import type { HttpClient } from "./http.ts";
import type { Resolver } from "./resolve.ts";
import { Conversation } from "./conversation.ts";
import { Run, type RunOptions } from "./run.ts";
import { streamPath, type StreamRequest } from "./sse.ts";
import type {
  ConversationRecord,
  ImageInput,
  Schedule,
  ScheduleInput,
  SchedulePatch,
  Stream,
  TeamAddInput,
  TeamEvent,
  Teammate,
} from "./types.ts";

export interface MessageOptions extends RunOptions {
  images?: ImageInput[];
}

/**
 * The team: agents you have hired, each with a standing conversation.
 *
 * This is the surface the applications built on Fountain actually use — ten of
 * the eleven talk to `/api/team` and only some of them ever touch
 * `/api/conversations`. The reason is that a teammate is a *durable* thing:
 * one agent, one long-running sandbox, one thread you keep messaging, rather
 * than a conversation you open and close. `message()` returns the same `Run`
 * handle `fountain.run()` does, so a reply can be awaited or streamed.
 */
export class Team {
  private readonly http: HttpClient;
  private readonly resolver: Resolver;

  /** Cron routines that run a teammate with a prompt. */
  readonly schedules: TeamSchedules;

  constructor(http: HttpClient, resolver: Resolver) {
    this.http = http;
    this.resolver = resolver;
    this.schedules = new TeamSchedules(http, resolver);
  }

  /** Everyone on the team, with their unread counts and last activity. */
  async list(): Promise<Teammate[]> {
    return this.http.list<Teammate>("/api/team");
  }

  /** One teammate, by agent name or id. */
  async get(agent: string): Promise<Teammate> {
    return this.http.data<Teammate>("GET", `/api/team/${await this.agentId(agent)}`);
  }

  /** Put an agent on the team. Idempotent for an agent already on it. */
  async add(agent: string, options: Omit<TeamAddInput, "agent_id"> = {}): Promise<Teammate> {
    const body: TeamAddInput = { ...options, agent_id: await this.agentId(agent) };
    return this.http.data<Teammate>("POST", "/api/team", { body });
  }

  /** Take a teammate off the team. The agent itself is untouched. */
  async remove(agent: string): Promise<void> {
    await this.http.request("DELETE", `/api/team/${await this.agentId(agent)}`);
  }

  /** Change the name the team page shows. `null` restores the agent's own name. */
  async rename(agent: string, name: string | null): Promise<Teammate> {
    return this.http.data<Teammate>("PATCH", `/api/team/${await this.agentId(agent)}`, {
      body: { name },
    });
  }

  /**
   * Say something to a teammate, in its standing conversation.
   *
   * Returns a `Run`: await it for the reply, iterate it for events, or ignore
   * it and let the team stream carry the answer to a UI.
   */
  message(agent: string, prompt: string, options: MessageOptions = {}): Run {
    const body: Record<string, unknown> = { prompt };
    if (options.images?.length) body.images = options.images;

    return new Run(
      this.http,
      {
        start: async () => {
          const agentId = await this.agentId(agent);
          // Where the teammate's thread stands *before* the message, so the
          // follower knows which turn is the reply and where to read from.
          const before = await this.http
            .data<Teammate>("GET", `/api/team/${agentId}`)
            .catch(() => null);
          const existing = before?.conversation?.id ?? null;

          let after = 0;
          let turnNumber = 1;
          if (existing) {
            const conversation = new Conversation(this.http, existing);
            after = await conversation.cursor();
            turnNumber = (await conversation.lastTurnNumber()) + 1;
          }

          const sent = await this.http.request<{ conversation_id?: string; status?: string }>(
            "POST",
            `/api/team/${agentId}/messages`,
            { body },
          );

          const conversationId = sent?.conversation_id ?? existing;
          if (!conversationId) {
            throw new Error(`POST /api/team/${agentId}/messages returned no conversation id`);
          }
          // A fresh thread (the teammate had none, or the old one was retired)
          // starts its own numbering, and there is no history to skip.
          if (conversationId !== existing) {
            after = 0;
            turnNumber = 1;
          }

          const conversation = await this.http.data<ConversationRecord>(
            "GET",
            `/api/conversations/${conversationId}`,
          );
          return { conversation, turnNumber, after };
        },
      },
      options,
    );
  }

  /** The teammate's standing conversation, as a handle. */
  async conversation(agent: string): Promise<Conversation> {
    const teammate = await this.get(agent);
    const id = teammate.conversation?.id;
    if (!id) throw new Error(`${agent} has no conversation yet — send it a message first`);
    return new Conversation(this.http, id);
  }

  /** Every conversation this teammate has had on the team. */
  async history(agent: string): Promise<ConversationRecord[]> {
    return this.http.list<ConversationRecord>(`/api/team/${await this.agentId(agent)}/conversations`);
  }

  /** Start a fresh thread on a new computer; the current one is retired. */
  async freshConversation(agent: string): Promise<ConversationRecord> {
    return this.http.data<ConversationRecord>(
      "POST",
      `/api/team/${await this.agentId(agent)}/conversations`,
    );
  }

  /**
   * The whole team's events on one connection.
   *
   * One stream for every teammate is the shape a team UI wants, and building
   * it out of N per-conversation streams is what the apps did before this
   * endpoint existed. Reconnects from the last event id on its own.
   *
   * Each payload is a conversation event plus `conversation_id` and
   * `agent_id`, so a roster row can be found without a socket per teammate.
   *
   * Events carry server-parsed `blocks`, as on every other feed, so a client
   * renders a transcript from this stream alone rather than re-parsing a
   * runtime's dialect or opening a second connection per thread. The stream is
   * multi-conversation, so the server picks the runtime per event from the
   * conversation that produced it (#881).
   */
  stream(options: StreamRequest = {}): AsyncIterable<TeamEvent> {
    return streamPath(this.http, "/api/team/stream", {
      blocks: true,
      ...normalizeStreams(options),
    });
  }

  private async agentId(agent: string): Promise<string> {
    const { id } = await this.resolver.resolve("/api/agents", "agent", agent);
    return id;
  }
}

/** Cron routines attached to a teammate. */
export class TeamSchedules {
  private readonly http: HttpClient;
  private readonly resolver: Resolver;

  constructor(http: HttpClient, resolver: Resolver) {
    this.http = http;
    this.resolver = resolver;
  }

  /** Every routine on the team, or just one teammate's. */
  async list(agent?: string): Promise<Schedule[]> {
    if (!agent) return this.http.list<Schedule>("/api/team/schedules");
    return this.http.list<Schedule>(`/api/team/${await this.agentId(agent)}/schedules`);
  }

  async get(agent: string, id: string): Promise<Schedule> {
    return this.http.data<Schedule>("GET", `/api/team/${await this.agentId(agent)}/schedules/${id}`);
  }

  async create(agent: string, input: ScheduleInput): Promise<Schedule> {
    return this.http.data<Schedule>("POST", `/api/team/${await this.agentId(agent)}/schedules`, {
      body: input,
    });
  }

  async update(agent: string, id: string, patch: SchedulePatch): Promise<Schedule> {
    return this.http.data<Schedule>(
      "PATCH",
      `/api/team/${await this.agentId(agent)}/schedules/${id}`,
      { body: patch },
    );
  }

  async delete(agent: string, id: string): Promise<void> {
    await this.http.request("DELETE", `/api/team/${await this.agentId(agent)}/schedules/${id}`);
  }

  /** Run it now, without waiting for its cron. */
  async run(agent: string, id: string): Promise<unknown> {
    return this.http.request("POST", `/api/team/${await this.agentId(agent)}/schedules/${id}/run`);
  }

  private async agentId(agent: string): Promise<string> {
    const { id } = await this.resolver.resolve("/api/agents", "agent", agent);
    return id;
  }
}

/** `streams: ["acp", "stage"]` is friendlier than a comma-joined string. */
export function normalizeStreams<T extends { streams?: Stream[] | string }>(
  options: T,
): Omit<T, "streams"> & { streams?: string } {
  const { streams, ...rest } = options;
  return {
    ...rest,
    ...(streams === undefined
      ? {}
      : { streams: Array.isArray(streams) ? streams.join(",") : streams }),
  };
}
