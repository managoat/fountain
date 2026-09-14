---
type: ADR
title: "Extensions contribute connection providers"
description: "Built. Fountain.Extension has an eleventh callback, connection_providers/0: an extension hands the host config-backed Fountain.Connections.Provider structs and the host lists them, reserves their slugs and drives them with the one OAuth client. Google, Microsoft and Slack each ship as an extension (fountain_google, fountain_microsoft, fountain_slack); core builds no platform provider and a core distribution lists none."
tags: [connections, oauth, extensions, architecture]
status: stable
adr: "0054"
adr_status: "Accepted"
date: 2026-09-14
generated: { by: claude-fable/5.1, at: 2026-09-14T00:40:00-04:00 }
verified: { by: claude-fable/5.1, at: 2026-09-14T00:40:00-04:00 }
---

# 0054 — Extensions contribute connection providers

**Status:** Accepted — **built.** The callback, the registry composition in
`Fountain.Connections.Platform` and the boot validation in
`Fountain.Extensions` are built (#2152 step 4a), and so are the three moves
that make core own no platform provider: Microsoft is
`apps/fountain_microsoft` (step 4c), Slack is `apps/fountain_slack` (step
4d) and Google is `apps/fountain_google` (step 4b), beside the Gmail MCP
server it also serves. Each reads its `<SLUG>_OAUTH_*` variables into its
own `config :fountain_<slug>` and owns its `(connection)` manual page.
`Platform` keeps the registry functions and builds nothing;
`builtin_slugs/0` is empty. Nothing described here is unbuilt.

## Context

ADR 0033 decision 1 made the platform providers "a small closed registry:
Google, Microsoft and Slack", grown only by amending that ADR, because
Fountain owns the OAuth client for each and a consumer-facing app's users
will never register their own. That registry lives in
`Fountain.Connections.Platform` as three struct builders plus nine
environment variables in `config/runtime.exs`.

Two things changed since. The Gmail MCP server, the only product behind the
Google provider, is moving out of core into `fountain_google` under ADR 0043
(#2152 step 2, specified as `fountain_gmail` in #1529). A provider whose
product is an extension but whose registry entry is core is a feature cut in
half: a core distribution would list "Connect a Google account" and have
nothing to do with the token. And the sprawl review of 2026-09-13 found that
the Connections context carries three provider kinds times three delivery
paths for one thing the product needs — a tenant authenticating to an
OAuth-based MCP service — with the platform registry and its products
accounting for most of what is not that.

ADR 0043 decision 3 fixes the callback set at ten and says no eleventh
without an ADR. The seam had, until now, survived two extractions and one
design without needing one. Moving the platform providers out needs one:
nothing in the ten lets an extension put a row on the connections page.

What made it possible is #2152 step 1: the two things the OAuth client used
to ask `Platform` about by slug (extra authorize parameters; Slack's nested
token body) became fields on the provider struct, so the client names no
service and a provider can come from anywhere.

## Decision

1. **`Fountain.Extension` gains `connection_providers/0`, the eleventh
   callback.** It returns `[Fountain.Connections.Provider.t()]`: config-backed
   structs in the shape a platform provider has always had — `user_id: nil`,
   the slug as `id`, a `kind` of `oauth2` or `mcp`, and everything the OAuth
   client reads on the struct, `authorize_params` and `token_body_nest`
   included. The default from `use Fountain.Extension` is `[]`.

2. **The extension contributes the provider, never the flow.**
   `Fountain.Connections.OAuth` drives an extension's provider exactly as it
   drives the host's: the authorize URL, the code exchange, refresh and
   revoke are core code, and the token is stored, encrypted and brokered by
   core. Extension code never sees a token. This is what keeps the
   callback off the list of things ADR 0043 said it would not add: it is not
   a hot-path callback, it wraps no host mutation, and it returns data.

3. **The registry is the host's own providers, then each installed
   extension's, in configured order.** `Fountain.Connections.Platform.all/0`
   is that concatenation; `get/1` answers a host slug or an extension's;
   `slugs/0` is every reserved slug and is what a tenant provider's changeset
   refuses. `Fountain.Extensions.connection_providers/0` is the extension
   half, isolated like the admin figures: a raising extension costs its own
   providers and nobody else's, because the alternative is a broken optional
   connector emptying the connections page for every account.

4. **Validated at boot, refused closed.** `Fountain.Extensions.validate!/0`
   refuses an installed extension whose list is not a list, an entry that is
   not a provider struct, one carrying a `user_id`, one whose `id` is not its
   slug, a slug of the wrong shape (the tenant slug shape) or kind, and a slug
   the host or an earlier extension already owns. A disabled extension is not
   asked, the way its migrations are not resolved.

5. **Convention, not callback, for the rest.** An extension reads
   `<SLUG>_OAUTH_CLIENT_ID` / `_SECRET` / `_SCOPES` into its own config
   namespace and builds the struct from there; the console names that env
   var beside an unconfigured row (`Platform.client_env_var/1`) and derives
   "Connect a Google account" from the slug (`Platform.short_name/1`), for
   an extension's provider as for the host's. A provider whose deployment
   has no client is still listed, with `configured` false, so a client can
   say "not available here".

6. **Core ends up owning no platform provider.** Google moves into
   `fountain_google` beside the Gmail MCP server; Microsoft and Slack each
   become an extension of their own (`fountain_microsoft`, `fountain_slack`),
   because each is a product someone may want to add to a deployment and a
   product nobody has to carry. Built: `Platform` keeps the registry
   functions and has no builders, and the nine env vars are read in
   `config/runtime.exs` into each extension's own configuration rather
   than core's. ADR 0033 decision 1's "grown only by amending this ADR" is
   "grown by installing an extension".

## Consequences

- A connector that ships as an extension is one more row on the connections
  page, one more reserved slug, and nothing else in core. The core
  distribution's connections page lists exactly what the core distribution
  can connect.
- The callback count is eleven. ADR 0043 decision 3 is amended, and CLAUDE.md
  keeps the rule that the next one needs an ADR.
- The test VM installs a fixture extension that contributes one provider
  (`fixture-svc`), so every test that enumerates the registry sees four
  platform providers rather than three. That is deliberate: the seam is
  proved on the real path the console and the API take, not on a copy of it.
- A core distribution lists no platform provider, so its connections page
  offers only what the tenant defines. A deployment that stored platform
  grants before the moves keeps them revocable and deletable and contributes
  no token from them (`FountainGoogle.CoreUpgradeTest` and its siblings).

## Alternatives considered

- **Keep the registry in core and gate rows on `Fountain.Extensions.installed?/1`.**
  Core would carry the provider's endpoints, scopes and quirks for a product
  it does not ship, and the guard test that keeps core from naming an
  extension would be satisfied by an id while the coupling stayed. Rejected.
- **One `fountain_connectors` extension holding all three providers and the
  Gmail server.** Recreates the bundle ADR 0033 built, one level out; a
  deployment that wants Slack would carry Google's product. Rejected in favour
  of one extension per service.
- **A provider-kind registry, so an extension could add a kind with its own
  flow.** A second hot path and a callback that runs extension code with a
  token in hand, both of which ADR 0043 said it would not add. The `oauth2`
  and `mcp` kinds cover every provider anyone has asked for. Rejected.
