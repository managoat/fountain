import { test } from "node:test";
import assert from "node:assert/strict";
import { webcrypto } from "node:crypto";
import {
  createAuth,
  challenge,
  serverURL,
} from "../../apps/fountain/priv/account_app/auth.mjs";
globalThis.crypto ??= webcrypto;
function fixture() {
  const values = new Map(),
    calls = [];
  const storage = {
    getItem: (k) => values.get(k) || null,
    setItem: (k, v) => values.set(k, v),
    removeItem: (k) => values.delete(k),
  };
  const location = {
    origin: "https://account.example",
    pathname: "/",
    search: "",
    assign(url) {
      this.assigned = url;
    },
  };
  let status = 200;
  const fetcher = async (url, options) => {
    calls.push({ url, options });
    return {
      ok: status < 400,
      status,
      json: async () =>
        status === 200
          ? { access_token: "test-token", expires_in: 60 }
          : { error: "expired" },
    };
  };
  const auth = createAuth({
    storage,
    location,
    history: { replaceState() {} },
    fetcher,
    now: () => 1000,
  });
  return {
    auth,
    calls,
    values,
    location,
    fail() {
      status = 401;
    },
  };
}
async function signIn(f) {
  await f.auth.begin("https://server.example", "connections");
  const state = new URL(f.location.assigned).searchParams.get("state");
  f.location.search = `?code=authorization-code&state=${state}`;
  assert.equal(await f.auth.complete(), "connections");
}
test("PKCE matches the RFC 7636 vector", async () => {
  assert.equal(
    await challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
    "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM",
  );
});
test("server validation rejects credentials, paths, insecure remote URLs and active schemes", () => {
  for (const url of [
    "javascript:alert(1)",
    "https://a:b@example.com",
    "https://example.com/path",
    "https://example.com?token=x",
    "http://example.com",
  ])
    assert.throws(() => serverURL(url));
  assert.equal(serverURL("http://localhost:4000"), "http://localhost:4000");
});
test("state mismatch never exchanges a code", async () => {
  const f = fixture();
  await f.auth.begin("https://server.example");
  f.location.search = "?code=bad&state=wrong";
  await assert.rejects(f.auth.complete(), /did not start/);
  assert.equal(f.calls.length, 0);
  assert.equal(f.auth.session(), null);
});
test("callback is single-use and API requests are bound to the authenticated server", async () => {
  const f = fixture();
  await signIn(f);
  const tokenBody = JSON.parse(f.calls[0].options.body);
  assert.equal(tokenBody.redirect_uri, "https://account.example/");
  assert.equal(tokenBody.client_id, "managoat-account");
  assert.ok(tokenBody.code_verifier.length >= 43);
  await f.auth.request("/api/auth/me");
  assert.equal(f.calls[1].url, "https://server.example/api/auth/me");
  assert.equal(f.calls[1].options.headers.Authorization, "Bearer test-token");
  assert.equal(f.calls[1].options.credentials, "omit");
  assert.equal(f.calls[1].options.redirect, "error");
  await assert.rejects(f.auth.complete(), /did not start/);
});
test("401 clears the session; expired tokens are not reused", async () => {
  const f = fixture();
  await signIn(f);
  f.fail();
  await assert.rejects(f.auth.request("/api/auth/me"), /expired/);
  assert.equal(f.auth.session(), null);
  f.values.set(
    "managoat-account.session",
    JSON.stringify({
      server: "https://server.example",
      token: "expired",
      expires: 999,
    }),
  );
  assert.equal(f.auth.session(), null);
});
test("logout revokes the OAuth key before forgetting it", async () => {
  const f = fixture();
  await signIn(f);
  await f.auth.logout();
  assert.equal(f.calls.at(-1).url, "https://server.example/api/oauth/revoke");
  assert.equal(f.auth.session(), null);
});
test("provider denial consumes pending state without a token request", async () => {
  const f = fixture();
  await f.auth.begin("https://server.example");
  const state = new URL(f.location.assigned).searchParams.get("state");
  f.location.search = `?error=access_denied&state=${state}`;
  await assert.rejects(f.auth.complete(), /declined/);
  assert.equal(f.calls.length, 0);
});
