import { test } from "node:test";
import assert from "node:assert/strict";
import { streamPath } from "../src/sse.ts";
import type { HttpClient } from "../src/http.ts";

for (const outageMs of [30_000, 120_000]) {
  test(`recovers through ${outageMs}ms outage with cursor and no duplicate events`, async (t) => {
    let elapsed = 0;
    t.mock.method(performance, "now", () => elapsed);
    let calls = 0;
    const frame = (id: number) => `id: ${id}\nevent: output\ndata: {"kind":"output","id":${id}}\n\n`;
    const http = { async raw(method: string, _path: string, options: { headers: Record<string,string> }) {
      assert.equal(method, "GET");
      calls++;
      if (calls === 1) return new Response(frame(7));
      assert.equal(options.headers["Last-Event-ID"], "7");
      elapsed += 5000;
      if (elapsed < outageMs) return new Response("no available server", { status: 503 });
      return new Response(frame(7) + frame(8));
    }} as unknown as HttpClient;
    const ids: number[] = [];
    for await (const event of streamPath(http, "/stream", { retryDelayMs: 0 })) {
      ids.push(event.id!);
      if (event.id === 8) break;
    }
    assert.deepEqual(ids, [7, 8]);
    assert.ok(calls > 5);
  });
}

test("empty successful connections cannot reset the elapsed recovery budget", async (t) => {
  let elapsed = 0;
  t.mock.method(performance, "now", () => elapsed);
  const http = { async raw() { elapsed += 10_000; return new Response(""); }} as unknown as HttpClient;
  await assert.rejects(async () => {
    for await (const _ of streamPath(http, "/stream", { recoveryTimeoutMs: 30_000, retryDelayMs: 0 })) {}
  }, /temporarily unavailable/);
  assert.equal(elapsed, 30_000);
});

test("cancellation during reconnect backoff stops attachment", async () => {
  const controller = new AbortController();
  let calls = 0;
  const http = { async raw() { calls++; return new Response("unavailable", {status: 503}); }} as unknown as HttpClient;
  for await (const _ of streamPath(http, "/stream", {signal: controller.signal, onReconnect: () => controller.abort()})) {}
  assert.equal(calls, 1);
});

test("the recovery deadline cancels a hanging attachment request", async () => {
  const http = { raw(_method: string, _path: string, options: { signal: AbortSignal }) {
    return new Promise((_resolve, reject) => options.signal.addEventListener("abort", () => reject(new Error("aborted")), { once: true }));
  }} as unknown as HttpClient;
  await assert.rejects(async () => {
    for await (const _ of streamPath(http, "/stream", { recoveryTimeoutMs: 10, retryDelayMs: 0 })) {}
  }, /temporarily unavailable/);
});
