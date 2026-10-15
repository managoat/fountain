// ADR 0082 renamed the project Managoat. For a deprecation window the SDK
// still answers to the old names: the `Fountain` and `FountainError` exports,
// and the FOUNTAIN_* environment variables.
import { test, describe, beforeEach, afterEach } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import "../src/node.ts";
import Default, { Fountain, FountainError, Managoat, ManagoatError, NotFoundError } from "../src/index.ts";
import { resolveConfig } from "../src/config.ts";

const NAMES = ["API_KEY", "TOKEN", "BASE_URL", "PROFILE", "APP_URL", "CONVERSATION_ID", "CREDENTIALS_FILE"];
const VARS = NAMES.flatMap((n) => [`MANAGOAT_${n}`, `FOUNTAIN_${n}`]);

let saved: Record<string, string | undefined> = {};
let home: string;
let savedHome: string | undefined;

beforeEach(() => {
  saved = Object.fromEntries(VARS.map((name) => [name, process.env[name]]));
  for (const name of VARS) delete process.env[name];
  home = mkdtempSync(join(tmpdir(), "managoat-sdk-legacy-"));
  savedHome = process.env.HOME;
  process.env.HOME = home;
});

afterEach(() => {
  for (const [name, value] of Object.entries(saved)) {
    if (value === undefined) delete process.env[name];
    else process.env[name] = value;
  }
  if (savedHome === undefined) delete process.env.HOME;
  else process.env.HOME = savedHome;
  rmSync(home, { recursive: true, force: true });
});

describe("the deprecated exports", () => {
  test("Fountain is the Managoat class, and the default export is Managoat", () => {
    assert.equal(Fountain, Managoat);
    assert.equal(Default, Managoat);
    assert.ok(new Fountain({ apiKey: "k", baseUrl: "https://x.example" }) instanceof Managoat);
  });

  test("FountainError is ManagoatError, so old catch blocks still match", () => {
    assert.equal(FountainError, ManagoatError);
    assert.ok(new NotFoundError("gone", { status: 404 }) instanceof FountainError);
  });
});

describe("the FOUNTAIN_* variables", () => {
  test("are read when the MANAGOAT_* one is unset", () => {
    process.env.FOUNTAIN_API_KEY = "old-key";
    process.env.FOUNTAIN_BASE_URL = "https://old.example/";
    process.env.FOUNTAIN_CONVERSATION_ID = "conv-1";
    const config = resolveConfig();
    assert.equal(config.apiKey, "old-key");
    assert.equal(config.baseUrl, "https://old.example");
    assert.equal(config.parentConversationId, "conv-1");
  });

  test("lose to the MANAGOAT_* one", () => {
    process.env.FOUNTAIN_API_KEY = "old-key";
    process.env.MANAGOAT_API_KEY = "new-key";
    assert.equal(resolveConfig().apiKey, "new-key");
  });

  test("FOUNTAIN_TOKEN still stands in for a key inside an older sandbox", () => {
    process.env.FOUNTAIN_TOKEN = "sandbox-token";
    assert.equal(resolveConfig().apiKey, "sandbox-token");
  });
});

describe("the credentials file", () => {
  const write = (dir: string, key: string) => {
    mkdirSync(join(home, dir), { recursive: true });
    writeFileSync(join(home, dir, "credentials"), `[default]\napi_key = "${key}"\n`);
  };

  test("~/.fountain/credentials is read while ~/.managoat/credentials does not exist", () => {
    write(".fountain", "ftn_old");
    assert.equal(resolveConfig().apiKey, "ftn_old");
  });

  test("~/.managoat/credentials wins once it exists", () => {
    write(".fountain", "ftn_old");
    write(".managoat", "ftn_new");
    assert.equal(resolveConfig().apiKey, "ftn_new");
  });
});
