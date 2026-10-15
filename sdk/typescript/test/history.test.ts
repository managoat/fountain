import { test, describe, before, after, beforeEach } from "node:test";
import assert from "node:assert/strict";
import { FakeFountain } from "./server.ts";
import { Managoat, type HistoryOptions, type LogEvent } from "../src/index.ts";

let fake: FakeFountain;
let baseUrl: string;

const client = (): Managoat => new Managoat({ baseUrl, apiKey: "fk_test" });

before(async () => {
  fake = new FakeFountain();
  baseUrl = await fake.start();
});

after(async () => {
  await fake.stop();
});

beforeEach(() => {
  fake.conversations.clear();
  fake.requests.length = 0;
  fake.onTurn = null;
});

/** A conversation of two prompted turns and one autonomous turn between them. */
async function threeTurns(): Promise<string> {
  const id = "conv-history";
  fake.conversations.set(id, {
    id,
    status: "idle",
    agent_id: "11111111-1111-1111-1111-111111111111",
    turn_count: 3,
    events: [],
    turns: [],
  });
  fake.scriptTurn(id, { turnNumber: 1, turnId: "t1", prompt: "Find the N+1 queries.", text: ["Found three."] });
  // Autonomous: nobody typed it, so the server attaches no prompt block.
  fake.scriptTurn(id, { turnNumber: 2, turnId: "t2", text: ["Checked CI on my own."] });
  fake.scriptTurn(id, { turnNumber: 3, turnId: "t3", prompt: "Fix the worst one.", text: ["Fixed."] });
  return id;
}

const pages = () => fake.requests.filter((r) => r.method === "GET" && r.path.endsWith("/events"));

const promptsOf = (events: LogEvent[]): string[] =>
  events.flatMap((event) => (event.blocks ?? []).filter((b) => b.kind === "prompt").map((b) => String(b.body)));

const turnStarts = (events: LogEvent[]): LogEvent[] =>
  events.filter((event) => event.kind === "stage" && event.stage === "turn" && event.state === "started");

describe("history prompts", () => {
  test("is off by default: no prompts param, and turn starts carry no blocks", async () => {
    const id = await threeTurns();

    const events = await client().resume(id).history();

    assert.equal(pages().length, 1);
    assert.equal(pages()[0]!.query.get("blocks"), "true");
    assert.equal(pages()[0]!.query.has("prompts"), false);
    assert.deepEqual(promptsOf(events), []);
    for (const start of turnStarts(events)) assert.deepEqual(start.blocks, []);
  });

  test("prompts: false sends nothing either", async () => {
    const id = await threeTurns();
    await client().resume(id).history({ prompts: false });
    assert.equal(pages()[0]!.query.has("prompts"), false);
  });

  test("prompts: true forwards prompts=true with blocks=true, and keeps the prompt apart from the answer", async () => {
    const id = await threeTurns();

    const events = await client().resume(id).history({ prompts: true });

    assert.equal(pages()[0]!.query.get("blocks"), "true");
    assert.equal(pages()[0]!.query.get("prompts"), "true");
    assert.deepEqual(promptsOf(events), ["Find the N+1 queries.", "Fix the worst one."]);

    // The prompt is on the turn's started stage event, not on its output.
    const [t1, t2, t3] = turnStarts(events);
    assert.deepEqual(t1!.blocks, [{ kind: "prompt", body: "Find the N+1 queries." }]);
    assert.deepEqual(t2!.blocks, [], "an autonomous turn gets no prompt block");
    assert.deepEqual(t3!.blocks, [{ kind: "prompt", body: "Fix the worst one." }]);
    for (const event of events.filter((e) => e.kind === "output")) {
      assert.ok((event.blocks ?? []).every((b) => b.kind === "text"));
    }
  });

  test("multi-page: every page asks for prompts, and ids, order and cursor survive", async () => {
    const id = await threeTurns();
    const everything = await client().resume(id).history();
    fake.requests.length = 0;

    const conversation = client().resume(id);
    const events = await conversation.history({ prompts: true, limit: 2 });

    // 3 turns × 3 events, two to a page.
    assert.equal(pages().length, 5);
    for (const page of pages()) {
      assert.equal(page.query.get("blocks"), "true");
      assert.equal(page.query.get("prompts"), "true");
      assert.equal(page.query.get("limit"), "2");
    }
    assert.deepEqual(
      pages().map((page) => page.query.get("after")),
      ["0", ...everything.slice(1, -1).filter((_, i) => i % 2 === 0).map((e) => String(e.id))],
    );
    assert.deepEqual(events.map((e) => e.id), everything.map((e) => e.id));
    assert.deepEqual(promptsOf(events), ["Find the N+1 queries.", "Fix the worst one."]);
    assert.equal(await conversation.cursor(), everything.at(-1)!.id);
  });

  test("a streams filter is forwarded as given and never widened", async () => {
    const id = await threeTurns();

    const acpOnly = await client().resume(id).history({ prompts: true, streams: ["acp"] });
    assert.equal(pages()[0]!.query.get("streams"), "acp");
    assert.deepEqual(promptsOf(acpOnly), [], "stage events are filtered out, and the prompts with them");

    fake.requests.length = 0;
    const both = await client().resume(id).history({ prompts: true, streams: ["acp", "stage"] });
    assert.equal(pages()[0]!.query.get("streams"), "acp,stage");
    assert.deepEqual(promptsOf(both), ["Find the N+1 queries.", "Fix the worst one."]);
  });

  test("eventPage takes the same flag, off by default", async () => {
    const id = await threeTurns();
    const conversation = client().resume(id);

    const plain = await conversation.eventPage(0, 1000);
    assert.equal(pages()[0]!.query.has("prompts"), false);
    assert.deepEqual(promptsOf(plain.events), []);

    const options: Pick<HistoryOptions, "prompts"> = { prompts: true };
    const first = await conversation.eventPage(0, 3, options);
    assert.equal(pages()[1]!.query.get("prompts"), "true");
    assert.equal(pages()[1]!.query.get("blocks"), "true");
    assert.equal(first.hasMore, true);
    assert.deepEqual(promptsOf(first.events), ["Find the N+1 queries."]);
    assert.equal(first.nextCursor, first.events.at(-1)!.id);
  });
});
