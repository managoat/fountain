# Swift wire-model generation inventory

Tracked by [#2251](https://github.com/managoat/fountain/issues/2251).
The generator reads the committed contract and does not require Elixir to run.

| Family | Disposition |
|---|---|
| Conversation, Turn, ImageInput, ConversationCreateRequest and referenced permission/model-selection objects | Generated in the foundation |
| Usage / UsageAccounting | Generated. Usage is the source-compatible union of TurnUsage and UsageTotal; either schema can add fields, and incompatible shared definitions fail generation |
| Sandbox, SandboxDetail, Sandbox.Checkpoint, Sandbox.RunnerRef, SandboxDetail.SandboxConversation, Runner | Generated from the contract; the shared inline definitions must match |
| ConversationTreeNode | Generated; no handwritten field/CodingKey declarations remain |
| Agent, Skill, AgentVersion, AgentInput | Generated; preserve names, initializer order, numeric policy values, explicit nullable inputs and the create/update convenience |
| Environment, EnvironmentInput, Vault, VaultInput, Secret | Generated; preserve JSONValue conveniences. Secret unions the environment/vault schemas and rejects conflicting shared definitions |
| Connection, ConnectionProvider, Teammate and nested types, TeamSchedule/Input | Generated; retain unknown enum handling and derived teammate identity |
| TeamAddRequest, TeamRenameRequest, TeamMessageRequest | Generated (#2300); the small request bodies local to `TeamResource`'s `add`, `rename` and `message`. `TeamMessageRequest.labels`, a field these methods do not yet expose, types `[String: JSONValue]` rather than `[String: String]` because its contract-declared `additionalProperties` allows a null value per key, which a non-Optional `String` cannot decode. Request bodies are encoded and never decoded, so none of the three needs an `OPTIONAL_COMPAT` pin; `rename` still sends an explicit JSON `null` for `nil` (never omits the key), which the caller now spells `TeamRenameRequest(name: nil)` plus `setNull(.name)` |
| APIKey, CreatedAPIKey, AuditEvent, SearchHit, Catalog/nested types, ApplyResult/nested types, AdminUser, AdminSandbox, AdminEvent | Generated from endpoint payload shapes, including shapes nested inside envelopes |
| AuthMe | Generated. `role` and `email_verified` are pinned: the contract requires both and every published AuthMe had them Optional. `onboardingState` is retired, not pinned — #1393 dropped the column, so no server emits the key |
| AdminUserPage | Decodes the generated `AdminUserListResponse` and its `Meta`; keeps `users` and the computed `hasMore`, and declares no wire keys of its own |
| ConversationBindingUpdate / ConversationReapplyRequest | Intentionally handwritten: three states are behaviour a generated `Optional` cannot express, since "leave it alone" and "remove it" are different requests. `reapplyRequestSendsEveryFieldTheContractAccepts` derives the field list from the contract, so a property added to the request fails a test rather than being silently unsendable |
| LogEvent | Generated. `id` and `ts` are pinned because one published model decodes two shapes, both contract-described since #2297: the REST row (`LogEvent`) carries both, the SSE frame (`StreamLogEvent`) carries no `id` at all (it is the frame's `id:` line). `conversation_id` and `agent_id` read their type from `StreamLogEvent` — the `owner == "LogEvent"` branch in `fields()` — rather than the REST schema, because the REST row genuinely never sends them and describing them there would promise a shape `GET /api/conversations/:id/events` never returns (#2298). `stageData` stays an extension because a Swift extension can add a computed property but never a stored one |
| Block | Intentionally handwritten. Its `body` is a two-branch `oneOf` (a string, or the plan array) that feeds two published properties, and it is one of the contract's two nodes carrying both `additionalProperties` and `properties` — both of which generation refuses by design (#2277). It also keeps an open-shaped `extra` catch-all no schema records |
| PermissionOption | Intentionally handwritten. The contract has no schema for it: `Block.options` items are open objects, so generation would retype it `[[String: JSONValue]]`. It also accepts both `optionId` and `option_id`, which nothing in the contract records |
| PermissionRequest | Intentionally handwritten, and not a wire model: it is derived from a `Block` through `init?(block:)` and never decoded |
| JSONValue, ConversationInputField and WireValue / enum wrappers | Intentionally handwritten value/behavior types; their raw-string decoding preserves unknown server values |
| Swift Fountain map product | Uses JSON objects rather than duplicated typed wire properties; remains supported |
| PageMeta, SearchResponse.Meta, AuditEventListResponse, LogEventListResponse, SearchResponse | Generated (#2300). The cursor envelope (`has_more`, `limit`, `next_cursor`) is declared inline on `AuditEventListResponse` and `LogEventListResponse`, never as a named schema; both declarations are named `PageMeta` in `INLINE_TYPES` and the reused-inline-shape guard is what proves they match. `has_more` and `limit` are pinned: the contract requires both and every published `PageMeta` had them Optional. `/api/search` pages by offset, a different shape, so it has its own `SearchResponse.Meta`, wholly new and therefore at contract requiredness. The handwritten `PageMeta` (in `Client/APIClient.swift`, not `Models/`) was the union of both shapes, so `offset` is a recorded removal in `REMOVED_PROPERTIES`. `Page<Items, Meta>` carries whichever meta the endpoint declares |
| APIErrorBody (`Errors/FountainError.swift`) | Handwritten for now. Since #2324 the contract declares one `Error` schema on every JSON error status, carrying `error` plus the optional `message`, `reason`, `errors`, `upgrade_url`, `active_sandboxes` and `limit`, so the payload can be generated from it. The behaviour over it stays handwritten — `reason` outranking `error`, `errors` accepting a string or an array per field, the client-stamped `httpStatus`, `FountainError.from(status:body:)` — the split `AdminUserPage` has over `AdminUserListResponse`. Every currently-Optional member takes an `OPTIONAL_COMPAT` pin when it moves |

## Compatibility rules

Existing nested public names and initializer order remain intact. A model that
already shipped by hand must not become harder to decode, so `OPTIONAL_COMPAT`
keeps two kinds of property optional even where the current server requires
them: properties that were historically optional, and properties this SDK
exposes for the first time on a type that already shipped. The second kind is
why a response from an older server still decodes rather than failing whole.
The table is finite and auditable: it grew from 9 entries over 5 owner types
(sandbox and runner models) to 55 over 21 as the resource families landed.

A nested type reached through a newly exposed property is pinned the same way,
because an older server reaches it with the same gaps: `CatalogMcpServersItem`
is pinned although it never shipped by hand. `CatalogFirstRequest` is the
exception and takes contract requiredness, because `first_request` arrived
whole in #1443 and no server has ever emitted it partially. A type no older
server can produce at all takes contract requiredness directly.

Three guards. The first enforces the rule itself; the other two protect the
table it is written in.

Generation fails when a property would be non-Optional on a type that has
already shipped and is either new there or was Optional before. Pinning the
property clears the failure, or `REQUIRED_BY_CONTRACT` records that no deployed
server emits the type without it — an entry there is a claim about every server
in the field, which is why it is empty. Before this guard the rule was applied
by hand and a miss was caught only if some fixture happened to decode that type
from a payload lacking the key. For 25 of 27 decodable schemas one did;
`Teammate`, the return of four public `TeamResource` methods, had no fixture at
all, so a required property there would have shipped (#2284).

The two rules below are answered independently and a property can owe both,
because the remedies differ. `REQUIRED_BY_CONTRACT` reaches only the decode
rule: "every deployed server sends this key" can establish that decoding is
safe, but it cannot make an already-public `T?` becoming `T` source-compatible.
The source rule therefore has no override at all. Keep the pin; a change that
really means to drop a published Optional should add its own door and say why,
rather than borrow an escape hatch written for a different question.

Both baselines come from the last release tag, because a baseline has to be
immutable with respect to the change being checked. The committed output is
not: a change that makes a property required and commits the regenerated file
would offer its own candidate as the record of what shipped and authorize
itself. That is why the `swift-sdk` and `workflow-checks` jobs fetch tags.

The released **contract** answers the decode question — can an older server
produce this shape, and can it leave this key out. A property that release
already required may be non-Optional; anything else must not be. This is asked
of the contract and not of the released SDK, because absence from the SDK is
not absence from the server: `CatalogMcpServersItem` is a shape the v0.17.1
server already emitted and the v0.17.1 Swift models simply did not expose, so
reading it as a wholly new type would let a required addition break an older
server's whole `Catalog` response. A shape the released contract never
described takes contract requiredness, since no released server can return it.
This is also why `REQUIRED_BY_CONTRACT` is still empty: `first_request`
arrived whole in #1443, so the released contract requires its four members and
they need no pin — the exception this file used to state in prose is now read
from the release.

The released **Swift** answers the source question — did this SDK already
publish the property as Optional. Decoding can be safe while flipping a
published `x?` to `x` still breaks a consumer's code, and 38 of the pins are
held by this rule alone. It reads every public property of every type under
`Sources/FountainKit` at the tag, wherever that type lived then, so `Teammate`
counts from when it was handwritten and `PageMeta` from when it lived in
`Client/APIClient.swift` (#2300 widened the read from `Models/` for exactly
that move: a wire type shipped outside `Models/` was the one case neither this
rule nor the presence rule could see); handwritten nested types were declared
inside their parent and generated ones in an extension, and both read as the
same key. A
name that is a Swift keyword is published escaped — `Catalog.SandboxProviders`'s
`` `default` `` is the one today — and both sides normalize to the bare name, so
a pin on it cannot be deleted in silence. The rule is only as good as that
parser, so a test counts the release's own `public var` declarations instead of
trusting a list.

The guard covers decodable models only. An input root is encoded and never
decoded, so no older server's response is in question, and pinning a request
property would let a field the server requires be omitted and the request
rejected instead — a required addition to a request is a contract change the
compiler surfaces, not a compatibility break.

`test_optional_compat_pins_reach_a_live_property` fails when a pin stops naming
a live property, which is how a contract rename turns a pin into a silent
no-op; it cannot see a pin that was deleted. `ResourceWireTests` and
`SandboxWireTests` decode payloads that omit pinned keys, which is what catches
a deletion — but only for the pins their fixtures actually omit. A pin whose
key some fixture still supplies can be dropped with every gate green, so a new
pin needs the omission that proves it.

Generation fails rather than retyping a field quietly: an inline object whose
synthesized `<Owner><Key>` name collides with a contract schema, a node
declaring both `additionalProperties` and `properties`, and an array of enum
strings with no `(<owner>, <key>_item)` entry in `ENUM_TYPES`. Each needs a
name or an override, not a default. The enum check reads the item through
`unwrap()`, which is the one definition of the wrappers `type()` follows — a
single-branch `allOf`, `anyOf` or `oneOf` — so an enum inside one of them
cannot reach the generator the check exists to stop. The both-shaped case is why the two
`networking_config` entries exist, and the array case is why
`Catalog.sandbox_api_access` types as `[SandboxAPIAccess]` beside the scalar
`Conversation.sandbox_api_access`.

Neither rule above catches a property *disappearing*: both compare
optionality, so a model that simply stops declaring a key passes either one.
A third rule closes that gap at generation time: it reads the same `shipped`
baseline as the source rule and asks presence instead, comparing it against
every `public var` the type currently publishes — not just `self.models`'
own field list, but also a computed property this module adds outside it
(`permissionPolicy`, `Teammate.id`) and one a handwritten extension elsewhere
under `Models/` adds to a generated type (`LogEvent.stageData`), since either
would otherwise read as removed the moment this guard exists. A property that
fails is a claim nobody meant to make, unless `REMOVED_PROPERTIES` — a table
beside `REQUIRED_BY_CONTRACT` — records the removal as deliberate, citing the
PR and changelog fragment that made it. Its first entry is
`("AuthMe", "onboardingState")`, retired in #2269 when `AuthMe` moved to
generation; the second is `("PageMeta", "offset")`, which moved to
`SearchResponse.Meta` in #2300.

An entry has two lives, and **it must not be pruned in the release that
retires the property**. While the release it cites is still the baseline the
entry is load-bearing: the released SDK publishes the property, the presence
rule fails on it, and the entry is what clears that — delete it early and
generation raises. Once the release that removed the property has itself
shipped, the baseline no longer publishes the key, the rule cannot consult
the entry, and it is inert; pruning it then is safe tidying. Nothing can
delete it *at* the release, because tagging is a consequence of merging: the
tree that becomes `vX.Y.Z` is tested before its tag exists and again, as
`main`, after it does, so the entry has to pass both. That is why
`test_removed_properties_entries_name_a_real_removal` tolerates an aged-out
entry and asserts it is inert rather than requiring it to be live, and why
`test_the_removal_history_has_not_grown` carries a ceiling instead — the
ceiling is what keeps the table from filling with dead entries. Requiring
live entries is what turned v0.18.0's own tag into a red run on `main`. A rename is invisible to
all three rules, since each is keyed by the property name alone — this is
also why `camel()` learning `ms` → `MS` in #2295 renamed nothing, only because
nothing generated ended in `Ms` — so a real rename reads here as the old name
removed and a new one added; this guard catches the half of that which
matters, the old name silently disappearing.

`PublicSurfaceTests` remains the compiled-consumer cover this rule does not
replace: it is still the one test file that imports `FountainKit` without
`@testable`, so it alone fails to compile if a property named in it
disappears. But it is a hand-written list that only names the families #2251
moved, where the generation-time rule reaches every currently generated type.

`EXTRA_PROPERTIES` is the third table, for properties this SDK publishes that
the contract does not describe anywhere. It is empty since #2297: it held the
SSE frame's `conversation_id` and `agent_id`, undescribed because all three
stream operations declared `text/event-stream` with a bare string schema.
Describing the frame as `StreamLogEvent` retired both — `LogEvent`'s
`owner == "LogEvent"` branch in `fields()` reads their type from that sibling
schema now, so the contract stays the one source and nothing here duplicates
it. An entry is a claim that the server sends a field the contract does not
document anywhere, so a ceiling test holds the count at 0 the way
`SchemaGuardAllowlist` holds its own, and a test fails an entry whose key the
contract has since described: at that point the ordinary path generates it
and the entry is duplication.

The 19 `TYPE_OVERRIDES` entries retain existing `JSONValue` APIs for
deliberately dynamic payloads: metadata, packages, networking config,
repositories, MCP servers, agent-version config and apply errors. Neither
table is a registry to extend for ordinary API additions. Aliased Skill
definitions must agree, and Secret reads both environment and vault schemas.
Conflicting shared definitions fail generation.

Agent inputs expose numeric policy values through `permissionPolicyValues`
while retaining the string-only initializer/property. Nullable generated inputs
use `setNull` for explicit JSON null; assigning nil restores omission. Endpoint
create/update validation remains server-owned.

Keep endpoint and behavioral contract assertions. Generation replaces field
registrations, not evidence that resource methods call the correct routes or
that the stream follower handles errors and permissions.

Checks: `python3 scripts/sdk-contract/generate-swift.py --check`,
`python3 -m unittest discover -s scripts/ci -p test_swift_generation.py`, and
`swift test -Xswiftc -warnings-as-errors`. Synthetic additions to every generated
family verify propagation without adding fake production API fields.
