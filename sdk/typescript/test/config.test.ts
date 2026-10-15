import { test, describe, beforeEach, afterEach } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync, rmSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
// Importing the Node entry is what installs the credentials-file reader; the
// browser entry deliberately has none. Doing it here tests that wiring too.
import "../src/node.ts";
import { resolveConfig, conversationUrl, DEFAULT_BASE_URL } from "../src/config.ts";
import { HttpClient, USER_AGENT } from "../src/http.ts";

const VARS = [
  "FOUNTAIN_API_KEY",
  "FOUNTAIN_TOKEN",
  "FOUNTAIN_BASE_URL",
  "FOUNTAIN_PROFILE",
  "FOUNTAIN_APP_URL",
  "FOUNTAIN_CONVERSATION_ID",
  "FOUNTAIN_CREDENTIALS_FILE",
];

let saved: Record<string, string | undefined> = {};
let dir: string;

beforeEach(() => {
  saved = Object.fromEntries(VARS.map((name) => [name, process.env[name]]));
  for (const name of VARS) delete process.env[name];
  dir = mkdtempSync(join(tmpdir(), "fountain-sdk-"));
});

afterEach(() => {
  for (const [name, value] of Object.entries(saved)) {
    if (value === undefined) delete process.env[name];
    else process.env[name] = value;
  }
  rmSync(dir, { recursive: true, force: true });
});

function credentials(contents: string): string {
  const path = join(dir, "credentials");
  writeFileSync(path, contents);
  process.env.FOUNTAIN_CREDENTIALS_FILE = path;
  return path;
}

describe("browser safety", () => {
  test("the browser entry pulls in no Node built-in", async () => {
    const { readFileSync } = await import("node:fs");
    const { join, dirname } = await import("node:path");
    const { fileURLToPath } = await import("node:url");
    const src = join(dirname(fileURLToPath(import.meta.url)), "..", "src");

    // Eleven of the applications built on Managoat are browser apps; a bare
    // `import "node:fs"` anywhere reachable from the browser entry breaks
    // their bundles, and it did until the reader was made injectable.
    const files = ["index.ts", "config.ts", "client.ts", "http.ts", "sse.ts",
                   "run.ts", "conversation.ts", "resources.ts", "resolve.ts", "turn.ts", "queue.ts"];
    for (const file of files) {
      const body = readFileSync(join(src, file), "utf8");
      const offending = body.match(/^\s*import[^\n]*["']node:[^"']+["']/m);
      assert.equal(offending, null, `${file} imports a Node built-in: ${offending?.[0]}`);
    }
  });
});

describe("resolveConfig", () => {
  test("an explicit option beats everything", () => {
    process.env.FOUNTAIN_API_KEY = "from-env";
    const config = resolveConfig({ apiKey: "explicit", baseUrl: "https://self.hosted/" });
    assert.equal(config.apiKey, "explicit");
    assert.equal(config.baseUrl, "https://self.hosted", "trailing slash is trimmed");
  });

  test("FOUNTAIN_TOKEN is the in-sandbox fallback", () => {
    process.env.FOUNTAIN_TOKEN = "sandbox-token";
    assert.equal(resolveConfig().apiKey, "sandbox-token");
  });

  test("FOUNTAIN_API_KEY wins over FOUNTAIN_TOKEN", () => {
    process.env.FOUNTAIN_TOKEN = "sandbox-token";
    process.env.FOUNTAIN_API_KEY = "my-key";
    assert.equal(resolveConfig().apiKey, "my-key");
  });

  test("reads the profile the CLI wrote, quotes and all", () => {
    credentials('[default]\napi_key = "fk_default"\nbase_url = "https://one.example"\n\n[work]\napi_key = fk_work\nbase_url = https://two.example\n');
    const fallback = resolveConfig();
    assert.equal(fallback.apiKey, "fk_default");
    assert.equal(fallback.baseUrl, "https://one.example");

    const work = resolveConfig({ profile: "work" });
    assert.equal(work.apiKey, "fk_work");
    assert.equal(work.baseUrl, "https://two.example");
  });

  test("an unknown profile contributes nothing, and is not an error", () => {
    credentials("[default]\napi_key = fk_default\n");
    const config = resolveConfig({ profile: "nope" });
    assert.equal(config.apiKey, "");
    assert.equal(config.baseUrl, DEFAULT_BASE_URL);
  });

  test("a missing credentials file is not an error", () => {
    process.env.FOUNTAIN_CREDENTIALS_FILE = join(dir, "does-not-exist");
    assert.equal(resolveConfig().apiKey, "");
  });

  test("running inside a sandbox records the parent conversation", () => {
    process.env.FOUNTAIN_CONVERSATION_ID = "conv-parent";
    assert.equal(resolveConfig().parentConversationId, "conv-parent");
    delete process.env.FOUNTAIN_CONVERSATION_ID;
    assert.equal(resolveConfig().parentConversationId, undefined);
  });
});

describe("conversationUrl", () => {
  test("points at the conversations app", () => {
    const config = resolveConfig({ appUrl: "https://app.example/c/" });
    assert.equal(conversationUrl("abc", config), "https://app.example/c/#/c/abc");
  });

  test("a deployment with no app falls back to something fetchable", () => {
    const config = resolveConfig({ baseUrl: "https://self.hosted", appUrl: "" });
    assert.equal(conversationUrl("abc", config), "https://self.hosted/api/conversations/abc");
  });
});

describe("the version the server sees", () => {
  // `USER_AGENT` is a literal, because importing package.json would need a JSON
  // import attribute in every consumer's bundler. A literal drifts silently, so
  // it is asserted instead: bump the version, and this says where else to.
  test("USER_AGENT carries the published version", () => {
    const pkg = JSON.parse(readFileSync(new URL("../package.json", import.meta.url), "utf8"));
    assert.equal(USER_AGENT, `fountain-sdk-js/${pkg.version}`);
  });

  // Firefox forwards a page-set User-Agent, which makes every call a CORS
  // preflight for a header Managoat's allow-list may not name. A browser
  // already has one; only a non-browser runtime should add the token.
  test("the header is sent from Node and not from a page", () => {
    const client = new HttpClient(resolveConfig({ apiKey: "ftn_x", baseUrl: "https://f.example" }));
    assert.equal(client.headers()["User-Agent"], USER_AGENT);
    const g = globalThis as { document?: unknown };
    g.document = {};
    try {
      assert.equal(client.headers()["User-Agent"], undefined);
    } finally {
      delete g.document;
    }
  });
});
