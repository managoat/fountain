---
type: ADR
title: "Web analytics from the public pages, API usage as one event, and an end to the datacentre geolocation"
description: "Retired 2026-10-12: the posthog-js snippet and the sign-in merge were removed with ADR 0025. posthog-js on the public browser surface only (the console stays snippet-free and server-captured), the anonymous visitor merged into the account at sign-in from the server, the :api pipeline's request log captured as a single api.request event with route as a property, and $ip replaced by an explicit $geoip_disable."
tags: [observability, analytics, privacy, api]
status: deprecated
adr: "0028"
adr_status: "Retired"
date: 2026-08-23
generated: { by: human:jhgaylor, at: 2026-08-23T03:00:00-04:00 }
verified: { by: human:jhgaylor, at: 2026-08-23T03:00:00-04:00 }
---

# 0028 — Web analytics from the public pages, API usage as one event, and an end to the datacentre geolocation

**Status:** Retired 2026-10-12; see the addendum at the end. The text above the addendum is history. Was: Accepted. Everything described here is built:
`FountainWeb.Plugs.WebAnalytics`, `FountainWeb.Plugs.AnalyticsIdentity`,
`Fountain.Analytics.browser_config/0`, `alias_anonymous/2`, `api_request/1`,
the `api.request` branch in `Fountain.Audit`, and the runtime CSP in
`FountainWeb.Router.csp/0`. Covered by `analytics_web_test.exs`,
`fountain_web/plugs/web_analytics_test.exs`,
`fountain_web/plugs/analytics_identity_test.exs`, and the amended
`analytics_bridges_test.exs` and `analytics_pageview_test.exs`.

Amends **ADR 0025**, which stands except where this says otherwise.

## Context

ADR 0025 built the product analytics pipeline and it works. A day of
production data showed that three of the questions it was built to answer
could not be asked of it, and that one of its outputs was actively wrong.

**Nobody who was not signed in was counted anywhere.** `capture/4` drops an
event with no subject, by rule, so PostHog person counts mean accounts. The
consequence went unnoticed: the marketing home, the legal pages, the manual
and the whole auth flow produced *nothing*. Fountain had no idea how many
people looked at it, where they came from, or how many of them reached the
register form. The acquisition funnel had no top.

**Web analytics had no input.** The console's server-side `$pageview` is the
only pageview the project received. It carries no `$session_id`, so a query
for sessions returned **0** against 108 pageviews; no `$referrer` and no UTM
parameters, so acquisition was unanswerable; no `$browser`, `$os` or
`$device_type`. Every PostHog web analytics KPI — bounce rate, session
duration, entry and exit pages — has no input at all. These are facts about a
browser, and only a browser has them.

**Every event geolocated to the deployment.** `base_properties/2` sent
`"$ip" => nil` with a comment saying that meant "no location". It does not.
PostHog fills a missing or null `$ip` from the address the batch arrived from,
which for a server-side sink is a pod's egress address, and then geolocates
that. All 108 pageviews reported a single city. The code that was written to
stop exactly this caused it.

**API usage was refused wholesale.** ADR 0025 declined the `:api` pipeline's
request-log rows, correctly, because their *names* are request lines and 73
distinct names in one day is 73 new event definitions. That reasoning is about
the name. It was applied to the row, which left "which endpoints does anyone
call", "is the SDK erroring", and "did that release change API usage" with no
answer, while the audit trail held the data for all three.

## Decision

**posthog-js on the public surface, and only there.**
`FountainWeb.Plugs.WebAnalytics` marks the landing and legal pages, the manual
and the auth flow; the root layout renders the snippet for those routes alone.
This is what makes a visitor countable: sessions, referrers, UTMs, devices,
and people who have no account yet.

**The console does not get one, and this is the constraint on future work.**
ADR 0025 rejected a console snippet and that rejection stands, for its
original reasons plus a new one: `FountainWeb.Live.Hooks` already captures
`$pageview` there, and a snippet that autocaptures would double every console
number in the project. A console page that needs a client-side event should
send it through the server, not by loading the library on that surface.

**`person_profiles: "identified_only"`.** An anonymous reader does not mint a
person profile. The events still count — visitors, sessions and entry pages
all work on anonymous events — but a person appears when an account does,
which is the same rule the server-side capture keeps. Without this, the manual
would become the project's largest cohort and the person count would stop
meaning accounts.

**The visitor and the account are merged from the server.**
`FountainWeb.Plugs.AnalyticsIdentity` reads posthog-js's own cookie
(`ph_<key>_posthog`), and on the transition from no session to a session
sends `$identify` with `$anon_distinct_id`. PostHog merges the anonymous
person into the account, and the pages someone read before signing up join
their history.

It is a plug on the transition, not a call at each sign-in site, for ADR
0013's reason: five controllers establish a browser session today, and a sixth
would be one forgotten line away from a silent hole. Doing it from the server
also avoids the alternative, which is a snippet on the console — the pages a
person lands on after signing in.

**The `:api` request log becomes one event.** `api.request`, with `method`,
`route`, `status` and `status_class` as properties. The cardinality moves from
the event definition, where it is unbounded and shared by everything that reads
the taxonomy, to a property value, where PostHog is built to break down by it
and the router bounds the set. `Fountain.Analytics.api_request/1` owns the
classification, and the two classifiers are mutually exclusive by test.

A request refused before Fountain knows the account has no subject and is not
captured. That preserves ADR 0025's rule that persons mean accounts, and it
means unauthenticated API failures stay an access-log question. The audit
trail keeps the row either way.

**`$geoip_disable`, not a null `$ip`.** A request-scoped capture forwards the
real client address; anything else states explicitly that there is no
location. The console pageview hook now forwards the address
`FountainWeb.Audited.put_client_ip/1` already resolved at mount, under the
same trusted-proxy rule the rate limiter and the audit trail use. This
replaces the sentence in ADR 0025's Consequences that describes `$ip` as sent
`null`.

**The CSP is widened on the public responses only.** `FountainWeb.Router`'s
`@csp` is unchanged and names no PostHog origin, so the console's policy stays
exactly as tight as it was — it loads no analytics script, so it should not
permit one. `FountainWeb.Plugs.WebAnalytics` appends the two origins to
`script-src` and `connect-src` on the responses that do load it.

That append happens at runtime because `POSTHOG_HOST` is read in
`config/runtime.exs`: a compile-time entry would carry whatever the build saw
— for a release, nothing — and would block every self-hosted PostHog behind a
header that looked correct in the source.
`Fountain.Analytics.assets_host/1` derives PostHog Cloud's separate asset
origin so `POSTHOG_HOST` stays the one thing an operator sets.

**The snippet's config reaches it as `data-` attributes.** HEEx escapes an
attribute on its own, so the layout interpolates nothing into JavaScript and
needs no `raw/1`. A template that concatenates config into a script body is an
XSS surface that has to be argued about; one that does not is not.

**The public pages are recorded, and that is now deliberate.** It did not
start out that way: session replay is switched on in the PostHog *project*,
and posthog-js records whenever it is, so loading the library turned replay on
for the landing page, the legal pages, the manual and the auth flow without
anyone deciding it. The behaviour was found in production, kept on review, and
is written down here because a capability nobody chose is one nobody is
maintaining.

So, plainly: **a visitor to a public Fountain page has that visit recorded.**

**No LiveView is recorded, and the admin pages least of all.** There is nothing
to exclude, because exclusion is not the mechanism: the console scope never
pipes through `:public_analytics`, so `@web_analytics` is unset, the layout's
`:if` is false, and posthog-js is never fetched. No library means no recorder,
on `/dashboard`, on `/admin`, and on `/admin/finance` — which lists accounts
and revenue and is the page it would matter most on.

That protection is a single routing fact, which is a thin thing to rest on, so
it is pinned by tests that name `/admin` and `/admin/finance` directly. Adding
`:public_analytics` to the console scope fails four of them. If a console page
ever does need a client-side event, it goes through the server, not by loading
the library on that surface.

The layout states `session_recording: { maskAllInputs: true }` rather than
relying on the default. Two reasons, neither of which is that the default is
wrong (it is `true`): a reader should be able to see that these pages are
recorded and how, without going to check a project setting; and masking should
not change silently when a dependency's default does. It matters most on
`/auth/login` and `/auth/register`, the two public pages with a form worth
typing into, where it covers the email address. Passwords are masked by rrweb
regardless.

**`POSTHOG_BROWSER_CAPTURE=false`** keeps the library off the public pages and
leaves server capture untouched. Loading a third-party script into a visitor's
browser is a different decision from sending product events from a server, and
a self-hoster is entitled to make them separately.

## Consequences

The project now receives two kinds of pageview. They are distinguished by a
`surface` property (`public` / `console`), which every browser event carries
as a registered super-property and every hook event sets. Any query that does
not filter on it is counting two different things.

PostHog's web analytics product becomes usable, but only for the public
surface. Console usage stays a product-analytics question answered by
`$pageview` with `surface: "console"`, and it will never have sessions or
bounce rates. That is the deliberate cost of not running a snippet there.

The CSP is now assembled in two places — the router's attribute and a plug
that appends to it. The plug parses the header it finds rather than
re-declaring one, so there is still a single source for every directive, but a
future change to `@csp`'s directive names would need to keep `@widened` in
step.

Merging depends on a cookie that an ad blocker removes, and on the visitor
signing in from the browser they browsed in. A merge that cannot be made is
not an error; that person's history starts at their account, which is where
every account's history started before this. Registration does not sign anyone
in, so the merge for a new signup lands at email verification rather than at
the register form.

Reading posthog-js's cookie couples the server to a third-party storage
format. It is read-only, defensive at every step, and it fails to `nil` on
anything unexpected — but a posthog-js change to the cookie shape would make
merging silently stop, with no other symptom than a funnel that loses its top
again.

`api.request` adds one PostHog event per audited API write, roughly doubling
captured volume for API-heavy tenants. It is one event definition, and it is
the only event in the project whose name is fixed while its meaning varies by
property.

Replay storage and retention now apply to Fountain's public traffic, which
they did not before. Recordings count against the PostHog plan, and a page that
is recorded is a page whose DOM leaves the building — masked, but present. If a
future public page carries anything that should not be replayed, masking it is
a per-page job (`ph-mask`, `ph-no-capture`) rather than something this decision
covers.

The trigger for replay is a **project setting**, not this code. Switching
replay off in PostHog stops it with no deploy; switching it on for a second
project would surprise a deployment that pointed at one. That is the honest
seam: this repository chooses to *load the library*, and PostHog chooses what
the library does.

## Alternatives considered

- **A snippet on the console too.** It would give the console sessions and
  replay, and it would double every pageview unless the server-side hook were
  deleted at the same time. Out of scope by choice; if it is ever done, the
  hook goes with it.
- **`disable_session_recording: true` on the public pages.** The alternative
  once the recording was discovered, and the one that matched the original
  scope, which had said nothing about replay. Rejected on review: replay of the
  landing page and the sign-up flow answers "where did this funnel actually
  lose people" in a way a pageview count cannot, and the pages carry nothing
  private beyond what masking already covers. Writing it down beat switching it
  off.
- **Lifting `product_event?/2`'s refusal and letting route-named events
  through.** The original reasoning holds, though **not for the reason first
  given here** — see the correction below. 73 new event definitions a day is a
  taxonomy nobody can read, an autocomplete nobody can use, and a
  `read-data-schema` answer in which the real vocabulary is a minority of the
  output. That is enough on its own.
- **Answering API usage from Grafana instead.** The data is already there and
  this would have cost nothing. It splits one question across two tools: "did
  the accounts that signed up last week start using the API" needs the person,
  and the person is in PostHog.
- **Calling `posthog.identify()` in the browser after login.** The natural
  approach, and it requires the snippet on the console, which is the thing
  this ADR declines.
- **A `$create_alias` event instead of `$identify` with `$anon_distinct_id`.**
  Both merge. `$identify` is the canonical anonymous-to-identified direction
  and is what the browser library sends for the same transition.
- **Turning off PostHog's GeoIP transformation project-wide.** Suggested by
  PostHog's own issue tracker, and it would fix the symptom for every event at
  once. It is a project setting rather than a property of this deployment, so
  a second Fountain reporting into the same project would inherit it silently.

## Correction (2026-08-23)

This ADR was accepted saying that a PostHog event definition is **permanent**,
and that "PostHog never garbage-collects one". That is not true, and the
statement was inherited from ADR 0025 rather than checked.

The nine request-line definitions this decision retired
(`POST /api/conversations`, `POST /api/mcp/team/:conversation_id`, and the
seven uuid-carrying names that predate the route-pattern fix) stopped receiving
events at 2026-08-22T09:00Z. Roughly a day later they were **gone from the
project's taxonomy**: a full listing of `/api/event_definitions/` returns 32
definitions and none of them is a request line, `?search=POST` returns zero,
and `?include_hidden=true` returns the same 32. The historical events are still
queryable in `events`; only the taxonomy entries are absent.

Whether PostHog prunes a definition once its event stops arriving, or whether
the tool that first listed them reads distinct names out of event data rather
than out of the definitions table, is not determinable from the API. Either
way, "permanent" is unsupported.

**The decision does not change**, and neither does `product_event?/2`. One
bounded event name is still right, because the cost of 73 new names a day is
paid while they exist and by everyone who reads the taxonomy — the event
picker, autocomplete, `read-data-schema`, and anyone trying to learn the
vocabulary. That cost is real and self-limiting rather than real and forever,
which is a weaker argument for the same conclusion.

What is worth carrying forward is the method: this was found by trying to act
on the ADR's claim (cleaning up the definitions it said would accumulate) and
discovering there was nothing to clean up. An ADR's justification is checkable,
and this one had not been checked.

ADR 0025 §"the request log is not a product event" carries the same
"permanently" and inherits this correction.

## Addendum — 2026-10-12: retired

Retired with [ADR 0025](0025-product-analytics-in-posthog.md), when Fountain
became a self-hosted application. The public pages load no third-party script
and nothing is recorded.

- `FountainWeb.Plugs.WebAnalytics`, `FountainWeb.Plugs.AnalyticsIdentity`, the
  `:public_analytics` pipeline and the posthog-js snippet in the root layout
  are deleted. The Content Security Policy is the router's `@csp` everywhere,
  widened only by `FountainWeb.Plugs.BrandAssets`.
- `POSTHOG_BROWSER_CAPTURE` is no longer read.
- The audit plug still records the route pattern rather than the request path.
  That rule never depended on PostHog: the pattern is the only groupable value
  in the trail.
