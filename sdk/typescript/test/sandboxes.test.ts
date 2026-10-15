import { test, describe, before, after, beforeEach } from "node:test";
import assert from "node:assert/strict";
import { FakeFountain } from "./server.ts";
import { Managoat } from "../src/index.ts";
import { NotFoundError } from "../src/errors.ts";

let fake: FakeFountain;
let baseUrl: string;

const client = (): Managoat => new Managoat({ baseUrl, apiKey: "fk_test" });

const SANDBOX = "cccccccc-1111-1111-1111-111111111111";

before(async () => {
  fake = new FakeFountain();
  baseUrl = await fake.start();
});

after(async () => {
  await fake.stop();
});

beforeEach(() => {
  fake.sandboxes = [{ id: SANDBOX, machine_name: "fountain-abc", sprite_name: "fountain-abc", status: "ready", conversations: [] }];
  fake.requests.length = 0;
});

describe("a sandbox's disk (ADR 0039)", () => {
  test("sandboxes and sandbox address the machine by id", async () => {
    const rows = await client().sandboxes({ status: ["ready", "suspended"] });
    assert.equal(rows[0]?.id, SANDBOX);
    assert.equal(fake.requests[0]?.query.get("status"), "ready,suspended");

    const one = await client().sandbox(SANDBOX);
    assert.equal(one.status, "ready");
  });

  test("sandboxFiles, sandboxFile and sandboxDiff hit the three routes with the API's names", async () => {
    fake.disk.files = {
      path: "/home/sprite/src",
      entries: [{ name: "lib", type: "directory", size: null }, { name: "app.ex", type: "file", size: 12 }],
      truncated: false,
    };
    fake.disk.file = {
      path: "/home/sprite/src/app.ex",
      size: 12,
      truncated: true,
      encoding: "utf-8",
      content: "defmodule",
    };
    fake.disk.diff = {
      path: "/home/sprite",
      repo_root: "/home/sprite",
      staged: true,
      ref: "main",
      diff: "diff --git a/x b/x\n",
      truncated: false,
    };

    const c = client();
    const listing = await c.sandboxFiles(SANDBOX, "src");
    assert.equal(listing.entries.length, 2);
    assert.equal(listing.entries[0]?.type, "directory");

    const file = await c.sandboxFile(SANDBOX, "src/app.ex", { maxBytes: 9 });
    assert.equal(file.content, "defmodule");
    assert.equal(file.truncated, true);

    const diff = await c.sandboxDiff(SANDBOX, { staged: true, ref: "main", maxBytes: 1000 });
    assert.equal(diff.staged, true);
    assert.match(diff.diff, /^diff --git/);

    const [files, one, d] = fake.requests;
    assert.equal(files?.path, `/api/sandboxes/${SANDBOX}/files`);
    assert.equal(files?.query.get("path"), "src");
    assert.equal(one?.path, `/api/sandboxes/${SANDBOX}/file`);
    assert.equal(one?.query.get("path"), "src/app.ex");
    assert.equal(one?.query.get("max_bytes"), "9");
    assert.equal(d?.path, `/api/sandboxes/${SANDBOX}/diff`);
    assert.equal(d?.query.get("staged"), "true");
    assert.equal(d?.query.get("ref"), "main");
    assert.equal(d?.query.get("max_bytes"), "1000");
    // An option left out is left off the wire, not sent as "undefined".
    assert.equal(d?.query.has("path"), false);
  });

  test("sandboxGitStatus reports what a diff cannot: a file made and never staged", async () => {
    fake.disk["git-status"] = {
      path: "/home/sprite/repo",
      repo_root: "/home/sprite/repo",
      branch: "main",
      untracked: "all",
      entries: [
        { path: "notes.md", index: "untracked", worktree: "untracked", renamed_from: null },
        { path: "lib/new.ex", index: "renamed", worktree: "unchanged", renamed_from: "lib/old.ex" },
      ],
      truncated: false,
    };

    const status = await client().sandboxGitStatus(SANDBOX, { path: "repo", untracked: "all" });

    assert.equal(status.branch, "main");
    assert.equal(status.entries?.[0]?.index, "untracked");
    assert.equal(status.entries?.[1]?.renamed_from, "lib/old.ex");
    // Relative to repo_root, not to the sandbox home.
    assert.equal(status.entries?.[0]?.path, "notes.md");

    const [req] = fake.requests;
    assert.equal(req?.path, `/api/sandboxes/${SANDBOX}/git-status`);
    assert.equal(req?.query.get("path"), "repo");
    assert.equal(req?.query.get("untracked"), "all");
  });

  test("an unknown sandbox is a NotFoundError on the disk routes too", async () => {
    await assert.rejects(client().sandboxFiles("nope"), NotFoundError);
  });
});
