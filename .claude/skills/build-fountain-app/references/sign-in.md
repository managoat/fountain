# Sign in with Managoat (OAuth 2.0 code + PKCE)

This is the `src/lib/oauth.ts` that the workbench and every demo app copied
(it began in the team app, since removed). Change `CLIENT_ID` and the stash key; nothing else.

Facts that shape it (ADR 0021, `docs/api.md`):

- Public client, S256 only, **no client secret, no scope parameter, no refresh token**.
- `redirect_uri` must match a registered entry **exactly** (trailing slash and all). The app's own page with the hash cleared is the convention.
- The code lives 5 minutes and works once. Consent is at `GET /oauth/authorize`; a signed-out user round-trips through login and comes back.
- The `access_token` **is an `ftn_…` API key**: full scope, 30 days, listed under Account → API keys as `oauth:<client_id>`. Store it exactly as you would a pasted key (`localStorage`, `{baseUrl, apiKey, via: "paste" | "oauth"}`), and on sign-out `POST /api/oauth/revoke` when `via === "oauth"`.
- Nothing refreshes. When the key expires, the next 401 sends the person back to sign-in. A 401 should show "That key was not accepted", not loop.
- The token endpoint says `invalid_grant` for every wrong grant and is rate-limited per IP. It never says which check failed.

```ts
import { normalizeBaseUrl } from "./settings";

const CLIENT_ID = "app_xxx";           // from fountain oauth-client create
const STASH = "my-app.oauth";

function base64url(bytes: ArrayBuffer): string {
  let s = "";
  const b = new Uint8Array(bytes);
  for (let i = 0; i < b.length; i++) s += String.fromCharCode(b[i]!);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function randomString(bytes = 32): string {
  const a = new Uint8Array(bytes);
  crypto.getRandomValues(a);
  return base64url(a.buffer);
}

async function challengeFor(verifier: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(verifier));
  return base64url(digest);
}

/** Must match a `redirect_uris` entry registered for the client on the server. */
export function redirectUri(): string {
  return window.location.origin + window.location.pathname;
}

export async function beginLogin(baseUrl: string): Promise<void> {
  const verifier = randomString();
  const state = randomString(16);
  const challenge = await challengeFor(verifier);
  const base = normalizeBaseUrl(baseUrl);
  sessionStorage.setItem(STASH, JSON.stringify({ verifier, state, baseUrl: base }));
  const q = new URLSearchParams({
    client_id: CLIENT_ID,
    redirect_uri: redirectUri(),
    response_type: "code",
    code_challenge: challenge,
    code_challenge_method: "S256",
    state,
  });
  window.location.href = `${base}/oauth/authorize?${q}`;
}

export interface CallbackResult { baseUrl: string; apiKey: string }

/** null when this page load is not an OAuth callback; throws on a real failure. */
export async function completeLoginIfCallback(): Promise<CallbackResult | null> {
  const params = new URLSearchParams(window.location.search);
  const code = params.get("code");
  const error = params.get("error");
  const state = params.get("state");
  if (!code && !error) return null;

  const stashed = sessionStorage.getItem(STASH);
  sessionStorage.removeItem(STASH);
  clearOAuthParams();

  if (error) throw new Error(error === "access_denied" ? "Sign-in was denied." : `Sign-in failed: ${error}`);
  if (!stashed) throw new Error("Sign-in could not be completed (no pending request in this browser).");

  const { verifier, state: expected, baseUrl } = JSON.parse(stashed) as { verifier: string; state: string; baseUrl: string };
  if (!state || state !== expected) throw new Error("Sign-in state did not match — try again.");

  const res = await fetch(`${baseUrl}/api/oauth/token`, {
    method: "POST",
    headers: { "content-type": "application/json", accept: "application/json" },
    body: JSON.stringify({ grant_type: "authorization_code", code, code_verifier: verifier, client_id: CLIENT_ID, redirect_uri: redirectUri() }),
  });
  if (!res.ok) throw new Error("Managoat rejected the sign-in. Try again.");
  const body = (await res.json()) as { access_token: string };
  return { baseUrl, apiKey: body.access_token };
}

export async function revoke(baseUrl: string, apiKey: string): Promise<void> {
  try {
    await fetch(`${baseUrl}/api/oauth/revoke`, { method: "POST", headers: { authorization: `Bearer ${apiKey}` } });
  } catch { /* signing out locally is what matters */ }
}

function clearOAuthParams(): void {
  const url = new URL(window.location.href);
  ["code", "state", "error", "error_description"].forEach((k) => url.searchParams.delete(k));
  window.history.replaceState({}, "", url.pathname + url.search + url.hash);
}
```

App-side wiring (`src/App.tsx`): seed an `oauthBusy` flag
synchronously from `/[?&](code|error)=/.test(location.search)` so the
settings screen never flashes during the callback; then
`completeLoginIfCallback()` → `GET /api/auth/me` → save settings. **Keep the
minted token even if `me()` fails** — otherwise a CORS mistake orphans a key
per attempt.

## The workbench variant (an app with a server)

The browser runs the same PKCE code, but only to obtain a key it then hands to
its own server once (`POST /api/session { apiKey }`) and forgets. The server
verifies with `GET /api/auth/me`, keys the identity on the lowercased email,
stores the key AES-256-GCM encrypted, and issues an `HttpOnly; SameSite=Lax`
session cookie. Sign-out keeps the stored key on purpose: a shared project
does not stop when its owner closes a tab. The browser then builds
`new Fountain({ baseUrl: "<origin>/f/<project>", apiKey: "session" })` — the
placeholder is swapped by the proxy — and CORS is not involved at all.
