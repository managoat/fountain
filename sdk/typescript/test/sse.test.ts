import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { parseSse } from "../src/sse.ts";
import { TurnFollower } from "../src/turn.ts";
import type { LogEvent } from "../src/types.ts";

/** Feed a body to the parser in exactly the chunks given, TCP-style. */
function bodyOf(chunks: string[]): ReadableStream<Uint8Array> {
  const encoder = new TextEncoder();
  return new ReadableStream({
    start(controller) {
      for (const chunk of chunks) controller.enqueue(encoder.encode(chunk));
      controller.close();
    },
  });
}

async function collect(chunks: string[]) {
  const out = [];
  for await (const message of parseSse(bodyOf(chunks))) out.push(message);
  return out;
}

describe("parseSse", () => {
  test("reads id, event and data", async () => {
    const messages = await collect(['id: 7\nevent: output\ndata: {"kind":"output"}\n\n']);
    assert.deepEqual(messages, [{ id: "7", event: "output", data: '{"kind":"output"}' }]);
  });

  test("a message split across packets is still one message", async () => {
    // The failure this guards against is not hypothetical: Managoat's replay
    // buffer cuts at a byte count, so a message arriving in two pieces is the
    // normal case, not the edge one.
    const messages = await collect(["id: 1\neve", "nt: output\ndata: {\"a\":", '1}\n\n']);
    assert.equal(messages.length, 1);
    assert.deepEqual(messages[0], { id: "1", event: "output", data: '{"a":1}' });
  });

  test("heartbeat comments are not messages", async () => {
    const messages = await collect([": heartbeat\n\n", "id: 2\nevent: stage\ndata: {}\n\n"]);
    assert.equal(messages.length, 1);
    assert.equal(messages[0]?.id, "2");
  });

  test("multi-line data joins with newlines", async () => {
    const messages = await collect(["data: one\ndata: two\n\n"]);
    assert.equal(messages[0]?.data, "one\ntwo");
  });

  test("CRLF framing works too", async () => {
    const messages = await collect(["id: 3\r\nevent: output\r\ndata: hi\r\n\r\n"]);
    assert.deepEqual(messages[0], { id: "3", event: "output", data: "hi" });
  });

  test("a final message with no trailing blank line is not dropped", async () => {
    const messages = await collect(["id: 9\nevent: stage\ndata: {}"]);
    assert.equal(messages[0]?.id, "9");
  });
});

const stage = (state: LogEvent["state"], meta: Record<string, unknown>): LogEvent => ({
  id: 1,
  kind: "stage",
  stage: "turn",
  state,
  ts: "2026-08-20T00:00:00Z",
  data: JSON.stringify(meta),
});

const output = (blocks: unknown[], turnId: string, stream: LogEvent["stream"] = "acp"): LogEvent => ({
  id: 2,
  kind: "output",
  stream,
  turn_id: turnId,
  ts: "2026-08-20T00:00:00Z",
  blocks: blocks as LogEvent["blocks"],
});

describe("TurnFollower", () => {
  test("ignores a different turn's lifecycle", () => {
    const follower = new TurnFollower(2);
    follower.apply(stage("started", { turn_number: 1, turn_id: "t1" }));
    assert.equal(follower.started, false);
    follower.apply(stage("done", { turn_number: 1, turn_id: "t1" }));
    assert.equal(follower.finished, false);
  });

  test("thinking is reported but is not the answer", () => {
    const follower = new TurnFollower(1);
    follower.apply(stage("started", { turn_number: 1, turn_id: "t1" }));
    const events = follower.apply(output([{ kind: "thinking", body: "hmm" }], "t1"));
    assert.ok(events.some((e) => e.type === "thinking"));
    assert.equal(follower.text, "");
  });

  test("a result block is the answer only when nothing else was said", () => {
    const follower = new TurnFollower(1);
    follower.apply(stage("started", { turn_number: 1, turn_id: "t1" }));
    follower.apply(output([{ kind: "result", body: "exit 0" }], "t1"));
    assert.equal(follower.text, "exit 0");

    const chatty = new TurnFollower(1);
    chatty.apply(stage("started", { turn_number: 1, turn_id: "t1" }));
    chatty.apply(output([{ kind: "text", body: "All set." }], "t1"));
    chatty.apply(output([{ kind: "result", body: "exit 0" }], "t1"));
    assert.equal(chatty.text, "All set.");
  });

  test("a tool is recorded once, in first-use order", () => {
    const follower = new TurnFollower(1);
    follower.apply(stage("started", { turn_number: 1, turn_id: "t1" }));
    follower.apply(output([{ kind: "tool_use", name: "Bash" }], "t1"));
    follower.apply(output([{ kind: "tool_use", name: "Read" }], "t1"));
    follower.apply(output([{ kind: "tool_use", name: "Bash" }], "t1"));
    assert.deepEqual(follower.toolsUsed, ["Bash", "Read"]);
  });

  test("the terminal stage carries how it ended", () => {
    const follower = new TurnFollower(1);
    follower.apply(stage("started", { turn_number: 1, turn_id: "t1" }));
    follower.apply(stage("failed", { turn_number: 1, turn_id: "t1", exit_code: 2, reason: "oom" }));
    assert.equal(follower.state, "failed");
    assert.equal(follower.exitCode, 2);
    assert.equal(follower.reason, "oom");
  });

  test("a permission request becomes an answerable event", () => {
    const follower = new TurnFollower(1);
    follower.apply(stage("started", { turn_number: 1, turn_id: "t1" }));
    const events = follower.apply(
      output(
        [
          {
            kind: "permission_request",
            request_id: "req-1",
            name: "rm -rf build",
            tool_id: "tool-9",
            summary: "Run rm -rf build",
            options: [
              { optionId: "allow", kind: "allow_once", name: "Allow once" },
              { optionId: "deny", kind: "reject_once", name: "Deny" },
            ],
          },
        ],
        "t1",
      ),
    );

    const ask = events.find((e) => e.type === "permission");
    assert.ok(ask, "a permission_request block must surface as its own event");
    assert.equal(ask.request.requestId, "req-1");
    assert.equal(ask.request.summary, "Run rm -rf build");
    assert.equal(ask.request.toolName, "rm -rf build");
    assert.equal(ask.request.toolId, "tool-9");
    assert.deepEqual(
      ask.request.options.map((o) => o.optionId),
      ["allow", "deny"],
    );
    // Asking is not saying, and it is not a tool the agent got to use.
    assert.equal(follower.text, "");
    assert.deepEqual(follower.toolsUsed, []);
  });

  test("an unanswerable ask is dropped rather than handed over", () => {
    const follower = new TurnFollower(1);
    follower.apply(stage("started", { turn_number: 1, turn_id: "t1" }));

    const noId = follower.apply(
      output([{ kind: "permission_request", options: [{ optionId: "allow" }] }], "t1"),
    );
    assert.equal(noId.some((e) => e.type === "permission"), false);

    const noOptions = follower.apply(
      output([{ kind: "permission_request", request_id: "req-2", options: [] }], "t1"),
    );
    assert.equal(noOptions.some((e) => e.type === "permission"), false);
  });

  test("matches on turn_id once known, even if the turn number drifts", () => {
    const follower = new TurnFollower(3);
    follower.apply(stage("started", { turn_number: 3, turn_id: "t3" }));
    follower.apply(output([{ kind: "text", body: "hi" }], "t3"));
    // A resumed sandbox renumbering its turns must not orphan the follower.
    follower.apply(stage("done", { turn_number: 99, turn_id: "t3" }));
    assert.equal(follower.state, "done");
    assert.equal(follower.text, "hi");
  });
});
