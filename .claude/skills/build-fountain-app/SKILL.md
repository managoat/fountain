---
name: build-fountain-app
description: Build an application on top of the Fountain API — a browser app, a bot, an internal tool, anything that hires agents, sends them prompts and renders what they do. Use whenever the user says "build an app on Fountain", "a client for Fountain", "another fountain-team / workbench / demo app", "Sign in with Fountain", or wants to ship something that talks to /api from its own origin. Covers the published TypeScript SDK (@managoat/fountain-sdk), the shape (static SPA on the SDK, or a small server in front), auth (OAuth code + PKCE, tokens are API keys), streaming, self-service OAuth client registration, a hosting recipe for any static host or container, and the traps every previous app hit.
---

# Build an app on Fountain

Fountain's own UI is a console. Every product surface that talks to a person
is a separate app on `/api`, on its own origin, with no privileged access.
Three of them are the reference implementations — clone their shape rather
than inventing one:

| Example | Shape | Study it for |
|---|---|---|
| [fountain-team](https://github.com/managoat/demos/tree/main/apps/fountain-team) | static SPA, raw `fetch` (predates the SDK) | roster + thread + queue, team stream, PKCE sign-in (`src/lib/oauth.ts`) |
| [fountain-workbench](https://github.com/managoat/demos/tree/main/apps/fountain-workbench) | SPA **plus a Bun server** (`server/`) | when an app needs its own backend: shared projects, a member never holds the owner's key, project-scoped proxy of `/api`, an MCP surface for the agent |
| [fountain-demos](https://github.com/managoat/demos/tree/main/apps/fountain-demos), an index of [briefing-room](https://github.com/managoat/demos/tree/main/apps/briefing-room), [table-talk](https://github.com/managoat/demos/tree/main/apps/table-talk), [repo-sage](https://github.com/managoat/demos/tree/main/apps/repo-sage), [mission-control](https://github.com/managoat/demos/tree/main/apps/mission-control), [watchtower](https://github.com/managoat/demos/tree/main/apps/watchtower), [arena](https://github.com/managoat/demos/tree/main/apps/arena), [mend](https://github.com/managoat/demos/tree/main/apps/mend), [rounds](https://github.com/managoat/demos/tree/main/apps/rounds) | one static app per directory in `managoat/demos`, all cloned from [dns-desk](https://github.com/managoat/demos/tree/main/apps/dns-desk); Mend and Rounds add a Bun `server/` because a GitHub App private key cannot live in a browser | a container recipe (Dockerfile + nginx + build workflow), the `lib/spec.ts` + `lib/protocol.ts` pair (the prompt asks for a fenced answer block, the parser reads it back; change one, change both), lazy hiring on first use |

Clone whichever you want to read; none of this depends on a local checkout.

The public manual already explains the domain; **read it before writing
code, do not re-derive it**:

- `docs/build/index.md` — why the app is static files + a bearer token
- `docs/build/pieces.md` — agent / conversation / sandbox / environment / vault, what happens between Enter and the first word, the two streams, where tenancy lives
- `docs/build/team-chat.md` — the whole app in SDK calls, in order (hire, roster, message, stream, thread, busy/stop/images/search, connectors, routines, ship)
- `docs/sdk.md` — the SDK surface, the error table, the browser section
- `docs/api.md` — every route, incl. *Sign in with Fountain*
- `sdk/typescript/examples/*.ts` — compiled in CI, so they are true

## The SDK is the client

[`@managoat/fountain-sdk`](https://www.npmjs.com/package/@managoat/fountain-sdk)
is published on npm (1.0.0, Apache-2.0, no runtime dependencies, Node ≥ 20.19,
browser-safe by default). Its source is `sdk/typescript/` in this repo;
`docs/sdk.md` is the manual and `sdk/typescript/examples/*.ts` are compiled
in CI. Do not hand-roll a `fetch` wrapper, an SSE parser or an ACP block
parser — the SDK is those, done once, and its types are generated from the
server's OpenAPI document so they cannot drift.

```bash
npm install @managoat/fountain-sdk
```

```ts
import { Fountain, ConversationBusyError } from "@managoat/fountain-sdk";

const fountain = new Fountain({ baseUrl, apiKey });   // in a browser: what the person gave you
const me = await fountain.me();                        // the cheapest check that a key works

// one-shot: an agent on a machine, streamed
const run = fountain.run("Any disks over 80%?", { agent: "watchtower" });
for await (const chunk of run.textStream) append(chunk);
const result = await run;                              // state: done | failed | interrupted | timeout

// a team: hire, message, one stream for the whole roster
await fountain.team.add("watchtower", { name: "Watchtower" });
try { await fountain.team.message("watchtower", text); }
catch (e) { if (e instanceof ConversationBusyError) queue.push(text); else throw e; }
for await (const ev of fountain.team.stream({ streams: ["stage"] })) route(ev);

// a thread: prompts + parsed blocks, paged to the end
const conv = fountain.resume(conversationId);
const [turns, events] = await Promise.all([conv.turns(), conv.history({ streams: ["acp", "stdout"] })]);

// anything the SDK does not wrap
await fountain.request("GET", "/api/audit", { query: { limit: 50 } });
```

What it gives you that raw `fetch` does not: `Run` handles you can await or
stream; `blocks: true` on every feed; reconnect from the last event id; the
name-or-id resolver on agents/environments/vaults; and one error class per
server `code` (`ConversationBusyError`, `NotReadyError` with `retryAfter`,
`SubscriptionRequiredError` with `upgradeUrl`,
`ValidationError` with `fieldErrors`, `ConnectionError` — in a browser,
CORS). In Node the credentials resolve from `FOUNTAIN_API_KEY` /
`FOUNTAIN_BASE_URL` and `~/.fountain/credentials`, same as the CLI; in a
browser you pass them. Add nothing to its headers (see the Firefox trap).

The SDK versions independently of the server; the API is additive, so an
older SDK keeps working against a newer Fountain. Other languages: the
OpenAPI document at `GET /api/openapi.json` is the contract.

## 1. Decide the shape

Ask one question: **does anyone besides the key's owner need to see the
data?**

- **No** → a static SPA. No backend. Key in `localStorage`, OAuth for
  sign-in, `@managoat/fountain-sdk` in the browser. This is fountain-team,
  fountain-conversations, dns-desk and all six demo apps. Default here.
- **Yes** (sharing, cross-user rooms, a credential the browser must not
  hold, your own data model) → the workbench shape: a small server that
  holds the owner's key encrypted, authenticates its own users by asking
  Fountain whose key it is (`GET /api/auth/me`), and **proxies a narrowed
  `/api`** so the browser still runs an ordinary SDK client with the proxy as
  `baseUrl` (`server/proxy.ts`). Fountain has no team/org/sharing primitive
  and no per-user prefs store; anything of that kind is the app's own table.

Persist app-only structure (projects, work items, pinned things) in the
app, but make membership **durable on Fountain** via `channel_id`
(`<app>:<scope>/<id>`), so the tree can be rebuilt from
`GET /api/conversations` after a wipe. Pass `fresh: true` on create when a
channel must not *resume* an existing conversation.

## 2. Stack

bun + vite + react + TypeScript, `@managoat/fountain-sdk` (current
`1.0.0`; the `browser` export condition works under Vite, no runtime deps).
Use the SDK. fountain-team and the demo apps predate it and vendor a
hand-rolled `src/api/client.ts` + `lib/sse.ts` + `lib/acp.ts` from dns-desk;
the SDK is those three files done once, with `blocks` on by default. Copy
`package.json` / `tsconfig.json` / `vite.config.ts` from fountain-workbench.
Scripts: `dev`, `build` (`tsc --noEmit && vite build`), `test` (`bun test`).
A mock/fake Fountain in tests, not the real one (`server/app.test.ts` in the
workbench is the pattern; see the envelope trap in
[references/traps.md](references/traps.md)).

Settings the user must be able to change at runtime: **base URL** and the
key. The SDK's default base URL is the hosted instance; a build that lets
the person type another works against any Fountain that admits the origin.

## 3. Auth: Sign in with Fountain, paste-a-key as fallback

OAuth 2.0 authorization code + PKCE (S256), public client, no secret, no
refresh token. The token **is** a 30-day full-scope API key named
`oauth:<client_id>` (ADR 0021). Sign-out is `POST /api/oauth/revoke` with
the token. ~80 lines, copied verbatim in
[references/sign-in.md](references/sign-in.md).

The client id and the **exact** redirect URI must be registered on the
server. Register it yourself as described in section 5. A client nobody
registered renders an error page and redirects nowhere. Keep the pasted-key
path for the CLI, sandboxes (`$FOUNTAIN_TOKEN`) and an instance where your
client is not registered.

## 4. The four things people judge an app on

1. **The 202 is not the answer.** `POST …/messages` and `POST /api/conversations` queue a turn; the words arrive on a stream. Await the SDK `Run`, iterate `run.textStream`, or read the team/events stream.
2. **Render blocks, never a dialect.** `?blocks=true` (the SDK sets it) folds ACP/stdout into `text | thinking | tool_use | tool_result | init | result | error | raw`. fountain-team once shipped a 200-line ACP parser — do not.
3. **Busy is not an error toast.** Catch `ConversationBusyError`, queue locally, flush on the `turn/done` event. Branch on `error.code`, never on status.
4. **Show the real error.** A banner with `status` + `code` (`describeError`) instead of "could not be reached" — the workbench's generic line hid a CORS failure for a whole round trip. `ConnectionError` in a browser is almost always CORS.

Plus: an `<img src>` at `/api/agents/:id/avatar` is a 401 — fetch with the
bearer and use an object URL. Secrets are write-only (`secrets.list()`
returns keys); say so in the UI when someone pastes a token.

## 5. Register the app with the Fountain it talks to

Register it yourself with a full-scope key. One registration enables both
sign-in and CORS.

```bash
fountain oauth-client create "My App" \
  --redirect-uri https://<host>/callback \
  --redirect-uri http://localhost:5173/callback
```

You can also use `POST /api/oauth/clients` or Account, then OAuth apps. The
response prints the generated `client_id` your app sends.

The client starts in development mode. It signs in only its owner. An
operator must publish a client before other accounts can use it. Redirect
URIs match exactly, except that loopback hosts match on any port. Use
`https` unless the host is `localhost` or `127.0.0.1`.

A sprite-scoped `FOUNTAIN_TOKEN` cannot register a client because a client
is a standing path to a full-scope key. Register it with your own key, then
run the flow from the app.

An app that *replaces* a first-party
surface (conversations or team) is also wired through `Fountain.Apps`
(`CONVERSATIONS_APP_URL` / `TEAM_APP_URL`) — the only place the server knows
where an app lives.

## 6. Ship it

A static SPA needs a static host and nothing else: GitHub Pages
(`VITE_BASE=/<repo>/`, the redirect URI then carries that path), any CDN, or
an nginx container. An app with a server ships as one container. The recipe
the reference apps use, file by file, is
[references/ship.md](references/ship.md); the only server-side fact is the
registration in section 5.

## 7. Before calling it done

- Sign-in tested in **Firefox**, not only headless Chrome (the User-Agent preflight trap).
- One real turn against a real instance: hire, message, see blocks render, see `turn/done` on the stream.
- `bun test` + `tsc --noEmit` green in CI.
- The OAuth registration is **live on the instance**: an `OPTIONS` preflight from your origin returns `access-control-allow-origin` before you test sign-in.
- Read [references/traps.md](references/traps.md) once; every entry cost a previous app real hours.
