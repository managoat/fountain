import type { HttpClient } from "./http.ts";
import type { LogEvent, Stream } from "./types.ts";
import { ManagoatError, errorForStatus } from "./errors.ts";

/**
 * What a caller asks a stream for. `streams` takes the friendly array form
 * here and is joined on the way to the query string.
 */
export type StreamRequest = Omit<StreamOptions, "streams"> & { streams?: Stream[] | string };

/** Join the friendly `streams` array into the comma list the query string takes. */
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

/** One `id:`/`event:`/`data:` message off the wire. */
export interface SseMessage {
  id: string | null;
  event: string;
  data: string;
}

/** Split a byte stream into SSE messages. Comments (`: heartbeat`) are dropped. */
export async function* parseSse(body: ReadableStream<Uint8Array>): AsyncGenerator<SseMessage> {
  const decoder = new TextDecoder();
  const reader = body.getReader();
  let buffer = "";

  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      buffer += decoder.decode(value, { stream: true });

      let split: number;
      // A message ends at a blank line; \r\n is legal and Managoat sends \n.
      while ((split = indexOfBoundary(buffer)) !== -1) {
        const { chunk, length } = boundaryAt(buffer, split);
        buffer = buffer.slice(split + length);
        const message = parseChunk(chunk);
        if (message) yield message;
      }
    }
  } finally {
    // A consumer that breaks out mid-turn must not leave the socket open.
    try {
      await reader.cancel();
    } catch {
      // Already closed, or the peer went away first.
    }
    reader.releaseLock();
  }

  const tail = parseChunk(buffer);
  if (tail) yield tail;
}

function indexOfBoundary(buffer: string): number {
  const lf = buffer.indexOf("\n\n");
  const crlf = buffer.indexOf("\r\n\r\n");
  if (lf === -1) return crlf;
  if (crlf === -1) return lf;
  return Math.min(lf, crlf);
}

function boundaryAt(buffer: string, index: number): { chunk: string; length: number } {
  const isCrlf = buffer.startsWith("\r\n\r\n", index);
  return { chunk: buffer.slice(0, index), length: isCrlf ? 4 : 2 };
}

function parseChunk(chunk: string): SseMessage | null {
  let id: string | null = null;
  let event = "message";
  const data: string[] = [];

  for (const rawLine of chunk.split("\n")) {
    const line = rawLine.endsWith("\r") ? rawLine.slice(0, -1) : rawLine;
    if (!line || line.startsWith(":")) continue; // heartbeat comment
    const colon = line.indexOf(":");
    const field = colon === -1 ? line : line.slice(0, colon);
    let value = colon === -1 ? "" : line.slice(colon + 1);
    if (value.startsWith(" ")) value = value.slice(1);

    if (field === "id") id = value;
    else if (field === "event") event = value;
    else if (field === "data") data.push(value);
  }

  if (!data.length && id === null) return null;
  return { id, event, data: data.join("\n") };
}

export interface StreamOptions {
  /** Resume after this event id. `0` replays the conversation from the start. */
  after?: number;
  signal?: AbortSignal;
  /** How long one connection may sit idle before it is retried. */
  idleTimeoutMs?: number;
  /** Give up reconnecting after this many consecutive failures. */
  maxRetries?: number;
  /** Wait between reconnects, in ms. Exposed so tests do not sleep. */
  retryDelayMs?: number;
  /** Which streams to carry. Omitted means everything. */
  streams?: string;
  /** `false` drains the buffered events and closes instead of tailing live. */
  wait?: boolean;
  /**
   * Ask for server-parsed `blocks` on each event.
   *
   * Every SSE endpoint takes it, so the wrappers here send it by default and
   * a caller only sets this to stream the runtime's raw dialect instead.
   */
  blocks?: boolean;
}

/**
 * The conversation's log feed as an async iterable of `LogEvent`, reconnecting
 * on its own.
 *
 * The reconnect is not decoration. A Managoat deploy, a sandbox wake or an
 * ordinary proxy timeout will end an SSE connection mid-turn; without a cursor
 * the next connection either replays what the caller already saw or misses
 * what arrived in the gap. `Last-Event-ID` is Managoat's answer — the server
 * replays buffered events after that id, then tails live — so this loop tracks
 * the last id it yielded and resumes there. A caller never sees the seam.
 */
export function streamEvents(
  http: HttpClient,
  conversationId: string,
  opts: StreamOptions = {},
): AsyncGenerator<LogEvent> {
  // A conversation stream supports blocks, and a turn cannot be followed
  // without them, so it is the default here.
  return streamPath(http, `/api/conversations/${conversationId}/stream`, {
    blocks: true,
    ...opts,
  });
}

/**
 * The same reader, pointed at any of Managoat's SSE endpoints: one
 * conversation, or every conversation the caller owns
 * (`/api/events/stream`). They share a format, a cursor header and
 * a heartbeat, so they share this loop.
 */
export async function* streamPath(
  http: HttpClient,
  path: string,
  opts: StreamOptions = {},
): AsyncGenerator<LogEvent> {
  let lastId = opts.after ?? 0;
  let attempt = 0;
  const maxRetries = opts.maxRetries ?? 5;
  const retryDelayMs = opts.retryDelayMs ?? 500;

  while (true) {
    let response: Response;
    try {
      response = await http.raw("GET", path, {
        query: {
          blocks: opts.blocks ? "true" : undefined,
          streams: opts.streams,
          wait: opts.wait === false ? "false" : undefined,
        },
        headers: lastId > 0 ? { "Last-Event-ID": String(lastId) } : {},
        accept: "text/event-stream",
        signal: opts.signal,
        // The stream is meant to be held open; a request timeout would kill it.
        timeoutMs: 0,
      });
    } catch (error) {
      if (opts.signal?.aborted) return;
      if (++attempt > maxRetries) throw error;
      await delay(retryDelayMs * attempt, opts.signal);
      continue;
    }

    if (!response.ok) {
      const text = await response.text().catch(() => "");
      // 4xx will not fix itself: a bad key or a conversation this account
      // cannot see returns the same answer however many times we ask.
      if (response.status < 500 || ++attempt > maxRetries) {
        throw errorForStatus(response.status, text ? safeJson(text) : null, "GET", path, response.headers);
      }
      await delay(retryDelayMs * attempt, opts.signal);
      continue;
    }

    if (!response.body) {
      throw new ManagoatError("SSE response had no body");
    }

    attempt = 0;
    try {
      for await (const message of parseSse(response.body)) {
        if (opts.signal?.aborted) return;
        const id = Number(message.id);
        if (Number.isFinite(id) && id > 0) lastId = id;
        const event = decodeEvent(message);
        if (event) yield event;
      }
    } catch (error) {
      if (opts.signal?.aborted) return;
      if (++attempt > maxRetries) throw error;
      await delay(retryDelayMs * attempt, opts.signal);
      continue;
    }

    // A drain closes on purpose; there is nothing to reconnect to.
    if (opts.wait === false) return;

    // The connection ended. Managoat closes an idle stream after 60s, which is
    // normal for a conversation between turns — reconnect from the cursor.
    if (opts.signal?.aborted) return;
    if (++attempt > maxRetries) return;
    await delay(retryDelayMs, opts.signal);
  }
}

function decodeEvent(message: SseMessage): LogEvent | null {
  if (!message.data) return null;
  let payload: unknown;
  try {
    payload = JSON.parse(message.data);
  } catch {
    return null;
  }
  if (!payload || typeof payload !== "object") return null;
  const event = payload as LogEvent;
  const id = Number(message.id);
  if (Number.isFinite(id) && id > 0) event.id = id;
  if (!event.kind && (message.event === "output" || message.event === "stage")) {
    event.kind = message.event;
  }
  return event;
}

function safeJson(text: string): unknown {
  try {
    return JSON.parse(text);
  } catch {
    return text;
  }
}

function delay(ms: number, signal?: AbortSignal): Promise<void> {
  return new Promise((resolve) => {
    if (signal?.aborted) return resolve();
    const timer = setTimeout(done, ms);
    // Never hold the process open on a retry sleep.
    timer.unref?.();
    function done() {
      signal?.removeEventListener("abort", done);
      clearTimeout(timer);
      resolve();
    }
    signal?.addEventListener("abort", done, { once: true });
  });
}
