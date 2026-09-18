/**
 * The shared conformance suite, run against this client.
 *
 * The scenarios live in `sdk/conformance/scenarios` and are the same files
 * Python, Swift and Elixir run. Nothing language-specific belongs in them, and
 * nothing here decides what passes: this file serves the scripted bytes, drives
 * the public client, normalises what it saw into the shared vocabulary, and
 * compares that against the scenario's own `expect`.
 *
 * `sdk/conformance/README.md` is the format. Read it before changing anything
 * here, because three other adapters implement the same thing.
 */
import { test } from "node:test";
import assert from "node:assert/strict";
import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import type { AddressInfo } from "node:net";
import { readFileSync, readdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { Fountain } from "../src/client.ts";
import {
  AuthError,
  ConnectionError,
  ConversationBusyError,
  FountainError,
  NotFoundError,
  NotReadyError,
  QuotaExceededError,
  RateLimitError,
  ResolutionError,
  InsufficientCreditsError,
  TimeoutError,
  ValidationError,
} from "../src/errors.ts";
import type { RunEvent } from "../src/types.ts";

const SDK = "typescript";
const HERE = dirname(fileURLToPath(import.meta.url));
const CONFORMANCE = join(HERE, "..", "..", "conformance");

// ── the scenario format, as this adapter reads it ────────────────────────────

interface Match {
  method: string;
  path: string;
  query?: Record<string, string>;
  headers?: Record<string, string>;
}
type SseChunk = string | { text: string; delay_ms?: number };
interface Respond {
  status: number;
  headers?: Record<string, string>;
  json?: unknown;
  body?: string;
  sse?: SseChunk[];
  close?: "end" | "abort";
}
interface Scenario {
  name: string;
  title: string;
  contract: string;
  client: { api_key: string | null; base_url_suffix?: string; timeout_ms?: number };
  http: { match: Match; respond: Respond }[];
  steps: Record<string, any>[];
  expect: Record<string, any>;
}

interface Recorded {
  method: string;
  path: string;
  query: Record<string, string>;
  headers: Record<string, string>;
  body: unknown;
}

// ── the scripted server ──────────────────────────────────────────────────────

/**
 * Serves one scenario's exchanges over a real socket.
 *
 * A real socket rather than a fetch stub on purpose: half of these scenarios
 * are about what happens between TCP writes, and a stub that hands over a whole
 * response body cannot express a frame arriving in three pieces or a connection
 * that dies without an end.
 */
class ScriptedServer {
  readonly requests: Recorded[] = [];
  readonly unmatched: Recorded[] = [];
  private readonly consumed: boolean[];
  private server: Server | null = null;
  private readonly open = new Set<ServerResponse>();

  private readonly exchanges: Scenario["http"];

  constructor(exchanges: Scenario["http"]) {
    this.exchanges = exchanges;
    this.consumed = exchanges.map(() => false);
  }

  async start(): Promise<string> {
    this.server = createServer((req, res) => void this.handle(req, res));
    await new Promise<void>((resolve) => this.server!.listen(0, "127.0.0.1", resolve));
    const { port } = this.server!.address() as AddressInfo;
    return `http://127.0.0.1:${port}`;
  }

  async stop(): Promise<void> {
    for (const res of this.open) res.destroy();
    this.open.clear();
    await new Promise<void>((resolve) => this.server?.close(() => resolve()));
    this.server = null;
  }

  private pick(recorded: Recorded): number {
    for (let index = 0; index < this.exchanges.length; index++) {
      if (this.consumed[index]) continue;
      const { match } = this.exchanges[index]!;
      if (match.method.toUpperCase() !== recorded.method) continue;
      if (match.path !== recorded.path) continue;
      if (!subset(match.query ?? {}, recorded.query)) continue;
      if (!subset(match.headers ?? {}, recorded.headers)) continue;
      this.consumed[index] = true;
      return index;
    }
    return -1;
  }

  private async handle(req: IncomingMessage, res: ServerResponse): Promise<void> {
    const url = new URL(req.url ?? "/", "http://127.0.0.1");
    const raw = await readBody(req);
    const recorded: Recorded = {
      method: (req.method ?? "GET").toUpperCase(),
      path: url.pathname,
      query: Object.fromEntries(url.searchParams),
      headers: Object.fromEntries(
        Object.entries(req.headers).map(([key, value]) => [
          key.toLowerCase(),
          Array.isArray(value) ? value.join(",") : String(value ?? ""),
        ]),
      ),
      body: raw === "" ? null : safeJson(raw),
    };
    this.requests.push(recorded);

    const index = this.pick(recorded);
    if (index === -1) {
      // Not a 404: an unanticipated request is a finding, and answering it
      // plausibly would let a client's extra round trip pass unnoticed.
      this.unmatched.push(recorded);
      res.writeHead(599, { "content-type": "application/json" });
      res.end(JSON.stringify({ error: "conformance_unmatched_request" }));
      return;
    }

    const respond = this.exchanges[index]!.respond;
    if (respond.sse) return this.stream(res, respond);

    const headers: Record<string, string> = { ...(respond.headers ?? {}) };
    let payload: string | null = null;
    if (respond.json !== undefined) {
      payload = JSON.stringify(respond.json);
      headers["content-type"] ??= "application/json";
    } else if (respond.body !== undefined) {
      payload = respond.body;
    }
    if (payload !== null) headers["content-length"] = String(Buffer.byteLength(payload));
    res.writeHead(respond.status, headers);
    res.end(payload ?? undefined);
  }

  private stream(res: ServerResponse, respond: Respond): void {
    res.writeHead(respond.status, {
      "cache-control": "no-cache",
      connection: "keep-alive",
      ...(respond.headers ?? {}),
    });
    this.open.add(res);
    res.on("close", () => this.open.delete(res));

    void (async () => {
      for (const chunk of respond.sse ?? []) {
        const text = typeof chunk === "string" ? chunk : chunk.text;
        const delay = typeof chunk === "string" ? 0 : (chunk.delay_ms ?? 0);
        if (delay > 0) await sleep(delay);
        if (res.destroyed) return;
        if (text) res.write(text);
      }
      if (res.destroyed) return;
      if (respond.close === "abort") {
        // A deploy, a proxy timeout, a sandbox wake. The bytes already written
        // reach the client; the terminating chunk never does.
        setImmediate(() => res.destroy());
      } else {
        res.end();
      }
    })();
  }
}

// ── driving the public client ────────────────────────────────────────────────

interface Observations {
  requests: Recorded[];
  unmatched: Recorded[];
  events: Record<string, unknown>[];
  result: Record<string, unknown> | null;
  error: Record<string, unknown> | null;
  value: unknown;
  eventIds: number[] | null;
}

const ERROR_KINDS: [new (...args: any[]) => Error, string][] = [
  // Most specific first: every one of these extends FountainError.
  [ConversationBusyError, "busy"],
  [InsufficientCreditsError, "insufficient_credits"],
  [QuotaExceededError, "quota"],
  [NotReadyError, "not_ready"],
  [RateLimitError, "rate_limited"],
  [ValidationError, "validation"],
  [NotFoundError, "not_found"],
  [AuthError, "auth"],
  [TimeoutError, "timeout"],
  [ConnectionError, "connection"],
  [ResolutionError, "resolution"],
  [FountainError, "server"],
];

function normaliseError(error: unknown): Record<string, unknown> {
  const kind = ERROR_KINDS.find(([type]) => error instanceof type)?.[1] ?? "unknown";
  const out: Record<string, unknown> = { kind };
  if (error instanceof FountainError) {
    out.status = error.status;
    out.code = error.code ?? null;
    out.retryable = error.retryable;
    out.retry_after = error.retryAfter;
    out.field_errors = error.fieldErrors;
    out.upgrade_url = error instanceof InsufficientCreditsError ? error.upgradeUrl ?? null : null;
  }
  if (error instanceof TimeoutError) out.partial_text = error.partialText;
  if (out.kind === "unknown") out.message = String((error as Error)?.message ?? error);
  return out;
}

function normaliseEvent(event: RunEvent): Record<string, unknown> {
  switch (event.type) {
    case "conversation":
      return { type: "conversation", conversation_id: event.conversationId };
    case "turn-start":
      return { type: "turn-start", turn_number: event.turnNumber, turn_id: event.turnId };
    case "text":
    case "thinking":
      return { type: event.type, text: event.text };
    case "tool":
      return { type: "tool", name: event.name };
    case "permission":
      return {
        type: "permission",
        request_id: event.request.requestId,
        options: event.request.options.map((option) => option.optionId),
      };
    case "turn-end":
      return {
        type: "turn-end",
        state: event.state,
        exit_code: event.exitCode,
        reason: event.reason,
      };
    default:
      return { type: event.type };
  }
}

async function drive(scenario: Scenario, baseUrl: string): Promise<Partial<Observations>> {
  const client = new Fountain({
    apiKey: scenario.client.api_key ?? undefined,
    baseUrl: baseUrl + (scenario.client.base_url_suffix ?? ""),
    // Nothing here should ever wait on a real network.
    timeoutMs: scenario.client.timeout_ms ?? 5_000,
  });

  const out: Partial<Observations> = {};

  for (const step of scenario.steps) {
    switch (step.op) {
      case "me":
        out.value = await client.me();
        break;
      case "list":
        out.value = await (client as any)[step.resource].list();
        break;
      case "create_agent":
        out.value = await client.agents.create(step.attrs);
        break;
      case "get_conversation":
        out.value = await client.resume(step.conversation_id).get();
        break;
      case "history":
        out.eventIds = (await client.resume(step.conversation_id).history()).map((event) =>
          Number(event.id),
        );
        break;
      case "send": {
        const run = client.resume(step.conversation_id).send(step.prompt);
        out.result = normaliseResult(await run);
        break;
      }
      case "run": {
        const run = client.run(step.prompt, {
          agent: step.agent,
          channelId: step.channel_id,
          clientRequestId: step.client_request_id,
          ...(step.timeout_ms ? { timeoutMs: step.timeout_ms } : {}),
        });
        const events: Record<string, unknown>[] = [];
        const answers: Record<string, string> = step.answer_permissions ?? {};
        const consume = (async () => {
          for await (const event of run) {
            events.push(normaliseEvent(event));
            if (event.type === "permission") {
              const option = answers[event.request.requestId] ?? answers["*"];
              if (option) await run.answer(event.request.requestId, option);
            }
          }
        })();
        try {
          out.result = normaliseResult(await run);
        } finally {
          out.events = events;
          await consume.catch(() => {});
        }
        break;
      }
      default:
        throw new Error(`conformance: this adapter has no op ${step.op}`);
    }
  }
  return out;
}

function normaliseResult(result: any): Record<string, unknown> {
  return {
    state: result.state,
    text: result.text,
    tools_used: result.toolsUsed,
    turn_number: result.turnNumber,
    exit_code: result.exitCode,
    reason: result.reason,
    conversation_id: result.conversationId,
    status: result.status,
  };
}

// ── comparing against `expect` ───────────────────────────────────────────────

function subset(expected: Record<string, unknown>, actual: Record<string, unknown>): boolean {
  return Object.entries(expected).every(([key, value]) => deepSubset(value, actual[key]));
}

function deepSubset(expected: unknown, actual: unknown): boolean {
  if (expected === null || typeof expected !== "object") return expected === actual;
  if (Array.isArray(expected)) {
    if (!Array.isArray(actual) || actual.length !== expected.length) return false;
    return expected.every((item, index) => deepSubset(item, actual[index]));
  }
  if (actual === null || typeof actual !== "object") return false;
  return Object.entries(expected as Record<string, unknown>).every(([key, value]) =>
    deepSubset(value, (actual as Record<string, unknown>)[key]),
  );
}

function show(value: unknown): string {
  return JSON.stringify(value, null, 2) ?? String(value);
}

function check(scenario: Scenario, observed: Observations): string[] {
  const problems: string[] = [];
  const expect = scenario.expect;
  const fail = (what: string, detail: string) => problems.push(`${what}\n      ${detail}`);

  for (const request of observed.unmatched) {
    fail(
      "unmatched request",
      `the client sent ${request.method} ${request.path}, which no exchange in the scenario ` +
        `anticipated. Either the client should not have sent it, or the scenario needs it.`,
    );
  }

  if (expect.error) {
    if (!observed.error) {
      fail("error", `expected ${show(expect.error)} but the call succeeded`);
    } else if (!subset(expect.error, observed.error)) {
      fail("error", `expected ${show(expect.error)}\n      got ${show(observed.error)}`);
    }
  } else if (observed.error) {
    fail("error", `the call was not supposed to fail, and raised ${show(observed.error)}`);
  }

  if (expect.requests) {
    const wanted = expect.requests as Record<string, any>[];
    if (expect.requests_exactly && observed.requests.length !== wanted.length) {
      fail(
        "requests",
        `expected exactly ${wanted.length} request(s), saw ${observed.requests.length}: ` +
          observed.requests.map((r) => `${r.method} ${r.path}`).join(", "),
      );
    }
    wanted.forEach((want, index) => {
      const got = observed.requests[index];
      if (!got) return fail(`requests[${index}]`, `expected ${want.method} ${want.path}, saw nothing`);
      if (want.method !== got.method || want.path !== got.path) {
        fail(
          `requests[${index}]`,
          `expected ${want.method} ${want.path}, saw ${got.method} ${got.path}`,
        );
        return;
      }
      if (want.query && !subset(want.query, got.query)) {
        fail(`requests[${index}].query`, `expected ${show(want.query)}\n      got ${show(got.query)}`);
      }
      if (want.headers && !subset(want.headers, got.headers)) {
        fail(
          `requests[${index}].headers`,
          `expected ${show(want.headers)}\n      got ${show(got.headers)}`,
        );
      }
      for (const [header, prefix] of Object.entries(want.header_prefixes ?? {})) {
        const value = got.headers[header] ?? "";
        if (!value.startsWith(String(prefix))) {
          fail(
            `requests[${index}].headers.${header}`,
            `expected it to start with ${JSON.stringify(prefix)}, got ${JSON.stringify(value)}`,
          );
        }
      }
      for (const header of want.headers_absent ?? []) {
        if (header in got.headers) {
          fail(
            `requests[${index}].headers.${header}`,
            `expected no such header, got ${JSON.stringify(got.headers[header])}`,
          );
        }
      }
      if (want.body && !deepSubset(want.body, got.body)) {
        fail(`requests[${index}].body`, `expected ${show(want.body)}\n      got ${show(got.body)}`);
      }
    });
  }

  if (expect.events) {
    // A subsequence, not an equality: `expect.events` names the events that
    // must appear in this order, and a client emitting extra `event` rows
    // alongside them is not a divergence.
    let cursor = 0;
    for (const want of expect.events as Record<string, unknown>[]) {
      const at = observed.events.findIndex((got, index) => index >= cursor && subset(want, got));
      if (at === -1) {
        fail(
          "events",
          `expected ${show(want)} after index ${cursor}, and the run emitted:\n      ` +
            show(observed.events),
        );
        break;
      }
      cursor = at + 1;
    }
  }

  if (expect.result) {
    if (!observed.result) fail("result", `expected ${show(expect.result)} but there was no result`);
    else if (!subset(expect.result, observed.result)) {
      fail("result", `expected ${show(expect.result)}\n      got ${show(observed.result)}`);
    }
  }

  if ("value" in expect && !deepSubset(expect.value, observed.value)) {
    fail("value", `expected ${show(expect.value)}\n      got ${show(observed.value)}`);
  }

  if (expect.event_ids && !deepSubset(expect.event_ids, observed.eventIds)) {
    fail("event_ids", `expected ${show(expect.event_ids)}\n      got ${show(observed.eventIds)}`);
  }

  return problems;
}

// ── the driver ───────────────────────────────────────────────────────────────

const skips: Record<string, unknown> = (() => {
  const matrix = JSON.parse(readFileSync(join(CONFORMANCE, "matrix.json"), "utf8"));
  const out: Record<string, unknown> = {};
  for (const [name, verdicts] of Object.entries(matrix.scenarios ?? {})) {
    const verdict = (verdicts as Record<string, unknown>)[SDK];
    if (verdict !== "yes") out[name] = verdict;
  }
  return out;
})();

const scenarios: Scenario[] = readdirSync(join(CONFORMANCE, "scenarios"))
  .filter((file) => file.endsWith(".json"))
  .sort()
  .map((file) => JSON.parse(readFileSync(join(CONFORMANCE, "scenarios", file), "utf8")));

for (const scenario of scenarios) {
  const skip = skips[scenario.name] as { skip?: string; issue?: number } | undefined;
  test(`conformance/${scenario.name}`, { skip: skip ? `#${skip.issue}: ${skip.skip}` : false }, async () => {
    const server = new ScriptedServer(scenario.http);
    const baseUrl = await server.start();
    const observed: Observations = {
      requests: server.requests,
      unmatched: server.unmatched,
      events: [],
      result: null,
      error: null,
      value: undefined,
      eventIds: null,
    };
    try {
      Object.assign(observed, await drive(scenario, baseUrl));
    } catch (error) {
      observed.error = normaliseError(error);
    } finally {
      await server.stop();
    }

    const problems = check(scenario, observed);
    assert.equal(
      problems.length,
      0,
      `\nconformance FAILED for ${SDK} / ${scenario.name}\n` +
        `  ${scenario.title}\n\n` +
        problems.map((problem) => `  ${problem}`).join("\n\n") +
        "\n",
    );
  });
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function safeJson(text: string): unknown {
  try {
    return JSON.parse(text);
  } catch {
    return text;
  }
}

async function readBody(req: IncomingMessage): Promise<string> {
  const chunks: Buffer[] = [];
  for await (const chunk of req) chunks.push(chunk as Buffer);
  return Buffer.concat(chunks).toString("utf8");
}
