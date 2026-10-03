import { test, describe, before, after, beforeEach } from "node:test";
import assert from "node:assert/strict";
import { FakeFountain } from "./server.ts";
import { Fountain, type AgentInput } from "../src/index.ts";
import { NotFoundError, ValidationError } from "../src/errors.ts";

let fake: FakeFountain;
let baseUrl: string;

const client = (): Fountain => new Fountain({ baseUrl, apiKey: "fk_test" });

before(async () => {
  fake = new FakeFountain();
  baseUrl = await fake.start();
});

after(async () => {
  await fake.stop();
});

beforeEach(() => {
  fake.agents = [
    { id: "11111111-1111-1111-1111-111111111111", name: "reposage", runtime: "claude", model: "opus" },
  ];
  fake.vaults = [{ id: "aaaaaaaa-1111-1111-1111-111111111111", name: "github-bot" }];
  fake.environments = [{ id: "bbbbbbbb-1111-1111-1111-111111111111", name: "monorepo" }];
  fake.secrets.clear();
  fake.requests.length = 0;
});

/** The definition the docs show — every field an agent has, in one object. */
const DEFINITION: AgentInput = {
  name: "reposage",
  runtime: "claude",
  model: "anthropic/claude-sonnet-5",
  description: "Reads a repository and answers questions about it",
  system: "You are a careful reader of other people's code.",
  environment_id: "bbbbbbbb-1111-1111-1111-111111111111",
  sandbox_provider: null,
  skills: [
    { source: "obra/superpowers", ref: "v2.1.0" },
    { name: "house-style", content: "# House style\n\nPrefer small diffs." },
  ],
  mcp_servers: { linear: { command: "npx", args: ["-y", "linear-mcp"] } },
  allowed_vault_ids: ["aaaaaaaa-1111-1111-1111-111111111111"],
  allowed_environment_ids: null,
  metadata: { team: "platform" },
};

describe("agents", () => {
  test("a whole definition goes to the wire flat, and comes back", async () => {
    const created = await client().agents.create({ ...DEFINITION, name: "newcomer" });

    assert.equal(created.name, "newcomer");
    assert.equal(created.runtime, "claude");

    const post = fake.requests.find((r) => r.method === "POST" && r.path === "/api/agents");
    // Flat attributes — not wrapped under an `agent` key, which the server rejects.
    assert.deepEqual(post?.body, { ...DEFINITION, name: "newcomer" });
  });

  test("a name is usable the moment it exists", async () => {
    const fountain = client();
    // Warm the resolver's memo so the create has something stale to invalidate.
    await fountain.agents.list();

    await fountain.agents.create({ ...DEFINITION, name: "brand-new" });
    const found = await fountain.agents.get("brand-new");
    assert.equal(found.name, "brand-new");
  });

  test("update touches only what it is given", async () => {
    const fountain = client();
    const updated = await fountain.agents.update("reposage", { model: "anthropic/claude-opus-5" });

    assert.equal(updated.model, "anthropic/claude-opus-5");
    assert.equal(updated.runtime, "claude", "untouched fields survive");

    const patch = fake.requests.find((r) => r.method === "PATCH");
    assert.deepEqual(patch?.body, { model: "anthropic/claude-opus-5" });
    assert.match(String(patch?.path), /^\/api\/agents\/11111111-/, "resolved the name to an id");
  });

  test("a rename is visible to the next lookup", async () => {
    const fountain = client();
    await fountain.agents.get("reposage");
    await fountain.agents.update("reposage", { name: "repo-sage" });

    const found = await fountain.agents.get("repo-sage");
    assert.equal(found.name, "repo-sage");
  });

  test("delete removes it, and the account listing agrees", async () => {
    const fountain = client();
    await fountain.agents.delete("reposage");
    assert.deepEqual(await fountain.agents.list(), []);
  });

  test("a definition without a name is rejected by the API, not the SDK", async () => {
    await assert.rejects(
      () => client().agents.create({ runtime: "claude", model: "anthropic/x" } as AgentInput),
      (error: unknown) => {
        assert.ok(error instanceof ValidationError);
        assert.equal(error.status, 422);
        return true;
      },
    );
  });
});

describe("environments and their secrets", () => {
  test("create an environment with repos and an egress allowlist", async () => {
    const env = await client().environments.create({
      name: "monorepo-ci",
      packages: { apt: ["ripgrep"] },
      env_vars: { CI: "true" },
      setup_script: "mix deps.get",
      networking_type: "limited",
      networking_config: { allowed_hosts: ["github.com", "hex.pm"] },
      repositories: [{ url: "https://github.com/managoat/fountain", mount_path: "/work" }],
    });

    assert.equal(env.name, "monorepo-ci");
    const post = fake.requests.find((r) => r.method === "POST" && r.path === "/api/environments");
    assert.equal((post?.body as Record<string, unknown>).networking_type, "limited");
  });

  test("a secret goes in by name and never comes back out", async () => {
    const fountain = client();
    await fountain.environments.secrets.set("monorepo", "HEX_API_KEY", "super-secret");

    const listed = await fountain.environments.secrets.list("monorepo");
    assert.deepEqual(listed.map((s) => s.key), ["HEX_API_KEY"]);
    // The whole point: the SDK can put a credential in and cannot read it back.
    assert.equal(JSON.stringify(listed).includes("super-secret"), false);
  });

  test("setAll stores several, and delete takes the key", async () => {
    const fountain = client();
    await fountain.vaults.secrets.setAll("github-bot", {
      GITHUB_TOKEN: "ghp_x",
      GITHUB_USER: "bot",
    });
    assert.equal((await fountain.vaults.secrets.list("github-bot")).length, 2);

    await fountain.vaults.secrets.delete("github-bot", "GITHUB_USER");
    assert.deepEqual(
      (await fountain.vaults.secrets.list("github-bot")).map((s) => s.key),
      ["GITHUB_TOKEN"],
    );

    const del = fake.requests.find((r) => r.method === "DELETE");
    assert.match(String(del?.path), /\/secrets\/GITHUB_USER$/, "the key is the path segment");
  });

  test("secrets on something that does not exist say so", async () => {
    await assert.rejects(
      () => client().vaults.secrets.set("aaaaaaaa-0000-0000-0000-000000000000", "K", "v"),
      NotFoundError,
    );
  });
});

describe("connections", () => {
  const CONNECTION = {
    id: "cccccccc-1111-1111-1111-111111111111",
    provider: "google",
    account_email: "me@example.com",
    scopes: ["openid", "email", "https://www.googleapis.com/auth/gmail.modify"],
    env_key: "GOOGLE_ACCESS_TOKEN",
    status: "active",
    expires_at: null,
    revoked_at: null,
    created_at: "2026-08-25T00:00:00Z",
    updated_at: "2026-08-25T00:00:00Z",
  };

  test("list, get, providers and delete", async () => {
    fake.connections = [CONNECTION];
    const fountain = client();

    const all = await fountain.connections.list();
    assert.equal(all.length, 1);
    assert.equal(all[0]?.account_email, "me@example.com");

    const one = await fountain.connections.get(CONNECTION.id);
    assert.equal(one.env_key, "GOOGLE_ACCESS_TOKEN");
    assert.equal(one.status, "active");

    const [google] = await fountain.connections.providers.list();
    assert.equal(google?.id, "google");
    assert.equal(google?.platform, true);
    assert.match(String(google?.connect_url), /\/connections\/google\/start$/);

    await fountain.connections.delete(CONNECTION.id);
    assert.equal(fake.connections.length, 0);
    await assert.rejects(() => fountain.connections.get(CONNECTION.id), NotFoundError);
  });
});

describe("connection providers", () => {
  test("create, get, update, discover and delete a tenant provider", async () => {
    const fountain = client();

    const github = await fountain.connections.providers.create({
      kind: "oauth2",
      slug: "github",
      name: "GitHub",
      authorize_url: "https://github.com/login/oauth/authorize",
      token_url: "https://github.com/login/oauth/access_token",
      client_id: "Iv1.abc",
      client_secret: "shh",
      token_hosts: ["api.github.com"],
    });
    assert.equal(github.slug, "github");
    assert.equal(github.platform, false);
    assert.equal((github as Record<string, unknown>).client_secret, undefined);

    const all = await fountain.connections.providers.list();
    assert.deepEqual(
      all.map((p) => p.id),
      ["google", github.id],
    );
    assert.equal((await fountain.connections.providers.get("google")).platform, true);

    const renamed = await fountain.connections.providers.update(github.id, { name: "GH" });
    assert.equal(renamed.name, "GH");

    const mcp = await fountain.connections.providers.create({ kind: "mcp", mcp_url: "https://mcp.test/mcp" });
    assert.equal(mcp.client_source, "dcr");
    assert.equal((await fountain.connections.providers.discover(mcp.id)).id, mcp.id);

    await fountain.connections.providers.delete(github.id);
    await assert.rejects(() => fountain.connections.providers.get(github.id), NotFoundError);
  });
});

describe("vaults", () => {
  test("create and read back", async () => {
    const fountain = client();
    const vault = await fountain.vaults.create({ name: "staging", description: "staging creds" });
    assert.equal(vault.name, "staging");
    assert.equal((await fountain.vaults.get("staging")).description, "staging creds");
  });
});

describe("vault expiry metadata", () => {
  test("sends only metadata with PATCH and preserves explicit null", async () => {
    const requests: { url: string; init?: RequestInit }[] = [];
    const fountain = new Fountain({
      baseUrl: "https://fountain.test", apiKey: "fk_test",
      fetch: async (url, init) => {
        requests.push({ url, init });
        return Response.json({ data: { id: "secret-id", key: "TOKEN", vault_id: "aaaaaaaa-1111-1111-1111-111111111111", expires_at: null } });
      },
    });
    const secret = await fountain.vaults.secrets.update("aaaaaaaa-1111-1111-1111-111111111111", "TOKEN", { expires_at: null });
    assert.equal(secret.expires_at, null);
    assert.equal(requests.length, 1);
    assert.equal(requests[0]!.init?.method, "PATCH");
    assert.equal(new URL(requests[0]!.url).pathname, "/api/vaults/aaaaaaaa-1111-1111-1111-111111111111/secrets/TOKEN");
    assert.deepEqual(JSON.parse(String(requests[0]!.init?.body)), { expires_at: null });
    await fountain.vaults.secrets.update("aaaaaaaa-1111-1111-1111-111111111111", "TOKEN", {});
    assert.deepEqual(JSON.parse(String(requests[1]!.init?.body)), {});
  });

  test("conversation sandbox filter reaches the public query alongside roots_only", async () => {
    let requested = "";
    const fountain = new Fountain({
      baseUrl: "https://fountain.test", apiKey: "fk_test",
      fetch: async (url) => { requested = url; return Response.json({ data: [] }); },
    });
    await fountain.conversations({ sandboxId: "sandbox-id" });
    const url = new URL(requested);
    assert.equal(url.searchParams.get("sandbox_id"), "sandbox-id");
    assert.equal(url.searchParams.get("roots_only"), "true");
  });

  test("a label filter goes out as a repeated key, not a joined string", async () => {
    let requested = "";
    const fountain = new Fountain({
      baseUrl: "https://fountain.test", apiKey: "fk_test",
      fetch: async (url) => { requested = url; return Response.json({ data: [] }); },
    });
    await fountain.conversations({ labels: { env: "prod", drift: "true" } });
    const url = new URL(requested);
    assert.deepEqual(url.searchParams.getAll("label").sort(), ["drift:true", "env:prod"]);
  });

  test("setLabels merges through PATCH and returns the record", async () => {
    const requests: { url: string; init?: RequestInit }[] = [];
    const fountain = new Fountain({
      baseUrl: "https://fountain.test", apiKey: "fk_test",
      fetch: async (url, init) => {
        requests.push({ url, init });
        return Response.json({ data: { id: "c1", labels: { env: "prod" } } });
      },
    });
    const record = await fountain.resume("c1").setLabels({ env: "prod", drift: null });
    assert.deepEqual(record.labels, { env: "prod" });
    assert.equal(requests[0]!.init?.method, "PATCH");
    assert.equal(new URL(requests[0]!.url).pathname, "/api/conversations/c1/labels");
    assert.deepEqual(JSON.parse(String(requests[0]!.init?.body)), {
      labels: { env: "prod", drift: null },
    });
  });

  test("wake posts to the conversation and returns its status", async () => {
    const requests: { url: string; init?: RequestInit }[] = [];
    const fountain = new Fountain({
      baseUrl: "https://fountain.test", apiKey: "fk_test",
      fetch: async (url, init) => {
        requests.push({ url, init });
        return Response.json({ status: "waking" });
      },
    });
    assert.equal(await fountain.resume("c1").wake(), "waking");
    assert.equal(requests[0]!.init?.method, "POST");
    assert.equal(new URL(requests[0]!.url).pathname, "/api/conversations/c1/wake");
  });
});
