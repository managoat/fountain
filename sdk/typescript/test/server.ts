/**
 * A fake Fountain, in process.
 *
 * The SDK's job is to turn a log feed into an answer, so the tests need a
 * server that can hand out a feed on demand — including the awkward parts: a
 * connection that dies mid-turn, output belonging to somebody else's turn, an
 * ACP runtime that streams a sentence as five chunks.
 *
 * **A route here must answer in the same envelope the real one does.** Almost
 * everything is wrapped in `{data: …}`, and a fake that wraps one of the few
 * that are not turns a green suite into a lie — `me()` shipped returning `null`
 * against production for exactly that reason, because this file wrapped
 * `/api/auth/me` and the only test that touched the path called `request()`
 * rather than the verb. The unenveloped ones, from the OpenAPI document:
 *
 *   GET  /api/auth/me
 *   POST /api/auth/api-keys
 *   POST /api/conversations/{id}/prompts
 *   POST /api/conversations/{id}/requests/{request_id}
 *   POST /api/team/{agent_id}/messages
 *   POST /api/team/{agent_id}/schedules/{id}/run
 *   POST /api/webhooks/{id}/test
 *   POST /api/webhooks/{id}/deliveries/{delivery_id}/redeliver
 *   GET  /health, GET /health/ready
 *
 * Regenerate that list against a fresh spec rather than trusting it to age
 * well: `jq` the schemas whose 2xx body has no `data` property.
 */
import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import type { AddressInfo } from "node:net";

export interface FakeEvent {
  kind: "output" | "stage";
  stream?: string;
  data?: string;
  stage?: string;
  state?: string;
  turn_id?: string | null;
  blocks?: unknown[];
}

interface StoredEvent extends FakeEvent {
  id: number;
}

export interface FakeConversation {
  id: string;
  status: string;
  agent_id: string;
  vault_id?: string | null;
  environment_id?: string | null;
  title?: string | null;
  turn_count: number;
  events: StoredEvent[];
  turns: { turn_number: number; status: string }[];
}

const GOOGLE_PROVIDER = {
  id: "google",
  slug: "google",
  name: "Google (Gmail)",
  kind: "oauth2",
  platform: true,
  configured: true,
  scopes: ["openid", "email", "https://www.googleapis.com/auth/gmail.modify"],
  env_key: "GOOGLE_ACCESS_TOKEN",
  token_hosts: ["gmail.googleapis.com", "www.googleapis.com"],
  redirect_uri: "https://fountain.test/connections/google/callback",
  connect_url: "https://fountain.test/connections/google/start",
};

export class FakeFountain {
  agents: Record<string, unknown>[] = [
    { id: "11111111-1111-1111-1111-111111111111", name: "reposage", runtime: "claude", model: "opus" },
    { id: "22222222-2222-2222-2222-222222222222", name: "reporter", runtime: "codex", model: "gpt" },
  ];
  vaults: Record<string, unknown>[] = [{ id: "aaaaaaaa-1111-1111-1111-111111111111", name: "github-bot" }];
  environments: Record<string, unknown>[] = [
    { id: "bbbbbbbb-1111-1111-1111-111111111111", name: "monorepo" },
  ];
  /** Connections (#1178), as `GET /api/connections` lists them. */
  connections: Record<string, unknown>[] = [];
  /** Tenant connection providers (#1186); Google is always listed first. */
  providers: Record<string, unknown>[] = [];
  /** Sandboxes (ADR 0023), as `GET /api/sandboxes` lists them. */
  sandboxes: Record<string, unknown>[] = [];
  /** What the disk reads answer (ADR 0039), keyed by `files` / `file` / `git-status` / `diff`. */
  readonly disk: Record<string, Record<string, unknown>> = {
    files: { path: "/home/sprite", entries: [], truncated: false },
    file: { path: "/home/sprite/x", size: 0, truncated: false, encoding: "utf-8", content: "" },
    diff: { path: "/home/sprite", repo_root: "/home/sprite", staged: false, ref: null, diff: "", truncated: false },
    "git-status": {
      path: "/home/sprite",
      repo_root: "/home/sprite",
      branch: "main",
      untracked: "normal",
      entries: [],
      truncated: false,
    },
  };
  /** Secrets by `${collection}:${parentId}` → key → value. Never read back out. */
  readonly secrets = new Map<string, Map<string, string>>();
  /** agent_id → the teammate row `/api/team` returns. */
  readonly teammates = new Map<string, Record<string, unknown>>();
  readonly schedules = new Map<string, Record<string, unknown>[]>();
  readonly catalog: Record<string, unknown> = { runtimes: ["claude", "codex"], models: [] };

  readonly conversations = new Map<string, FakeConversation>();
  /** Every request the SDK made, for assertions about the wire. */
  readonly requests: {
    method: string;
    path: string;
    query: URLSearchParams;
    body: unknown;
    headers: NodeJS.Dict<string | string[]>;
  }[] = [];

  /** Called when a conversation opens or a prompt lands; script the turn here. */
  onTurn: ((conversation: FakeConversation, turnNumber: number) => void) | null = null;
  /** Force the next N SSE connections to die after this many events. */
  dieAfterEvents: number | null = null;
  /** Status to answer the next request with, instead of doing the work. */
  failNextWith: { status: number; body: unknown; retryAfter?: number } | null = null;
  /** Teammates that answer `conversation_busy` instead of taking a message. */
  readonly busyTeammates = new Set<string>();
  /** Every permission answer that arrived, in order. */
  readonly answers: { conversationId: string; requestId: string; optionId: string }[] = [];
  /** Every reapply body the server was sent, in order. */
  readonly reapplies: { conversationId: string; body: Record<string, unknown> }[] = [];
  /** Called when one lands — script the rest of the held turn from here. */
  onAnswer: ((conversationId: string, requestId: string, optionId: string) => void) | null = null;

  private nextEventId = 1;
  private nextConversation = 1;
  private readonly listeners = new Map<string, Set<() => void>>();
  private server: Server | null = null;
  readonly openResponses = new Set<ServerResponse>();

  async start(): Promise<string> {
    this.server = createServer((req, res) => void this.handle(req, res));
    await new Promise<void>((resolve) => this.server!.listen(0, "127.0.0.1", resolve));
    const { port } = this.server!.address() as AddressInfo;
    return `http://127.0.0.1:${port}`;
  }

  async stop(): Promise<void> {
    for (const res of this.openResponses) res.destroy();
    this.openResponses.clear();
    await new Promise<void>((resolve) => this.server?.close(() => resolve()));
    this.server = null;
  }

  /** Fail a conversation the way a provisioning failure does. */
  failConversation(conversationId: string, reason: string): void {
    const conversation = this.conversations.get(conversationId);
    if (!conversation) throw new Error(`no conversation ${conversationId}`);
    conversation.status = "failed";
    this.emit(conversationId, {
      kind: "stage",
      stage: "provision",
      state: "failed",
      stream: "stage",
      data: JSON.stringify({ reason }),
    });
  }

  /** Append an event to a conversation's feed and wake every open stream. */
  emit(conversationId: string, event: FakeEvent): StoredEvent {
    const conversation = this.conversations.get(conversationId);
    if (!conversation) throw new Error(`no conversation ${conversationId}`);
    const stored: StoredEvent = { ...event, id: this.nextEventId++ };
    conversation.events.push(stored);
    for (const wake of this.listeners.get(conversationId) ?? []) wake();
    return stored;
  }

  /** The whole shape of one agent turn: start, some output, done. */
  scriptTurn(
    conversationId: string,
    opts: { turnNumber: number; turnId: string; text?: string[]; tools?: string[]; state?: string; stream?: string },
  ): void {
    const turnId = opts.turnId;
    const stream = opts.stream ?? "acp";
    this.emit(conversationId, {
      kind: "stage",
      stage: "turn",
      state: "started",
      stream: "stage",
      data: JSON.stringify({ turn_number: opts.turnNumber, turn_id: turnId }),
    });
    for (const tool of opts.tools ?? []) {
      this.emit(conversationId, {
        kind: "output",
        stream,
        turn_id: turnId,
        blocks: [{ kind: "tool_use", name: tool }],
      });
    }
    for (const text of opts.text ?? []) {
      this.emit(conversationId, {
        kind: "output",
        stream,
        turn_id: turnId,
        blocks: [{ kind: "text", body: text }],
      });
    }
    this.emit(conversationId, {
      kind: "stage",
      stage: "turn",
      state: opts.state ?? "done",
      stream: "stage",
      data: JSON.stringify({ turn_number: opts.turnNumber, turn_id: turnId, stop_reason: "end_turn" }),
    });
  }

  private async handle(req: IncomingMessage, res: ServerResponse): Promise<void> {
    const url = new URL(req.url ?? "/", "http://localhost");
    const body = await readBody(req);
    this.requests.push({
      method: req.method ?? "GET",
      path: url.pathname,
      query: url.searchParams,
      body,
      headers: req.headers,
    });

    if (this.failNextWith) {
      const failure = this.failNextWith;
      this.failNextWith = null;
      if (failure.retryAfter !== undefined) res.setHeader("retry-after", String(failure.retryAfter));
      return json(res, failure.status, failure.body);
    }

    if (!(req.headers.authorization ?? "").startsWith("Bearer ")) {
      return json(res, 401, { error: "unauthorized" });
    }

    const path = url.pathname;

    // Unenveloped, exactly as the real server answers it — see the note above.
    if (path === "/api/auth/me") {
      return json(res, 200, { id: "user-1", email: "test@example.com", role: "user", email_verified: true });
    }
    if (path === "/api/catalog") return json(res, 200, { data: this.catalog });
    if (path === "/api/search") return json(res, 200, { data: [{ conversation_id: "conv-1", snippet: "hit" }] });

    if (path.startsWith("/api/team")) return this.team(req, res, path, url, body);

    // Connection providers (#1186): Google plus the tenant's own. A create
    // with `kind: mcp` stands in for discovery.
    if (path === "/api/connection-providers" || path === "/api/connections/providers") {
      if (req.method === "POST") {
        const input = (body ?? {}) as Record<string, unknown>;
        const created = {
          ...GOOGLE_PROVIDER,
          ...input,
          id: `prov-${this.providers.length + 1}`,
          platform: false,
          configured: true,
          client_source: input.kind === "mcp" ? "dcr" : "manual",
          issuer: input.kind === "mcp" ? "https://auth.test" : null,
          has_client_secret: true,
          client_secret: undefined,
        };
        this.providers.push(created);
        return json(res, 201, created);
      }
      return json(res, 200, { data: [GOOGLE_PROVIDER, ...this.providers] });
    }
    const provider = /^\/api\/connection-providers\/([^/]+)(\/discover)?$/.exec(path);
    if (provider) {
      if (provider[1] === "google") return json(res, 200, GOOGLE_PROVIDER);
      const found = this.providers.find((p) => p.id === provider[1]);
      if (!found) return json(res, 404, { error: "not_found" });
      if (req.method === "DELETE") {
        this.providers = this.providers.filter((p) => p !== found);
        res.statusCode = 204;
        res.end();
        return;
      }
      if (req.method === "PATCH") Object.assign(found, body ?? {});
      return json(res, 200, found);
    }
    // Sandboxes and their disks (ADR 0039). A read of an unknown sandbox
    // is 404 like the real one; the disk answers are whatever the test set.
    if (path === "/api/sandboxes") return json(res, 200, { data: this.sandboxes });
    const sandbox = /^\/api\/sandboxes\/([^/]+)(?:\/(files|file|git-status|diff))?$/.exec(path);
    if (sandbox) {
      const found = this.sandboxes.find((s) => s.id === sandbox[1]);
      if (!found) return json(res, 404, { error: "not_found" });
      if (sandbox[2]) return json(res, 200, { data: this.disk[sandbox[2]] });
      if (req.method === "DELETE") {
        res.statusCode = 204;
        res.end();
        return;
      }
      return json(res, 200, { data: found });
    }

    if (path === "/api/connections") return json(res, 200, { data: this.connections });
    const connection = /^\/api\/connections\/([^/]+)$/.exec(path);
    if (connection) {
      const found = this.connections.find((c) => c.id === connection[1]);
      if (!found) return json(res, 404, { error: "not_found" });
      if (req.method === "DELETE") {
        this.connections = this.connections.filter((c) => c !== found);
        res.statusCode = 204;
        res.end();
        return;
      }
      return json(res, 200, found);
    }

    const collection = /^\/api\/(agents|vaults|environments)(?:\/([^/]+))?(?:\/(secrets)(?:\/(.+))?)?$/.exec(path);
    if (collection) {
      return this.collection(req, res, {
        name: collection[1] as "agents" | "vaults" | "environments",
        id: collection[2],
        secrets: collection[3] === "secrets",
        key: collection[4],
        body,
        search: url.searchParams.get("search"),
      });
    }

    if (path === "/api/conversations" && req.method === "POST") {
      return json(res, 201, { data: this.createConversation(body as Record<string, unknown>) });
    }
    if (path === "/api/conversations" && req.method === "GET") {
      return json(res, 200, { data: [...this.conversations.values()].map(summary) });
    }

    const match = /^\/api\/conversations\/([^/]+)(\/.*)?$/.exec(path);
    if (match) {
      const conversation = this.conversations.get(match[1] as string);
      if (!conversation) return json(res, 404, { error: "not found" });
      const rest = match[2] ?? "";

      if (rest === "" && req.method === "GET") return json(res, 200, { data: summary(conversation) });
      if (rest === "/turns") return json(res, 200, { data: conversation.turns });
      if (rest === "/prompts" && req.method === "POST") {
        const turnNumber = conversation.turns.length + 1;
        conversation.turns.push({ turn_number: turnNumber, status: "running" });
        conversation.turn_count = turnNumber;
        json(res, 202, { status: "queued" });
        this.onTurn?.(conversation, turnNumber);
        return;
      }
      // Answering a held tool call. Unenveloped, like the real one.
      const answering = /^\/requests\/([^/]+)$/.exec(rest);
      if (answering && req.method === "POST") {
        const optionId = (body as { option_id?: unknown } | null)?.option_id;
        if (typeof optionId !== "string" || !optionId) {
          return json(res, 422, { error: "unprocessable_entity", errors: { option_id: ["is required"] } });
        }
        const requestId = decodeURIComponent(answering[1] as string);
        this.answers.push({ conversationId: conversation.id, requestId, optionId });
        json(res, 200, { ok: true });
        this.onAnswer?.(conversation.id, requestId, optionId);
        return;
      }

      if (rest === "/interrupt" || rest === "/terminate") return json(res, 200, { status: "ok" });
      if (rest === "/read" && req.method === "POST") return json(res, 204, null);
      if (rest === "/reapply" && req.method === "POST") {
        const selection = (body ?? {}) as Record<string, unknown>;
        this.reapplies.push({ conversationId: conversation.id, body: selection });
        return json(res, 200, { data: { ...summary(conversation), ...selection } });
      }
      if (rest === "/tree") return json(res, 200, { data: { id: conversation.id, children: [] } });
      if (rest === "/events") return this.eventPage(res, conversation, url);
      if (rest === "/stream") return this.stream(req, res, conversation, url);
    }

    json(res, 404, { error: "no route" });
  }

  /** The team endpoints: roster, messages, threads, routines and the stream. */
  private team(req: IncomingMessage, res: ServerResponse, path: string, url: URL, body: unknown): void {
    const method = req.method ?? "GET";

    if (path === "/api/team/stream") {
      // Every teammate's conversation on one connection.
      const first = [...this.teammates.values()][0] as { conversation?: { id?: string } } | undefined;
      const conversation = first?.conversation?.id
        ? this.conversations.get(first.conversation.id)
        : undefined;
      if (!conversation) {
        res.writeHead(200, { "Content-Type": "text/event-stream" });
        this.openResponses.add(res);
        res.on("close", () => this.openResponses.delete(res));
        return;
      }
      return this.stream(req, res, conversation, url);
    }

    if (path === "/api/team/schedules") {
      return json(res, 200, { data: [...this.schedules.values()].flat() });
    }

    if (path === "/api/team") {
      if (method === "GET") return json(res, 200, { data: [...this.teammates.values()] });
      if (method === "POST") {
        const attrs = (body ?? {}) as Record<string, unknown>;
        const agentId = String(attrs.agent_id ?? "");
        const agent = this.agents.find((a) => a.id === agentId);
        if (!agent) return json(res, 404, { error: "not_found" });
        const teammate = {
          agent_id: agentId,
          name: attrs.name ?? agent.name,
          agent,
          conversation: null,
          unread: 0,
        };
        this.teammates.set(agentId, teammate);
        return json(res, 201, { data: teammate });
      }
    }

    const match = /^\/api\/team\/([^/]+)(?:\/(messages|conversations|schedules)(?:\/([^/]+))?(?:\/(run))?)?$/.exec(path);
    if (!match) return json(res, 404, { error: "no route" });

    const agentId = match[1] as string;
    const teammate = this.teammates.get(agentId) as Record<string, unknown> | undefined;
    if (!teammate) return json(res, 404, { error: "not_found" });
    const sub = match[2];

    if (!sub) {
      if (method === "GET") return json(res, 200, { data: teammate });
      if (method === "PATCH") {
        const attrs = (body ?? {}) as Record<string, unknown>;
        teammate.name = attrs.name ?? (teammate.agent as Record<string, unknown>).name;
        return json(res, 200, { data: teammate });
      }
      if (method === "DELETE") {
        this.teammates.delete(agentId);
        return json(res, 204, null);
      }
    }

    if (sub === "messages" && method === "POST") {
      const attrs = (body ?? {}) as Record<string, unknown>;
      if (typeof attrs.prompt !== "string") return json(res, 422, { error: "prompt is required" });
      if (this.busyTeammates.has(agentId)) {
        // A 400 with a code, exactly as the real server answers a teammate
        // that is still working on the last message.
        return json(res, 400, { error: "conversation_busy" });
      }

      let conversationId = (teammate.conversation as { id?: string } | null)?.id;
      if (!conversationId) {
        const created = this.createConversation({ agent_id: agentId });
        conversationId = created.id;
        teammate.conversation = { id: conversationId, status: created.status };
      }
      const conversation = this.conversations.get(conversationId) as FakeConversation;
      const turnNumber = conversation.turns.length + 1;
      conversation.turns.push({ turn_number: turnNumber, status: "running" });
      json(res, 200, { status: "queued", conversation_id: conversationId });
      this.onTurn?.(conversation, turnNumber);
      return;
    }

    if (sub === "conversations") {
      if (method === "GET") {
        const id = (teammate.conversation as { id?: string } | null)?.id;
        const conv = id ? this.conversations.get(id) : undefined;
        return json(res, 200, { data: conv ? [summary(conv)] : [] });
      }
      if (method === "POST") {
        const created = this.createConversation({ agent_id: agentId });
        teammate.conversation = { id: created.id, status: created.status };
        return json(res, 201, { data: summary(created) });
      }
    }

    if (sub === "schedules") {
      const list = this.schedules.get(agentId) ?? [];
      this.schedules.set(agentId, list);
      if (method === "GET" && !match[3]) return json(res, 200, { data: list });
      if (match[4] === "run") return json(res, 200, { status: "queued" });
      if (method === "POST" && !match[3]) {
        const created = { id: `sched-${list.length + 1}`, agent_id: agentId, ...(body as object) };
        list.push(created);
        return json(res, 201, { data: created });
      }
      const id = match[3];
      const index = list.findIndex((s) => s.id === id);
      if (index === -1) return json(res, 404, { error: "not_found" });
      if (method === "GET") return json(res, 200, { data: list[index] });
      if (method === "PATCH") {
        Object.assign(list[index] as object, body as object);
        return json(res, 200, { data: list[index] });
      }
      if (method === "DELETE") {
        list.splice(index, 1);
        return json(res, 204, null);
      }
    }

    json(res, 405, { error: "method not allowed" });
  }

  /** The agent/vault/environment endpoints, including their secrets. */
  private collection(
    req: IncomingMessage,
    res: ServerResponse,
    q: {
      name: "agents" | "vaults" | "environments";
      id?: string | undefined;
      secrets: boolean;
      key?: string | undefined;
      body: unknown;
      search: string | null;
    },
  ): void {
    const items = this[q.name];
    const method = req.method ?? "GET";
    const singular = { agents: "agent", vaults: "vault", environments: "environment" }[q.name];

    if (!q.id) {
      if (method === "GET") {
        const data = q.search
          ? items.filter((item) => String(item.name ?? "").includes(q.search as string))
          : items;
        return json(res, 200, { data });
      }
      if (method === "POST") {
        const attrs = (q.body ?? {}) as Record<string, unknown>;
        if (!attrs.name) return json(res, 422, { error: "name is required" });
        // The API takes attributes flat, not wrapped under a resource key —
        // asserted here so a wrapped payload fails loudly.
        if (attrs[singular]) return json(res, 422, { error: `unexpected ${singular} wrapper` });
        const created = { id: `${q.name}-${items.length + 1}`, ...attrs };
        items.push(created);
        return json(res, 201, { data: created });
      }
      return json(res, 405, { error: "method not allowed" });
    }

    const index = items.findIndex((item) => item.id === q.id);
    if (index === -1) return json(res, 404, { error: "not found" });
    const item = items[index] as Record<string, unknown>;

    if (q.secrets) {
      const bag = this.secrets.get(`${q.name}:${q.id}`) ?? new Map<string, string>();
      this.secrets.set(`${q.name}:${q.id}`, bag);

      if (method === "GET") {
        // Keys only, never values.
        return json(res, 200, {
          data: [...bag.keys()].map((key) => ({ id: `sec-${key}`, key })),
        });
      }
      if (method === "POST") {
        const attrs = (q.body ?? {}) as Record<string, unknown>;
        if (typeof attrs.key !== "string" || typeof attrs.value !== "string") {
          return json(res, 422, { error: "key and value are required" });
        }
        bag.set(attrs.key, attrs.value);
        return json(res, 201, { data: { id: `sec-${attrs.key}`, key: attrs.key } });
      }
      if (method === "DELETE" && q.key) {
        if (!bag.delete(decodeURIComponent(q.key))) return json(res, 404, { error: "not found" });
        return json(res, 204, null);
      }
      return json(res, 405, { error: "method not allowed" });
    }

    if (method === "GET") return json(res, 200, { data: item });
    if (method === "PATCH") {
      Object.assign(item, (q.body ?? {}) as Record<string, unknown>);
      return json(res, 200, { data: item });
    }
    if (method === "DELETE") {
      items.splice(index, 1);
      return json(res, 204, null);
    }
    return json(res, 405, { error: "method not allowed" });
  }

  createConversation(body: Record<string, unknown>): FakeConversation {
    const id = `conv-${this.nextConversation++}`;
    const conversation: FakeConversation = {
      id,
      status: "running",
      agent_id: String(body.agent_id ?? ""),
      vault_id: (body.vault_id as string) ?? null,
      environment_id: (body.environment_id as string) ?? null,
      title: (body.title as string) ?? null,
      turn_count: 0,
      events: [],
      turns: [],
    };
    this.conversations.set(id, conversation);
    if (body.prompt) {
      conversation.turns.push({ turn_number: 1, status: "running" });
      conversation.turn_count = 1;
      // The real server starts the turn asynchronously; so does this one, or
      // the SDK would never exercise its replay path.
      setTimeout(() => this.onTurn?.(conversation, 1), 1);
    }
    return conversation;
  }

  private eventPage(res: ServerResponse, conversation: FakeConversation, url: URL): void {
    const after = Number(url.searchParams.get("after") ?? 0) || 0;
    const events = conversation.events.filter((event) => event.id > after);
    json(res, 200, {
      data: events,
      meta: { next_cursor: events.at(-1)?.id ?? after, has_more: false },
    });
  }

  stream(req: IncomingMessage, res: ServerResponse, conversation: FakeConversation, url: URL): void {
    const streams = (url.searchParams.get("streams") ?? "").split(",").filter(Boolean);
    const waitForMore = url.searchParams.get("wait") !== "false";
    let cursor = Number(req.headers["last-event-id"] ?? 0) || 0;
    let written = 0;
    let dead = false;

    res.writeHead(200, {
      "Content-Type": "text/event-stream",
      "Cache-Control": "no-cache",
      Connection: "keep-alive",
    });
    this.openResponses.add(res);

    const flush = (): void => {
      if (dead) return;
      for (const event of conversation.events) {
        if (event.id <= cursor) continue;
        if (streams.length && !streams.includes(event.stream ?? "")) {
          cursor = event.id;
          continue;
        }
        res.write(`id: ${event.id}\nevent: ${event.kind}\ndata: ${JSON.stringify(event)}\n\n`);
        cursor = event.id;
        written++;
        if (this.dieAfterEvents !== null && written >= this.dieAfterEvents) {
          // A deploy, a proxy timeout, a sandbox wake: the connection just ends.
          this.dieAfterEvents = null;
          dead = true;
          cleanup();
          // Let the bytes reach the client, *then* drop the socket — a real
          // connection death loses the future, not the past.
          setImmediate(() => res.destroy());
          return;
        }
      }
      if (!waitForMore) {
        dead = true;
        cleanup();
        res.end();
      }
    };

    const listeners = this.listeners.get(conversation.id) ?? new Set<() => void>();
    listeners.add(flush);
    this.listeners.set(conversation.id, listeners);

    const cleanup = (): void => {
      listeners.delete(flush);
      this.openResponses.delete(res);
    };
    res.on("close", cleanup);

    flush();
  }
}

function summary(conversation: FakeConversation): Record<string, unknown> {
  const { events, turns, ...rest } = conversation;
  void events;
  void turns;
  return rest;
}

function json(res: ServerResponse, status: number, body: unknown): void {
  const payload = JSON.stringify(body);
  res.writeHead(status, { "Content-Type": "application/json", "Content-Length": Buffer.byteLength(payload) });
  res.end(payload);
}

async function readBody(req: IncomingMessage): Promise<unknown> {
  const chunks: Buffer[] = [];
  for await (const chunk of req) chunks.push(chunk as Buffer);
  if (!chunks.length) return null;
  try {
    return JSON.parse(Buffer.concat(chunks).toString("utf8"));
  } catch {
    return null;
  }
}
