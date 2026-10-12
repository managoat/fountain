# Deliverable 3: the integration catalog

Designed so the fortieth entry costs almost nothing. The governing idea is
WorkOS's constant-half / variable-half split, verified by diffing
`workos.com/docs/integrations/okta-saml` against
`workos.com/docs/integrations/azure-ad-saml`. Their guides are a translation
table between a fixed set of WorkOS-side terms and one vendor's labels for
them, wrapped in boilerplate that is identical across guides.

Fountain's version of that fixed set is the sandbox contract, the client
protocols, and the four primitives. Those are the constant half. A catalog
entry supplies only the variable half.

---

## The six catalogs and what a row means

| Catalog | Entry unit | Today | Growth |
|---|---|---|---|
| Sandbox providers | one backend implementing `Fountain.Sandbox` | 4 | slow, single digits |
| Clients | one thing that drives Fountain from outside | 7 | slow |
| Services | one external service Fountain calls to run | 4 | slow |
| Runtimes | one coding-agent CLI | 4 | slow |
| MCP servers | one server, one transport | 0 | fast, hundreds |
| Skills | one skill | 2, both undocumented | fast, hundreds |

Segment's rule applies to the last two. At
`segment.com/docs/connections/destinations/catalog/` I counted 1021 entry
listings resolving to 495 distinct names across roughly 45 categories, so each
destination is cross-listed under about two categories. **One vendor is not one
entry.** Slack has two Segment destinations, Optimizely five, TikTok five. For
Fountain that means one MCP server offered over both stdio and HTTP is two
entries if their setup differs, and one entry with a transport switcher if it
does not.

---

## Front matter, which is the whole point

> **Deferred, and honestly so.** This section assumes index pages render from
> front matter. Nothing in Fountain's MkDocs stack does that without a macros
> plugin, which is not installed, so the catalog indexes that shipped in #915
> and #920 are hand-written tables. Adding front matter now would be unused
> metadata. The design below stands if a generator arrives; it is not a
> prerequisite for writing entries.

Every entry carries YAML front matter. The index pages, the badges, the
filtering and the sort all read from it. Nothing about an entry is derived from
its prose.

```yaml
---
title: Sprites
catalog: sandboxes          # sandboxes | clients | services | runtimes | mcp-servers | skills
slug: sprites
categories: [sandbox, hosted]   # cross-listing; an entry may appear under several
status: ga                  # ga | beta | experimental | deprecated | community
maintainer: fountain        # fountain | vendor | community
also_known_as: []           # former names, so search finds the rename
direction: outbound         # outbound (Fountain calls it) | inbound (it calls Fountain)
protocol: sprites-http      # the wire format, verbatim
requires_config: true       # does the operator set env vars for this
env_vars: [SPRITES_TOKEN]   # exact names, so the config reference can back-link
capabilities: [exec, sessions, checkpoints, network-policy, suspend]
since: "0.1.0"
verified_against: "0.12.0"  # the last Fountain version this entry was checked on
---
```

Four of these fields do disproportionate work.

`also_known_as` handles vendor renames. WorkOS titles its page "Entra ID SAML
(formerly Azure AD)" precisely because catalogs outlive branding and a reader
searching the old name must land.

`status` renders as an inline badge in the entry title on the index, which is
Segment's move. `Beta`, `(Actions)`, `Cloud Mode` and `(Classic)` appear in the
name text itself, so a scanner disambiguates two same-vendor entries without
clicking either.

`capabilities` is what makes filtering possible later without rewriting
anything, and it is what a comparison table renders from.

`verified_against` is the honesty field. `CLAUDE.md` already forbids describing
unbuilt behavior as existing. A catalog of forty entries drifts, and a stated
verification version is cheaper than pretending it does not.

---

## The entry template

```markdown
---
<front matter as above>
---

# <Name> <(Variant)>

<!-- Title is the name plus the disambiguating variant, exactly as Segment
     does. "Sprites", "Slack (stdio)", "Entra ID SAML (formerly Azure AD)". -->

> <One sentence, from the vendor, saying what the thing is.>

<!-- Vendor-supplied and clearly so. Segment does exactly this on
     segment.com/docs/connections/destinations/catalog/actions-slack/ and
     nobody is confused about who wrote it. -->

## At a glance

<!-- Rendered from front matter. The writer types none of it. This is
     Segment's "Destination Info" box, hoisted above all prose: machine facts
     before sentences. -->

| | |
|---|---|
| Status | GA |
| Maintained by | Fountain |
| Protocol | `sprites-http` |
| Env vars | `SPRITES_TOKEN` |
| Capabilities | exec, sessions, checkpoints, network policy, suspend |
| Verified against | 0.12.0 |

<!-- If other entries exist for the same vendor, a disambiguation callout goes
     here, linking siblings. Segment: "Additional versions of this destination
     are available… See below for information about other versions." -->

## Why you would pick this one

<!-- Two to four sentences. The only genuinely editorial part of the page, and
     it exists because the index cannot answer "which" from badges alone.
     Compare against the sibling entries by name. -->

## What Fountain provides

<!-- The constant half. Boilerplate, near-identical across every entry in this
     catalog, with the provider name substituted. This is WorkOS's "What WorkOS
     provides".

     Sandbox providers: the six advertised capabilities (:suspend,
       :network_policy, :attach, :tty, :checkpoint, :public_url) and the
       error taxonomy, each defined once in the boilerplate.
     Clients: the conversation, the API key, the stream.
     Services: the callback URL, the webhook path, the sender identity.

     Each item gets a fixed definition sentence, then one per-entry sentence
     translating it into this vendor's vocabulary. That translation pair is the
     mechanism that makes the fortieth entry cheap. -->

## What you will need

<!-- The variable half. Exactly what comes from the vendor's side, with where
     to get it. WorkOS's "What you'll need", including its note that the value
     normally arrives from someone else's team. -->

## Set it up

<!-- Numbered steps with fixed titles reused across the catalog wherever the
     work is the same. WorkOS reuses "1 Log in", "2 Select or create your
     application", "3 Initial SAML Application Setup" verbatim across
     providers, and diverges only where the work genuinely diverges.

     Fountain's reusable step titles, per catalog:
       services:      1 Create it on the provider  2 Set the env vars  3 Restart
       sandboxes:     1 Get a token  2 Build the image  3 Point Fountain at it
       clients:       1 Get an API key  2 Configure the client  3 Name an agent
       mcp-servers:   1 Add it to the agent  2 Supply its credentials
       skills:        1 Add it to the agent

     A reader who has done one entry can skim the next. A writer knows which
     steps they are allowed to invent. -->

## Verify

<!-- One command, one expected output. Four of Fountain's existing service
     pages already end this way; the template makes it universal. Non-optional:
     an entry with no verification step cannot tell a reader they are done. -->

## How the contract maps

<!-- Sandbox providers only. The existing e2b.md and runners.md both
     have this section already and it is the best thing about them. Table of
     contract operation against this provider's call. -->

## Limits

<!-- Mandatory. Titled "Limits", not "Known issues", and stated rather than
     discovered. Three existing client pages independently invented the heading
     "Limits, stated rather than discovered", which is evidence the section is
     needed and evidence writers will invent it if the template omits it.

     Tailscale's rule applies: concede the failure case in the same breath as
     the feature. "Some especially cruel networks block UDP entirely" arrives
     immediately before the relay fallback, not in an appendix. -->

## Troubleshooting

<!-- Symptom, cause, fix. Three entries maximum. Anything longer moves to the
     Troubleshooting section and this becomes a link. This cap keeps a page
     from growing an operator runbook in place, as one integration page once
     did on its way to 395 lines. -->

## Related

<!-- Sibling entries in the same catalog, the concept page for the capability,
     and the reference for the protocol. -->
```

### Which sections are optional

Required on every entry. Front matter, title, vendor sentence, At a glance,
What you will need, Set it up, Verify, Limits, Related.

Optional. Why you would pick this one (omit when the catalog has fewer than
three entries), How the contract maps (sandbox providers only), Troubleshooting
(omit when there is nothing observed, never fill it speculatively).

### Cost of the fortieth entry

Front matter is roughly twelve lines of fact the author already knows. At a
glance is generated. What Fountain provides is boilerplate with a name
substituted. Set it up reuses three of its step titles. That leaves the vendor
sentence, Why you would pick this one, What you will need, the click path, the
Verify command, and Limits. Call it forty lines of genuinely new writing on a
page of about a hundred and forty.

---

## The catalog index page

Two views over one dataset, which is Segment's arrangement. The categorized
view answers "what should I use for X". The flat view answers "do you support
X". Neither view answers both, and both questions are common.

### `catalog/index.md`

Six cards, one per sub-catalog, each showing its entry count and its three
newest entries. Nothing else. This page exists to route, and a router that
tries to also be a list becomes neither.

### `catalog/<name>/index.md`

```markdown
# <Catalog name>

<One sentence saying what an entry in this catalog is.>

<!-- Do this literally. "A sandbox provider is a backend that Fountain
     provisions computers on." Without it, a reader cannot tell why
     self-hosted runners are in this list and Sprites' transport reference is
     not. -->

<Two sentences on how to choose, linking the concept page.>

## All <n> <things>

<!-- The flat view, first, always. Table sorted by name, generated entirely
     from front matter. -->

| Name | Status | Protocol | Env vars | Capabilities |
|---|---|---|---|---|

<!-- Enough per row to decide without clicking. Segment's badges are in the
     name text for the same reason. -->

## By category

<!-- The categorized view, second. Entries cross-list, so an entry appears
     under every category in its front matter, not under one home.
     Segment cross-lists at an average of about two categories per
     destination, and it is necessary well before their scale, because vendors
     do not respect your taxonomy. -->

### <Category>

- **<Name>** `<status>`. <the vendor sentence, truncated>

## Not here yet

<!-- What the catalog deliberately excludes, and how to request or contribute
     one. Links to guides/contribute/write-a-catalog-entry.md.

     This section is why an empty-ish catalog is honest rather than
     embarrassing, and diataxis.fr/how-to-use-diataxis/ warns against shipping
     empty structures. Never ship an index with fewer than three entries. -->
```

---

## When search and filtering become necessary

The threshold is not a raw count, it is two structural events. Both are
observable in the source.

**Filtering becomes necessary when a single category's list stops fitting on
one screen.** That is about 25 entries in one category. Below it, the browser's
own find is faster than any widget you can build. Above it, the reader is
scrolling a list they cannot see the shape of, and the categorized view has
stopped doing its job.

**Search over entry metadata becomes necessary when the total exceeds about
40.** Below 40 the flat table is one long screen and site-wide search is
adequate. Above it, readers stop arriving with a name and start arriving with a
requirement, and full-text search over prose answers the wrong question. What
they need is a query against `capabilities`, `protocol` and `status`, which is
why those are front matter fields rather than sentences.

**Cross-listing becomes necessary before either.** At about 15 entries the
first entry appears that legitimately belongs in two categories, and filing it
in one is a lie. Segment's ~495 destinations across ~45 categories with ~1021
listings is the mature version of a problem that starts small.

### Where each Fountain catalog lands

| Catalog | Entries now | Needs cross-listing | Needs filtering | Needs search |
|---|---|---|---|---|
| Sandbox providers | 4 | no | no | no |
| Clients | 7 | at ~15 | no | no |
| Services | 4 | no | no | no |
| Runtimes | 4 | no | no | no |
| MCP servers | 0 | immediately | at ~25 in one category | at ~40 |
| Skills | 2 | immediately | at ~25 in one category | at ~40 |

So four of six catalogs never need any of it, and the two that do are the two
that do not exist yet. Build them with front matter from entry one, and the
filtering is a rendering change rather than a migration.

### One thing Fountain already has and does not use

`GET /api/catalog` returns runtimes, model suggestions per runtime, sandbox
providers, package managers, and app URLs. Fountain
already publishes a machine-readable catalog and no human-readable one. The
index pages above should render from the same source wherever the data
overlaps, so the two cannot disagree, which is the argument
`diataxis.fr/reference/` makes for generated reference.

MkDocs Material with `plugins: [search]` is already configured in
`mkdocs.yml`, so site-wide search exists today. The gap is catalog-scoped
filtering, and nothing above needs building until the MCP-server catalog passes
25 entries in a category.
