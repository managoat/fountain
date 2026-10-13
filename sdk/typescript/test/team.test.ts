import { test, describe, before, after, beforeEach } from "node:test";
import assert from "node:assert/strict";
import { FakeFountain } from "./server.ts";
import { Fountain } from "../src/index.ts";
import { ConversationBusyError, NotReadyError, ValidationError } from "../src/errors.ts";

let fake: FakeFountain;
let baseUrl: string;

const AGENT = "11111111-1111-1111-1111-111111111111";
const client = (): Fountain => new Fountain({ baseUrl, apiKey: "fk_test" });

before(async () => {
  fake = new FakeFountain();
  baseUrl = await fake.start();
});
after(async () => {
  await fake.stop();
});

beforeEach(() => {
  fake.agents = [{ id: AGENT, name: "watchtower", runtime: "claude", model: "opus" }];
  fake.teammates.clear();
  fake.schedules.clear();
  fake.conversations.clear();
  fake.busyTeammates.clear();
  fake.requests.length = 0;
  fake.onTurn = null;
});

describe("team", () => {
  test("hire by name, and the roster shows them", async () => {
    const fountain = client();
    const hired = await fountain.team.add("watchtower", { name: "Watchtower" });

    assert.equal(hired.agent_id, AGENT);
    assert.deepEqual((await fountain.team.list()).map((t) => t.name), ["Watchtower"]);

    // The name resolved to an id before it went to the wire.
    const post = fake.requests.find((r) => r.method === "POST" && r.path === "/api/team");
    assert.deepEqual(post?.body, { name: "Watchtower", agent_id: AGENT });
  });

  test("a message is a Run: await it for the reply", async () => {
    fake.onTurn = (conversation, turnNumber) =>
      fake.scriptTurn(conversation.id, {
        turnNumber,
        turnId: `t${turnNumber}`,
        text: ["disks are fine"],
      });

    const fountain = client();
    await fountain.team.add("watchtower");
    const reply = await fountain.team.message("watchtower", "check the disks");

    assert.equal(reply.text, "disks are fine");
    assert.equal(reply.state, "done");
    assert.equal(reply.turnNumber, 1);
  });

  test("a second message is turn 2 of the same thread", async () => {
    fake.onTurn = (conversation, turnNumber) =>
      fake.scriptTurn(conversation.id, {
        turnNumber,
        turnId: `t${turnNumber}`,
        text: [`answer ${turnNumber}`],
      });

    const fountain = client();
    await fountain.team.add("watchtower");
    const first = await fountain.team.message("watchtower", "one");
    const second = await fountain.team.message("watchtower", "two");

    assert.equal(second.turnNumber, 2);
    assert.equal(second.text, "answer 2");
    assert.equal(second.conversationId, first.conversationId, "same standing conversation");
  });

  test("a busy teammate is its own error, not a bare 400", async () => {
    const fountain = client();
    await fountain.team.add("watchtower");
    fake.busyTeammates.add(AGENT);

    await assert.rejects(
      async () => {
        await fountain.team.message("watchtower", "another one");
      },
      (error: unknown) => {
        // The apps all branch on this: it is a 400, so status is useless.
        assert.ok(error instanceof ConversationBusyError);
        assert.equal(error.status, 400);
        assert.equal(error.code, "conversation_busy");
        assert.equal(error.retryable, true);
        return true;
      },
    );
  });

  test("rename, history, a fresh thread and removal", async () => {
    fake.onTurn = (c, n) => fake.scriptTurn(c.id, { turnNumber: n, turnId: `t${n}`, text: ["ok"] });
    const fountain = client();
    await fountain.team.add("watchtower");
    await fountain.team.message("watchtower", "hello");

    const renamed = await fountain.team.rename("watchtower", "Eyes");
    assert.equal(renamed.name, "Eyes");

    assert.equal((await fountain.team.history("watchtower")).length, 1);

    const fresh = await fountain.team.freshConversation("watchtower");
    assert.ok(fresh.id);

    await fountain.team.remove("watchtower");
    assert.deepEqual(await fountain.team.list(), []);
  });

  test("the whole team on one stream", async () => {
    const fountain = client();
    await fountain.team.add("watchtower");
    fake.onTurn = (c, n) => fake.scriptTurn(c.id, { turnNumber: n, turnId: `t${n}`, text: ["hi"] });
    await fountain.team.message("watchtower", "hello");

    const seen: string[] = [];
    const controller = new AbortController();
    for await (const event of fountain.team.stream({ streams: ["stage"], signal: controller.signal })) {
      if (event.kind === "stage" && event.stage === "turn") seen.push(String(event.state));
      if (seen.length === 2) controller.abort();
    }
    assert.deepEqual(seen, ["started", "done"]);

    const stream = fake.requests.find((r) => r.path === "/api/team/stream");
    assert.ok(stream, "used the team stream, not one connection per teammate");
    // #881: the endpoint takes `blocks` now, so a client renders a transcript
    // from this connection instead of re-parsing the runtime's dialect.
    assert.equal(stream.query.get("blocks"), "true");
  });

  test("routines", async () => {
    const fountain = client();
    await fountain.team.add("watchtower");

    const created = await fountain.team.schedules.create("watchtower", {
      cron: "0 9 * * *",
      prompt: "morning check",
    } as never);
    assert.equal((await fountain.team.schedules.list("watchtower")).length, 1);

    await fountain.team.schedules.update("watchtower", created.id as string, { prompt: "evening" } as never);
    await fountain.team.schedules.run("watchtower", created.id as string);
    await fountain.team.schedules.delete("watchtower", created.id as string);
    assert.deepEqual(await fountain.team.schedules.list("watchtower"), []);
  });
});

describe("errors the apps branch on", () => {
  test("a full fleet is not ready yet, and is retryable", async () => {
    fake.failNextWith = { status: 503, body: { error: "fleet_full" }, retryAfter: 60 };
    await assert.rejects(
      () => client().team.list(),
      (error: unknown) => {
        assert.ok(error instanceof NotReadyError);
        assert.equal(error.code, "fleet_full");
        assert.equal(error.retryAfter, 60);
        assert.equal(error.retryable, true);
        return true;
      },
    );
  });

  test("a sandbox still coming up carries the server's Retry-After", async () => {
    fake.failNextWith = { status: 503, body: { error: "provisioning" }, retryAfter: 30 };
    await assert.rejects(
      () => client().team.list(),
      (error: unknown) => {
        assert.ok(error instanceof NotReadyError);
        assert.equal(error.retryAfter, 30);
        assert.equal(error.retryable, true);
        return true;
      },
    );
  });

  test("a 422 exposes the field errors", async () => {
    fake.failNextWith = {
      status: 422,
      body: { errors: { name: ["can't be blank"], model: ["is invalid"] } },
    };
    await assert.rejects(
      () => client().team.list(),
      (error: unknown) => {
        assert.ok(error instanceof ValidationError);
        assert.deepEqual(error.fieldErrors, { name: ["can't be blank"], model: ["is invalid"] });
        assert.equal(error.retryable, false);
        return true;
      },
    );
  });
});

describe("the rest of what the apps use", () => {
  test("catalog and search", async () => {
    const fountain = client();
    assert.deepEqual((await fountain.catalog()).runtimes, ["claude", "codex"]);
    assert.equal((await fountain.search("disks")).length, 1);
  });

  test("history drains the feed, and markRead clears the badge", async () => {
    fake.onTurn = (c, n) => fake.scriptTurn(c.id, { turnNumber: n, turnId: `t${n}`, text: ["hi"] });
    const fountain = client();
    await fountain.team.add("watchtower");
    const reply = await fountain.team.message("watchtower", "hello");

    const conversation = fountain.resume(reply.conversationId);
    const events = await conversation.history({ streams: ["acp", "stage"] });
    assert.ok(events.length >= 3, "start, output and done at least");
    assert.ok(events.every((e) => typeof e.id === "number"));

    await conversation.markRead();
    assert.ok(fake.requests.some((r) => r.method === "POST" && r.path.endsWith("/read")));
  });
});
