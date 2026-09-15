# Fountain Swift SDK

Give an agent a computer, repositories, and credentials in one call.

Two clients ship from this package, and they are for different jobs:

| Product | Import | Shape | Use it when |
|---|---|---|---|
| `Fountain` | `import Fountain` | JSON in, `JSONObject` out; one `Fountain` object | scripting, automation, a one-call run — the shape its TypeScript, Python and Elixir siblings have |
| `FountainKit` | `import FountainKit` | `Codable` models, one namespace per resource | building an application against the API: models that bind to a UI, and the admin, audit, runner and API-key surfaces a console needs |

Both speak the same wire, both are checked against the same
[conformance suite](../conformance/README.md), both are Apache-2.0. Pick one:
they do not share types, and an app has no reason to use both.

```swift
import Fountain

let fountain = try Fountain()
let run = fountain.run(
    "Upgrade us to Phoenix 1.8 and open a PR",
    agent: "reposage",
    vault: "github-bot"
)
let result = try await run.value()
print(result.text)
print(result.url)
```

Pass `sandboxMode: "ephemeral", sandboxAPIAccess: "none"` to `run` to start
without an owner callback credential. FountainKit accepts
`sandboxAPIAccess: SandboxAPIAccess.none` on `ConversationCreateRequest`.
Omitting the option inherits a resumed channel's setting; new conversations
default to `"owner"`.

The sandbox remains after the turn, so a follow-up continues on the same
computer and in the same agent session:

```swift
let next = fountain.resume(result.conversationID).send("Fix the worst three.")
print(try await next.value().text)
```

## API-shaped conversation requests

`runRequest` accepts server field names and raw resource IDs in the `Fountain`
product. It forwards the entire map; `timeout` and `collectEvents` stay local:

```swift
let run = try fountain.runRequest([
    "agent_id": .string(agentID), "prompt": .string("Review this repo"),
    "vault_id": .null, "fresh": .bool(false), "labels": .object([:])
], timeout: 120, collectEvents: true)
```

In `FountainKit`, pass the generated `ConversationCreateRequest` directly:

```swift
var request = ConversationCreateRequest(agentID: agentID, prompt: "Review this repo")
request.labels = ["origin": "desktop"]
request.setNull(.vaultID)
request.permissionPolicyValues = ["shell": .string("ask"), "ask_timeout": .number(0)]
let run = try await client.runRequest(request, timeout: 120)
```

An optional property set to `nil` is omitted, including server-defaulted fields.
`setNull` encodes JSON null for a nullable field. Assigning a value replaces null;
assigning `nil` restores omission. False, zero, empty strings, arrays and objects
are preserved. Existing initializer arguments and the string-only
`permissionPolicy` property remain usable; `permissionPolicyValues` exposes the
complete policy, including numeric values. Reading the legacy property returns
only string entries; setting it replaces the complete policy.

With a channel ID, both `runRequest` methods follow turn 1 when the server
creates a conversation, including fresh launches. When the server resumes an
existing conversation, they submit the prompt and images once, then follow the
next turn. A rejected follow-up surfaces the API error.

Both run paths reject a missing/blank prompt and `queue: true` before HTTP.
Use the generic request API for queued creation; its 202 response is a job.
`FountainKit.conversations.create` also rejects queued creation because it returns
a conversation. Existing `run` convenience calls continue to resolve/build their
usual requests.

The conversation request, Conversation, Turn, images, usage and permission
request models are generated from `sdk/contract/contract.json`. Regenerate with
`python3 scripts/sdk-contract/generate-swift.py`; add `--check` to detect stale
output. This needs Python and the package's Swift 6.1 formatter, without booting
the server. The bounded generator reuses Sandbox and existing open-enum types;
new unsupported union shapes fail with their schema/property name. Swift wire
names, optionality, dates and nullable request fields come from the contract.

## Install

The remotely consumable `Package.swift` is at the repository root. Depend on
Fountain 0.17.0 or newer:

```swift
dependencies: [
    .package(url: "https://github.com/managoat/fountain.git", from: "0.17.0")
]
```

Then add `.product(name: "Fountain", package: "fountain")` to your target —
or `.product(name: "FountainKit", package: "fountain")` for the typed client,
which is available starting with 0.17.0.

Swift 6.1 or newer is required. The SDK supports macOS 12, iOS/tvOS 15,
watchOS 8, and Linux FoundationNetworking, with no third-party dependencies.

## The typed client

`FountainKit` is the same API with the JSON resolved into types: `Agent`,
`Conversation`, `LogEvent`, `Block`, `AuthMe`, `AdminUser`, and a resource
namespace each. Errors are an enum (`FountainError`) you branch on by case
and by server `code`, and every server enum decodes unknown values instead of
throwing, so a new runtime never crashes a shipped app.

```swift
import FountainKit

let client = FountainClient(config: FountainConfig(baseURL: url, apiKey: key))
let me = try await client.auth.me()          // the cheapest key check
for agent in try await client.agents.list() {
    print(agent.name, agent.model)
}

let run = try await client.run("Review this repository", agent: agent.id)
for try await event in run.events {
    if case .text(let chunk) = event { print(chunk, terminator: "") }
}
let result = try await run.value()           // text, tools used, end state
```

`run.events` replays from the beginning for every subscriber and follows the
turn once, so a window and a menu-bar item can watch the same run without
opening a second stream. A failed *turn* is a `RunResult` with a non-`done`
state; only client-side failures throw.

Transcript links in `Run.url`, conversation events, and `RunResult.url` use
`FountainConfig.appURL`. Without it, they open the deployment's `/dashboard`;
the retired `/conversations/:id` browser route is no longer used. To configure
run links from the server's catalog before starting a run:

```swift
let catalog = try await client.catalog()
var config = client.config
config.appURL = catalog.apps?.conversations.flatMap { $0.isEmpty ? nil : URL(string: $0) }
let linkedClient = FountainClient(config: config)
let linkedRun = try await linkedClient.run("Review this repository", agent: agent.id)
```

For an existing conversation, `client.conversationURL(id, apps: catalog.apps)`
uses the catalog app first, then `config.appURL`, then `/dashboard`. The dashboard
is a navigation fallback; it does not display the transcript.

It wraps more of the API than `Fountain` does — admin, audit, runners, API
keys, `apply`, agent avatars, turn images — and reaches anything unwrapped
through `client.request(_:_:)`. See
[docs/api-surface.md in swift-goat](https://github.com/jhgaylor/swift-goat/blob/main/docs/api-surface.md)
for the operation-by-operation map, and swift-goat itself for a macOS app
built on it.

## Credentials

`Fountain()` resolves credentials the same way as the Fountain CLI. It throws
if the base URL it resolves has no scheme or no host:

```text
apiKey:  argument -> FOUNTAIN_API_KEY -> FOUNTAIN_TOKEN -> ~/.fountain/credentials
baseURL: argument -> FOUNTAIN_BASE_URL -> ~/.fountain/credentials -> hosted Fountain
```

Use `profile:` for another credentials-file profile. In a Fountain sandbox,
the SDK also sends `FOUNTAIN_CONVERSATION_ID` as the parent-conversation header.

## Stream a run

Every access to `events` is an independent replaying subscription to the same
run. It never starts a second API request, and a text-only stream is available.

```swift
let run = fountain.run("Review this repository", agent: "reviewer")
for try await event in run.events {
    switch event {
    case .tool(let name, _): print("->", name)
    case .text(let text): print(text, terminator: "")
    case .permission(let request, _):
        if let allow = request.options.first(where: { $0.kind == "allow_once" }) {
            try await run.answer(requestID: request.requestID, optionID: allow.optionID)
        }
    default: break
    }
}
let result = try await run.value()
```

`cancel()` only stops the SDK wait. Use `interrupt()` to stop the current turn
or `terminate()` to tear down its sandbox. Failed agent turns are successful
`RunResult` values with `.failed`; HTTP, transport, resolution, and SDK timeout
failures throw `FountainError` with a typed `kind` and retry metadata.

## Resources and the raw API

`agents`, `environments`, and `vaults` provide async list/get/create/update/
delete methods. Environments and vaults expose write-only secret helpers.
`team` provides durable teammates and schedules. Resource input uses
`JSONObject`, whose `JSONValue` values support Swift literal syntax.

```swift
let environment = try await fountain.environments.create([
    "name": "fountain-ci",
    "packages": ["apt": ["ripgrep"]]
])
try await fountain.vaults.secrets.set("github-bot", key: "GITHUB_TOKEN", value: token)

let audit = try await fountain.request("GET", "/api/audit", query: ["limit": "50"])
```

## Develop

Run from the repository root:

```bash
swift test
swift build -Xswiftc -warnings-as-errors
```

## Credit error migration

Replace `FountainError.Kind.subscriptionRequired` with
`FountainError.Kind.insufficientCredits` in the `Fountain` product, including
switches and stored raw kind strings. The raw value is now `insufficientCredits`.
Read `error.upgradeURL` for the purchase page. `FountainKit` already uses
`.insufficientCredits(body, upgradeURL:)`; its case and associated URL remain unchanged.
Both products retire the special `subscription_required` wire mapping.

This source API boundary (#2104) ships in Swift v0.17.0. Use that tag or
newer to adopt the credit error names; earlier tags keep their original names.

For billing error handling, use Fountain v0.13.0 or newer.
[v0.13.0](https://github.com/managoat/fountain/releases/tag/v0.13.0) is the first
release containing the credit-only server contract (`c3349343`).
`insufficient_credits` and a generic HTTP 402 identify the credit gate.
`subscription_required` has no special mapping; it follows the HTTP status.
The response still exposes its original code and purchase URL.
