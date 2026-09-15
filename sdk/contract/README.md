# The SDK wire contract

One API, four clients. The server is the only place the API is described, and
this directory is how that description reaches TypeScript, Python, Swift and
Elixir so a schema change fails in the PR that makes it rather than months
later in somebody's application.

## Artifacts and handwritten claims

| File | Written by | Checked in |
|---|---|---|
| `../../dist/openapi.json` | `mix openapi.export`, canonicalised by `scripts/sdk-contract/build.py` | no — `dist/` is ignored |
| `contract.json` | `scripts/sdk-contract/build.py` | yes |
| `manifests/<sdk>.json` | a person | yes |
| `../typescript/src/generated/openapi.ts` | openapi-typescript | yes |
| `../swift/Sources/FountainKit/Models/ConversationWire.generated.swift` | `generate-swift.py` | yes |

`dist/openapi.json` is the whole OpenAPI document with vendor extensions off.
It moves with every prose edit and every release, which is why it is rebuilt
rather than committed.

`contract.json` is that document projected down to shape alone: operations,
schemas, requiredness, enums, formats, nullability. Descriptions, summaries,
tags and `info.version` are dropped, so a docs pass or a version bump leaves
this file byte-identical and a diff on it means exactly one thing — the wire
changed. It is committed so an SDK check needs no Elixir toolchain: the Swift
job on macOS reads it straight from the checkout.

`manifests/<sdk>.json` is what one client says it depends on. Each SDK has a
verifier in its own language that reads both files and fails, naming itself and
the scenario, when the two disagree.

`swift.json` claims the union of operations used by the `Fountain` and
`FountainKit` products in the `Fountain` Swift package. Its schema and enum
claims cover the original `Fountain` layer. `FountainKitContractTests` invokes
the typed client's resource methods through a recording transport and checks
their requests against the operation claims and the committed API contract.
Add an inventory case there when adding a typed resource method.

## Rebuilding

```bash
mise exec -- python3 scripts/sdk-contract/generate.py          # all wire artifacts
mise exec -- python3 scripts/sdk-contract/generate.py --check  # report stale outputs
```

Install dependencies/toolchains first: the pinned Elixir/OTP and server deps,
a local test database, Python 3, `npm ci` in `sdk/typescript`, and Swift 6.1.
`MIX_ENV=test` can select the configured test database. The command exports the
server contract, generates TypeScript, then generates the bounded FountainKit
conversation models. Check mode leaves committed generated files unchanged.

Split CI jobs use `--target typescript --skip-export --check` after the contract
export, and `--target swift --skip-export --check` using only the committed
contract. `build.sh` remains the lower-level export/contract command.


The export boots the app, so it needs Elixir and a database URL. Everything
downstream of it does not.

Determinism is not left to the encoder. `build.py` sorts every object key
recursively before writing either file, so the output depends on the document
and nothing else — not on Jason's map ordering, not on the OTP release. Run it
twice from a clean checkout and the second run writes the same bytes.

## The manifest

```jsonc
{
  "sdk": "python",
  "operations": ["GET /api/agents", "POST /api/conversations"],
  "schemas": {
    "Turn": {
      "required": ["id", "turn_number", "status"],  // read as always present
      "optional": ["ended_at"],                     // the client may omit it
      "fields": ["exit_code", "prompt"]             // read, requiredness not relied on
    }
  },
  "enums": {
    "Turn.status": ["completed", "failed"],
    "LogEvent.kind": { "values": ["output", "stage"], "exhaustive": true }
  }
}
```

What each verifier checks, in the same order, with the same messages:

1. **Operations.** Every `"METHOD /path"` still exists. A moved, renamed or
   deleted endpoint fails here.
2. **Schemas.** Every named schema still exists.
3. **Fields.** Every name under `required`, `optional` and `fields` is still a
   property of its schema. A renamed field fails here, and the message lists
   the properties the schema does have.
4. **Requiredness.** A `required` name must still be required; an `optional`
   name must still be optional. On a response schema that reads as "the client
   takes this field without a guard" and "the client copes when it is absent".
   On a request schema it reads as "the client always sends this" and "the
   client leaves this out when the caller gave nothing", which is the check
   that guards the `default` trap below.
5. **Enums.** The declared values must still be accepted. An entry written as
   a bare list is a subset check: the client handles these, the API may add
   more. `{"values": [...], "exhaustive": true}` demands equality, for the
   places where a new value would fall through a `switch` — declare it only
   where the client genuinely enumerates every case.

A response envelope is not a special case. `AgentListResponse` is a schema with
one required property, `data`; declare it and a server that renames the
envelope key fails check 3.

## The omissions allowlist

`omissions.json` records the operations no SDK's hand-written layer models, one
reason per group. `build.py --check` fails when an operation is neither claimed
by a manifest nor matched here, **and** when an entry here matches nothing the
API still serves. So a new endpoint stops CI until somebody decides — wire it
into a client, or write the line saying why no client needs it. Deleting an
endpoint that was written down here fails too, rather than leaving a stale
reason behind.

Patterns are fnmatch globs over `METHOD /path`, with the path exactly as the
OpenAPI document templates it (`/api/agents/{id}`, not `/api/agents/:id`).

## What this does not catch

A manifest is a declaration, not a derivation. If a client starts reading a
field and nobody adds it to the manifest, the rename that breaks it later will
not fail here. Adding the field to the manifest is part of writing the code
that reads it — the same way a new endpoint gets a test.

The complement is `sdk/typescript`, which generates types for the *whole*
document into `src/generated/openapi.ts` and fails on a diff. Between the two,
every schema in the API is pinned somewhere, and the fields the ergonomic
layers actually reach for are pinned in all four languages.

## The `default` trap

An OpenAPI property that carries a `default` is **not** required — the default
is what the server uses when the client omits it. `openapi-typescript` emits
such a property as non-optional anyway, which is why
`sdk/typescript/src/schemas.ts` re-relaxes `ScheduleInput`.

The projection takes requiredness from the schema's `required` list and nothing
else, records `has_default` separately, and `build.py` refuses to write a
contract where a default-carrying property came out required. Four properties
are in that state today (`ChatCompletionRequest.stream`,
`InferenceCredentialRequest.validate`, `TeamScheduleCreateRequest.enabled`,
`TeamScheduleCreateRequest.one_off`); the TypeScript manifest declares the last
two as `optional`, so the day the server makes one required, the client that
omits it is told.

## The `nullable` trap

In OpenAPI 3.0 `nullable: true` relaxes the type of the schema it sits on and
nothing else. A property that borrows its shape from a composition —
`{"nullable": true, "allOf": [{"$ref": ...}]}` — reads as nullable and is not:
the wrapper carries no `type` to relax, and the referenced schema, which is
where `type: object` lives, never saw the flag. A standards validator and a
generated client both read the document, so both refuse the `null` the server
still sends. Nothing on the server side can see it: OpenApiSpex resolves null
before it consults the composition, so every casting test stays green.

`build.py` refuses to write a contract where a property says `nullable: true`
and the composition would still reject null (`check_nullable_composition`, over
the exported document rather than the projection). The repair is to put
`nullable: true` on the referenced schema itself, or to give the union an
explicit null-only branch; adding `type: object` to the wrapper does not work.
`PermissionPolicy` is the shape done right. The original `Conversation.sandbox` and `Turn.usage` exceptions (#2189)
now carry explicit null-only union branches; `KNOWN_NOT_NULLABLE` is empty.
The projection records a named
schema's own `nullable` for the same reason — without it, hoisting the flag
onto a component diffs `contract.json` to nothing.

## Per-SDK commands

| SDK | Command | Run from |
|---|---|---|
| TypeScript | `npm run verify-contract` | `sdk/typescript` |
| TypeScript (types) | `npm run generate` then check for a diff | `sdk/typescript` |
| Python | `python3 scripts/verify_contract.py` | `sdk/python` |
| Swift | `swift test --filter ContractTests` | repository root |
| Elixir | `mix test test/contract_test.exs` | `sdk/elixir` |

`CONTRIBUTING.md` has the order to run them in when a PR changes the API.

## Conversation field workflow

The API-shaped SDK launch methods forward the supplied request; FountainKit
passes its generated request directly. The CLI's `conv create --file` preserves
JSON values and prints the response, including queued 202 job responses. Run
methods require a nonblank prompt and immediate creation. Omission and explicit
null stay distinct; local timeout/collection options never enter the body.

| Representative addition | Handwritten work before | Handwritten work now | Generated output |
|---|---|---|---|
| Optional conversation launch field | Server schema/input handling; four SDK arguments/body allowlists; CLI flag; manifest/fixture edits when used | Server schema/input behavior and focused server test; a convenience argument only if deliberately offered | Contract, TypeScript request type, Swift property/initializer/CodingKey/null support |
| Optional conversation response field | Server schema and JSON view; Swift property/CodingKey; declarations/claims and fixtures when read | Server schema and JSON view plus serialization test; client logic only if it reads the field | Contract, TypeScript response type, Swift model |
| New run/permission/SSE behavior | Server and client behavior; hand-authored conformance expectations | Same behavioral work and independent expectations | Shape declarations only |

The passthrough and model generation do not remove server domain validation or
JSON serialization. They remove the need to register a shape-only field in
every client. Existing manifest entries remain: they describe fields and enums
that handwritten run/error/resolver/legacy-builder code still depends on.
No endpoint coverage decision or behavioral manifest claim became redundant
merely because a model is generated. The nullable response guard and actual
controller-response/schema validation remain in place.

### Propagation probe

```bash
npm --prefix sdk/typescript run build
mise exec -- python3 scripts/sdk-contract/check-propagation.py
# Or just the language installed in a CI job:
python3 scripts/sdk-contract/check-propagation.py --client swift
```

Besides the generation prerequisites, the full probe needs Go and fetched
`sdk/elixir` dependencies. It uses the built TypeScript output (so both Node
20.19 and 24 run the same probe), source Python/Elixir, the Go CLI, and both
Swift products. Each language job runs its own `--client` check in CI.

`propagation/fixture.json` declares a synthetic optional object `future_options`
with nested objects mixing required and nullable children, shared schema
references, arrays and dictionaries, plus
false/null/empty/zero values. Request-reachable generated models must be
encodable and publicly constructible. Nullable input children distinguish
omission, explicit null via `setNull`, and values; shared response models retain
those states when decoded and re-encoded, along with Hashable conformance.
A loopback server records and compares each request exactly, then deliberately
returns 422 to stop the SDK run at creation.
A GET proves map responses preserve the new field; the CLI prints a created
response with it. For FountainKit, the probe copies sources into a temporary
Swift package, extends only its in-memory contract, generates the field,
compiles a caller using it, and checks request encoding and response decoding.
No fake field enters the published schema or checked-in generated model.
The separate generator mutation test covers Conversation and Turn as well.

This fixture proves propagation, not server acceptance of an invented field.
It does not generate expected SSE/retry/permission/pagination/run-termination
behavior; those scenarios remain independently authored in `sdk/conformance`.

Regeneration is not a release instruction. Assess each SDK's public change
under its existing version/publishing rules; preserve the Swift/server version
relationship until the separate release-policy initiative #1414 changes it.
