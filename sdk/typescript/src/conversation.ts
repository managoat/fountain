import type { HttpClient } from "./http.ts";
import type { ConversationRecord, LogEvent, Stream, Turn } from "./types.ts";
import { Run, type RunOptions } from "./run.ts";
import { streamEvents, type StreamOptions } from "./sse.ts";
import { conversationUrl } from "./config.ts";

export interface SendOptions extends RunOptions {
  /** Images to attach to the prompt, as the API's `ImageInput` shape. */
  images?: unknown[];
  /**
   * Your own name for this submission, carried to the turn the prompt opens
   * and onto that turn's `started` event (#1406). Read it back on the turn to
   * find which turn was yours, instead of guessing from turn order. Not an
   * idempotency key: sending the same value twice opens two turns.
   */
  clientRequestId?: string;
}

export interface ReapplyOptions {
  /** Change the agent; omit to keep the current one. */
  agentId?: string;
  /** Change the environment, pass null to clear it, or omit it to keep it. */
  environmentId?: string | null;
  /** Change the vault, pass null to clear it, or omit it to keep it. */
  vaultId?: string | null;
}

/**
 * A conversation you already have — the sandbox is still there, and so is
 * everything the agent learned in it.
 *
 * This is the piece no stateless agent API has. `resume(id).send(...)` costs
 * one prompt, not a re-explanation of the whole task, because the machine, the
 * checkout and the session are exactly where the last turn left them.
 */
export class Conversation {
  readonly id: string;

  private readonly http: HttpClient;
  /** Where the log feed has been read to, so a follow-up skips the history. */
  private cursorValue: number;

  constructor(http: HttpClient, id: string, cursor = 0) {
    this.http = http;
    this.id = id;
    this.cursorValue = cursor;
  }

  /** Where a human watches this conversation. */
  get url(): string {
    return conversationUrl(this.id, this.http.config);
  }

  /** The conversation record: status, agent, turn count. */
  async get(): Promise<ConversationRecord> {
    return this.http.data<ConversationRecord>("GET", `/api/conversations/${this.id}`);
  }

  async status(): Promise<ConversationRecord["status"]> {
    return (await this.get()).status;
  }

  async turns(): Promise<Turn[]> {
    return this.http.list<Turn>(`/api/conversations/${this.id}/turns`);
  }

  /**
   * Merge labels into this conversation, and return the updated record.
   *
   * A key you do not name is left alone; `null` removes one. At most 32
   * labels, a key at most 64 bytes and a value at most 256 bytes — a write
   * over any of those is a 422 naming the offending key.
   */
  async setLabels(labels: Record<string, string | null>): Promise<ConversationRecord> {
    return this.http.data<ConversationRecord>(
      "PATCH",
      `/api/conversations/${this.id}/labels`,
      { body: { labels } },
    );
  }

  /** Send the next turn. Returns a `Run` — await it, or stream it. */
  send(prompt: string, options: SendOptions = {}): Run {
    const body: Record<string, unknown> = { prompt };
    if (options.images?.length) body.images = options.images;
    // Presence, not truthiness: an explicitly empty id is a 422 the caller has
    // to see, not a prompt that quietly runs uncorrelated.
    if (options.clientRequestId !== undefined) {
      body.client_request_id = options.clientRequestId;
    }

    const run = new Run(
      this.http,
      {
        start: async () => {
          // The cursor and the turn number both have to be taken *before* the
          // prompt goes in, or we race the events it produces.
          const after = await this.cursor();
          const turnNumber = (await this.lastTurnNumber()) + 1;
          await this.http.request("POST", `/api/conversations/${this.id}/prompts`, { body });
          const conversation = await this.get();
          return { conversation, turnNumber, after };
        },
      },
      options,
    );

    // Keep the conversation's cursor moving as the run consumes the feed, so
    // the next send starts where this one stopped.
    void run
      .finally(() => {
        if (run.cursor > this.cursorValue) this.cursorValue = run.cursor;
      })
      .catch(() => {});

    return run;
  }

  /**
   * Answer a permission request the agent is holding a tool call on.
   *
   * `optionId` has to be one of the ids the agent offered on the
   * `permission_request` block — the server refuses anything else with a 422
   * rather than forwarding it. Answer promptly: the request expires, and an
   * expired one is denied.
   *
   * ```ts
   * for await (const event of run) {
   *   if (event.type === "permission") {
   *     const allow = event.request.options.find((o) => o.kind === "allow_once");
   *     if (allow) await conversation.answer(event.request.requestId, allow.optionId);
   *   }
   * }
   * ```
   */
  async answer(requestId: string, optionId: string): Promise<void> {
    await this.http.request(
      "POST",
      `/api/conversations/${this.id}/requests/${encodeURIComponent(requestId)}`,
      { body: { option_id: optionId } },
    );
  }

  /**
   * Mark everything so far as read, clearing the teammate's unread badge.
   *
   * Every application built on Fountain calls this — it is what stops a UI
   * shouting about messages the person is currently looking at.
   */
  async markRead(): Promise<void> {
    await this.http.request("POST", `/api/conversations/${this.id}/read`);
  }

  /**
   * Everything the feed holds, oldest first, paged until drained.
   *
   * The other universal one: a UI opening a thread needs the transcript so
   * far, and the JSON feed pages at 1000. `streams` narrows what comes back —
   * `["acp"]` for a transcript, `["stage"]` for the lifecycle alone.
   */
  async history(
    options: { streams?: Stream[] | string; after?: number; limit?: number } = {},
  ): Promise<LogEvent[]> {
    const streams = Array.isArray(options.streams) ? options.streams.join(",") : options.streams;
    const limit = options.limit ?? 1000;
    const out: LogEvent[] = [];
    let after = options.after ?? 0;

    for (;;) {
      const page = await this.http.request<{
        data?: LogEvent[];
        meta?: { has_more?: boolean; next_cursor?: number | null };
      }>("GET", `/api/conversations/${this.id}/events`, {
        query: { after, limit, blocks: "true", streams },
      });
      const events = page?.data ?? [];
      out.push(...events);
      const meta = page?.meta ?? {};
      if (!meta.has_more || meta.next_cursor === null || meta.next_cursor === undefined) break;
      after = meta.next_cursor;
    }

    const last = out.at(-1)?.id;
    if (typeof last === "number" && last > this.cursorValue) this.cursorValue = last;
    return out;
  }

  /** The conversations this one spawned, as a tree. */
  async tree(): Promise<unknown> {
    return this.http.data("GET", `/api/conversations/${this.id}/tree`);
  }

  /**
   * Re-select this conversation's agent, environment and vault on the machine
   * it is already running. The conversation, the transcript and the files on
   * disk all stay; the next prompt starts a runtime that reads the new
   * selection. Call it with nothing to refresh what is already selected.
   *
   * A selection that would need the machine built again is refused with 409
   * `rebuild_required`, naming the field that forced it.
   */
  async reapply(options: ReapplyOptions = {}): Promise<ConversationRecord> {
    const body: Record<string, unknown> = {};
    if (options.agentId !== undefined) body.agent_id = options.agentId;
    if (options.environmentId !== undefined) body.environment_id = options.environmentId;
    if (options.vaultId !== undefined) body.vault_id = options.vaultId;
    return this.http.data("POST", `/api/conversations/${this.id}/reapply`, { body });
  }

  /** Ask the agent to stop the turn it is on. The sandbox stays up. */
  async interrupt(): Promise<void> {
    await this.http.request("POST", `/api/conversations/${this.id}/interrupt`);
  }

  /** Tear the sandbox down. Nothing resumes after this. */
  async terminate(): Promise<void> {
    await this.http.request("POST", `/api/conversations/${this.id}/terminate`);
  }

  /** Delete the conversation and its history. */
  async delete(): Promise<void> {
    await this.http.request("DELETE", `/api/conversations/${this.id}`);
  }

  /**
   * The raw log feed, reconnecting on its own. Everything, from `after`
   * onwards, of every turn — `run`/`send` is the filtered view of this.
   */
  events(options: StreamOptions = {}): AsyncIterable<LogEvent> {
    return streamEvents(this.http, this.id, options);
  }

  /** One page of the log feed as JSON, for a client that would rather poll. */
  async eventPage(after = 0, limit = 1000): Promise<{ events: LogEvent[]; nextCursor: number; hasMore: boolean }> {
    const out = await this.http.request<{ data?: LogEvent[]; meta?: Record<string, unknown> }>(
      "GET",
      `/api/conversations/${this.id}/events`,
      { query: { after, limit, blocks: "true" } },
    );
    const meta = out?.meta ?? {};
    return {
      events: out?.data ?? [],
      nextCursor: typeof meta.next_cursor === "number" ? meta.next_cursor : after,
      hasMore: Boolean(meta.has_more),
    };
  }

  /** The highest turn number so far; the next prompt is this plus one. */
  async lastTurnNumber(): Promise<number> {
    const turns = await this.turns();
    return turns.reduce((max, turn) => Math.max(max, Number(turn.turn_number) || 0), 0);
  }

  /** Where this handle has read to, discovering it if nobody has looked yet. */
  async cursor(): Promise<number> {
    return this.cursorValue > 0 ? this.cursorValue : this.discoverCursor();
  }

  /**
   * Find the end of the log feed cheaply.
   *
   * A cold `resume().send()` has no cursor, and starting from 0 would replay
   * every event of every earlier turn before reaching ours. Draining the
   * `stage` stream (`wait=false`) is a few rows for even a long conversation,
   * and its ids are the same global ids the full feed uses.
   */
  private async discoverCursor(): Promise<number> {
    let last = 0;
    try {
      for await (const event of streamEvents(this.http, this.id, {
        streams: "stage",
        wait: false,
        maxRetries: 0,
      })) {
        if (typeof event.id === "number" && event.id > last) last = event.id;
      }
    } catch {
      // Not worth failing a send over; 0 replays, which is correct if noisy.
      return 0;
    }
    this.cursorValue = last;
    return last;
  }
}
