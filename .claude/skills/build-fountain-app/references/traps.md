# Traps every previous app hit

Read once. Each entry cost real hours in fountain-team, fountain-workbench,
dns-desk or the demo suite. Issue numbers are managoat/fountain unless
noted.

## Transport

- **`ConnectionError` / "Failed to fetch" in a browser is usually CORS**, not your code. Register the app's redirect origin or add it to `API_CORS_ORIGINS`.
- **Firefox sends a page-set `User-Agent`; Chrome drops it.** Any custom header turns every call into a preflight, and the server's allow-list is static. SDK ≥ 0.1.5 no longer stamps UA in a browser and the plug admits `user-agent` (#1062), but **do not add custom headers of your own** and smoke in Firefox, not only headless Chrome. The workbench server uses plain `fetch` rather than the SDK on proxied calls precisely so it stamps nothing.
- **`EventSource` cannot send `Authorization`.** Streams are read with `fetch` and parsed by hand (SSE spec: blank-line records, `id:`/`event:`/`data:`, `:` heartbeats). The SDK's `stream()`/`team.stream()` do this and reconnect from their own last id; if you hand-roll, send `Last-Event-ID`, back off 1s→×2→15s cap, and `refresh()` on every open because a reconnect can miss a turn-end.
- **`/api/events/stream` follows unfinished conversations only** (#1060): one that fails or finishes before the debounced re-follow leaves a gap the stream never fills. Workaround: on any change to `turn_count` / `status` / `sandbox.status`, re-read `history({ after: lastSeenId })` and merge by event id — and merge live events into an in-flight history fetch, or the live ones get overwritten.
- **The Vite `FOUNTAIN_PROXY` dev trick breaks OAuth** — the redirect goes to the real origin. With the proxy, paste a key.
- Raise the SDK `timeoutMs` (30s default) to ~120s for terminate — it waits on sprite teardown. Mutations should ignore a client abort; a terminate half-way through must finish whether or not the tab is still there.

## Data model

- **A channel binds exactly one conversation.** A second create on the same `channel_id` with `fresh: true` *steals* the binding; without `fresh` it *resumes*. Mint a per-conversation tag (`app:<scope>/<id>/<tag>`) and read the scope off the prefix.
- **A pending conversation lies about its sandbox** (#839): opened without a prompt it stays `pending`, and `presence` reads "starting computer" even once the sandbox is `ready`. Read `conversation.sandbox.status` too. The conversation list carries only `sandbox_id`; fetch the sandbox record separately, re-read when a conversation on it changes status.
- **There is no "destroy sandbox".** A sprite dies with the last live conversation on it; a machine something else still holds stays up. Report what actually went.
- **Two "fresh thread" semantics.** `POST /api/team/:id/conversations` retires the thread and keeps the computer; to get a *new* computer, `terminate` first, then the same call.
- **Sharing a sandbox** is `sandbox_id` on the create body (ADR 0023); unknown keys are ignored by older servers, so compare the returned `conversation.sandbox_id` with what you asked for and say so when it differs. Identity is `(agent, environment, vault)`.
- Fountain has **no pins, mutes, drafts, prefs, projects, or sharing**. Per-browser things go in `localStorage`; cross-user things need your own server. An app with a server should return **404, not 403**, for a resource the caller isn't a member of.
- **Secret values are write-only.** `secrets.list()` returns keys. Connectors reference `${VAR}`; the token never reaches the model, and any sandbox env value ≥ 8 bytes persists as `[REDACTED]`.

## Rendering

- **Use `?blocks=true`** (the SDK sets it). fountain-team predates it and carries a 200-line port of the server's ACP parser (`src/lib/acp.ts`); do not copy that.
- **Permission requests**: never synthesise an option the agent did not offer (the server 422s `unknown_option`); first answer wins so a 409 `permission_request_resolved` is normal; read the `outcome` field, not `state` — `state` is `done` for a deny too. Log events are immutable, so the resolution arrives as a separate `request` stage event paired on `request_id`. "Always allow" (claude-agent-acp) is a rule for the exact command line, in the sandbox, and dies with it.
- Parse markdown to React elements, never HTML; agent output is untrusted.
- An `<img src>` at `/api/agents/:id/avatar` or a turn image is a 401 — fetch with the bearer, `URL.createObjectURL`, revoke later.
- Read `catalog.apps.conversations` for transcript links and append `#/c/<id>` to its trailing slash. A null app URL means no transcript app is configured; omit the link. The retired `/conversations/:id` browser path returns 404 and is not a fallback.

## Errors

- Branch on `code`, not status: `conversation_busy` 400, `provisioning` / `sprite_probe_failed` / `fleet_full` 503 (carry `Retry-After`), `sandbox_quota_exceeded` 429, `insufficient_credits` 402 (`upgrade_url`), 422 `fieldErrors`. `starting` is deliberately *not* busy: attempt the send and let the server decide.
- Both fountain-team and the workbench keep a `describeError(err)` table mapping codes to copy (`environment_not_allowed`, `runner_offline`, `no_runner_online`, `provider_error`, …). Start from theirs.

## Testing

- Test against a **fake Fountain**, but shape its responses from the real API: the SDK's fake once wrapped a response in an envelope the real API omits, and the suite was green while prod returned null. Verify the shape with one real call before writing the fake.
- A dev Fountain has no `SPRITES_TOKEN`; a real turn needs prod (or a self-hosted runner). Dev login for a local server smoke: create a user via the UI; consent buttons are `Deny` / `Allow`.
- Headless-Chrome CDP smokes set React inputs via the native value setter + `input`/`change` events. Then run it again in Firefox (Marionette).

## SDK

- `@managoat/fountain-sdk` 1.0.0 (2026-08-25): credits vocabulary; `402 insufficient_credits` maps to `SubscriptionRequiredError` (name kept); `fleet_full` → `NotReadyError`.
- Anything the SDK does not wrap: `fountain.request(method, path, { query, body })` or `fountain.api.raw(...)` for bytes.
- An OpenAPI property with a `default:` generates as **required** in the SDK types; if a call won't typecheck for a field the server defaults, that is why (fix in `schemas.ex` → regenerate, not in the app).
