import type { HttpClient } from "./http.ts";
import type {
  ConversationRecord as Conversation,
  ElicitationAnswer,
  LogEvent,
  RunEvent,
  RunResult,
} from "./types.ts";
import { TurnFollower } from "./turn.ts";
import { streamEvents } from "./sse.ts";
import { Broadcast, deferred } from "./queue.ts";
import { conversationUrl } from "./config.ts";
import { TimeoutError } from "./errors.ts";

const TERMINAL_CONVERSATION_STATUSES = new Set(["failed", "terminated"]);

export interface RunPlan {
  /** Open the conversation (a fresh `run`), or reuse one (`send`). */
  start(): Promise<{ conversation: Conversation; turnNumber: number; after: number }>;
}

export interface RunOptions {
  /** Stop waiting after this many ms and throw `TimeoutError`. `0` (default) waits. */
  timeoutMs?: number;
  /** Abort the run's own waiting. The turn keeps going in the sandbox. */
  signal?: AbortSignal;
  /** Keep every log event on the result. Off by default — a long turn is a lot of rows. */
  collectEvents?: boolean;
}

/**
 * A turn in flight.
 *
 * The work starts as soon as you call `run()`; what you do with this object
 * decides how much of it you see. `await` it for the answer, iterate it for
 * events as they land, or read `.textStream` for just the words. All three
 * read the same underlying run — there is no second request behind them.
 */
export class Run implements Promise<RunResult>, AsyncIterable<RunEvent> {
  readonly [Symbol.toStringTag]: string = "Run";

  /** The conversation this turn runs in. Resolves as soon as it exists. */
  readonly conversationId: Promise<string>;
  /** Where a human watches it. Resolves with `conversationId`. */
  readonly url: Promise<string>;
  /** The full conversation record, once opened. */
  readonly conversation: Promise<Conversation>;

  private readonly http: HttpClient;
  private readonly events = new Broadcast<RunEvent>();
  private readonly completion: Promise<RunResult>;
  private readonly opened = deferred<Conversation>();
  private readonly abort = new AbortController();
  private lastEventId = 0;
  private conversationIdValue: string | null = null;

  constructor(http: HttpClient, plan: RunPlan, options: RunOptions = {}) {
    this.http = http;
    this.conversation = this.opened.promise;
    this.conversationId = hushed(this.conversation.then((c) => c.id));
    this.url = hushed(this.conversation.then((c) => conversationUrl(c.id, http.config)));
    this.completion = this.execute(plan, options);
    // A caller may only ever iterate, or only ever read `conversationId`. None
    // of these derived promises may crash the process for want of a handler —
    // the failure still arrives on whichever one is actually awaited.
    hushed(this.completion);
  }

  then<A = RunResult, B = never>(
    onfulfilled?: ((value: RunResult) => A | PromiseLike<A>) | null,
    onrejected?: ((reason: unknown) => B | PromiseLike<B>) | null,
  ): Promise<A | B> {
    return this.completion.then(onfulfilled, onrejected);
  }

  catch<B = never>(onrejected?: ((reason: unknown) => B | PromiseLike<B>) | null): Promise<RunResult | B> {
    return this.completion.catch(onrejected);
  }

  finally(onfinally?: (() => void) | null): Promise<RunResult> {
    return this.completion.finally(onfinally);
  }

  [Symbol.asyncIterator](): AsyncIterator<RunEvent> {
    return this.events[Symbol.asyncIterator]();
  }

  /** Just the words, as they arrive. */
  get textStream(): AsyncIterable<string> {
    const events = this.events;
    return {
      async *[Symbol.asyncIterator]() {
        for await (const event of events) {
          if (event.type === "text") yield event.text;
        }
      },
    };
  }

  /** Stop waiting. The turn keeps running in the sandbox; `interrupt()` stops that. */
  cancel(): void {
    this.abort.abort();
  }

  /**
   * Answer a permission request this turn is blocked on — the `requestId` and
   * the `optionId` both come off a `{ type: "permission" }` event.
   *
   * ```ts
   * for await (const event of run) {
   *   if (event.type === "permission") {
   *     const allow = event.request.options.find((o) => o.kind === "allow_once");
   *     if (allow) await run.answer(event.request.requestId, allow.optionId);
   *   }
   * }
   * ```
   *
   * Only an agent with an `ask` entry in its `permission_policy` produces
   * these. Leave them unanswered and the server denies each one when it
   * expires, so the turn finishes having skipped the work.
   */
  async answer(requestId: string, optionId: string): Promise<void> {
    const id = await this.conversationId;
    await this.http.request(
      "POST",
      `/api/conversations/${id}/requests/${encodeURIComponent(requestId)}`,
      { body: { option_id: optionId } },
    );
  }

  /**
   * Answer a form this turn is blocked on — the `requestId` and the `schema`
   * the content is keyed by both come off an `{ type: "elicitation" }` event.
   *
   * ```ts
   * for await (const event of run) {
   *   if (event.type === "elicitation") {
   *     await run.answerElicitation(event.request.requestId, {
   *       action: "accept",
   *       content: { question_0: "Postgres" },
   *     });
   *   }
   * }
   * ```
   *
   * A value that does not fit the form, or a choice it did not offer, is
   * refused with a `ValidationError`. Leave a form unanswered and the server
   * declines it when it expires.
   */
  async answerElicitation(requestId: string, answer: ElicitationAnswer): Promise<void> {
    const id = await this.conversationId;
    await this.http.request(
      "POST",
      `/api/conversations/${id}/requests/${encodeURIComponent(requestId)}`,
      { body: answer },
    );
  }

  /** Ask the agent to stop the turn it is on. The sandbox stays up. */
  async interrupt(): Promise<void> {
    const id = await this.conversationId;
    await this.http.request("POST", `/api/conversations/${id}/interrupt`);
  }

  /** Tear the sandbox down. Nothing resumes after this. */
  async terminate(): Promise<void> {
    const id = await this.conversationId;
    await this.http.request("POST", `/api/conversations/${id}/terminate`);
  }

  /** The cursor to resume the log feed from — how a follow-up turn skips history. */
  get cursor(): number {
    return this.lastEventId;
  }

  private async execute(plan: RunPlan, options: RunOptions): Promise<RunResult> {
    try {
      const { conversation, turnNumber, after } = await plan.start();
      this.conversationIdValue = conversation.id;
      this.lastEventId = after;
      this.opened.resolve(conversation);
      const url = conversationUrl(conversation.id, this.http.config);
      this.events.push({ type: "conversation", conversationId: conversation.id, conversation, url });

      const result = await this.follow(conversation, turnNumber, after, options, url);
      this.events.close();
      return result;
    } catch (error) {
      this.opened.reject(error);
      this.events.close(error);
      throw error;
    }
  }

  private async follow(
    conversation: Conversation,
    turnNumber: number,
    after: number,
    options: RunOptions,
    url: string,
  ): Promise<RunResult> {
    const follower = new TurnFollower(turnNumber);
    const collected: LogEvent[] = [];
    const signal = options.signal
      ? AbortSignal.any([options.signal, this.abort.signal])
      : this.abort.signal;

    let failure: { reason: string | null } | null = null;
    let timedOut = false;
    const timeoutMs = options.timeoutMs ?? 0;
    const timer =
      timeoutMs > 0
        ? setTimeout(() => {
            timedOut = true;
            this.abort.abort();
          }, timeoutMs)
        : null;
    timer?.unref?.();

    try {
      for await (const event of streamEvents(this.http, conversation.id, { after, signal })) {
        if (typeof event.id === "number" && event.id > this.lastEventId) this.lastEventId = event.id;
        if (options.collectEvents) collected.push(event);
        this.events.push({ type: "event", event });

        for (const out of follower.apply(event)) this.events.push(out);
        if (follower.finished) break;

        // A stage that can mean the conversation is over. Which stages those
        // are is not a list worth hard-coding — `provision/failed` stops the
        // server, `setup/failed` may not, and `sandbox/done` is a suspend
        // (resumable) or a reclaim (not) depending on a field. So ask the
        // conversation instead of guessing: if it is terminal, no turn event
        // is ever coming and waiting for one hangs forever.
        if (mayEndConversation(event)) {
          const status = await this.currentStatus(conversation);
          if (status && TERMINAL_CONVERSATION_STATUSES.has(status)) {
            failure = { reason: stageReason(event) };
            break;
          }
        }
      }
    } finally {
      if (timer) clearTimeout(timer);
    }

    if (timedOut) {
      throw new TimeoutError(
        `Timed out after ${timeoutMs}ms waiting for turn ${turnNumber}. ` +
          `The turn is still running — resume conversation ${conversation.id}.`,
        conversation.id,
        follower.text,
      );
    }

    const status = await this.currentStatus(conversation);
    if (!follower.finished) {
      // The conversation died under the turn, or the caller stopped waiting.
      // Either way say so, rather than reporting an empty answer as normal.
      const state = failure ? "failed" : "timeout";
      this.events.push({ type: "turn-end", state, exitCode: null, reason: failure?.reason ?? null });
    }

    const result: RunResult = {
      conversationId: conversation.id,
      url,
      turnNumber,
      text: follower.text,
      toolsUsed: follower.toolsUsed,
      state: follower.state ?? (failure ? "failed" : "timeout"),
      exitCode: follower.exitCode,
      reason: follower.reason ?? failure?.reason ?? null,
      status,
    };
    if (options.collectEvents) result.events = collected;
    return result;
  }

  /** The status as of the end of the wait, not as of the last event. */
  private async currentStatus(conversation: Conversation): Promise<Conversation["status"] | null> {
    try {
      const fresh = await this.http.data<Conversation>(
        "GET",
        `/api/conversations/${conversation.id}`,
      );
      return fresh?.status ?? conversation.status ?? null;
    } catch {
      return conversation.status ?? null;
    }
  }

  /** The id, once known — for internal callers that already awaited the open. */
  get id(): string | null {
    return this.conversationIdValue;
  }
}

/**
 * Stage events worth checking the conversation's status over.
 *
 * `state` is a closed vocabulary — started/done/failed/interrupted — so a
 * destroyed sandbox and a parked one are both `sandbox`/`done`, told apart by
 * a field in the payload. Rather than encode that, treat every one of these as
 * "go and ask" and let the conversation's own status decide.
 */
function mayEndConversation(event: LogEvent): boolean {
  if (event.kind !== "stage") return false;
  if (event.stage === "turn") return false; // the follower owns the turn's own fate
  return event.state === "failed" || event.stage === "terminate" || event.stage === "sandbox";
}

/** Why a stage said it ended, when it said. */
function stageReason(event: LogEvent): string | null {
  let meta: unknown = event.data;
  if (typeof meta === "string") {
    try {
      meta = JSON.parse(meta);
    } catch {
      return null;
    }
  }
  if (!meta || typeof meta !== "object") return null;
  const record = meta as Record<string, unknown>;
  const reason = record.message ?? record.reason;
  const label = typeof reason === "string" && reason ? reason : null;
  return label ? `${event.stage}/${event.state}: ${label}` : `${event.stage}/${event.state}`;
}

/** Mark a promise as handled without changing what it settles to. */
function hushed<T>(promise: Promise<T>): Promise<T> {
  promise.catch(() => {});
  return promise;
}
