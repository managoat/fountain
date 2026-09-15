# Conversation caller inventory

Follow-up: [#2249](https://github.com/managoat/fountain/issues/2249).
Foundation: [ADR 0056](../decisions/0056-conversation-request-inputs.md).

## Fountain repository

| Caller | Identity and execution ownership | Disposition |
|---|---|---|
| `docs/snippets/first-request.ts`, `Fountain.Onboarding`, start page | Server already has the selected agent ID; SDK follows the first turn | Use `runRequest` with `agent_id`; catalog and CLI share the same snippet |
| CLI first-request renderer | Reads the catalog; substitutes selected ID and raw key | Already supports the ID placeholder; test both current and older name-based catalog snippets |
| FountainKit README examples | Caller already has an agent ID; SDK owns following | Use generated `ConversationCreateRequest` and `runRequest`; state tagged-release availability |
| TypeScript/Python/Elixir README examples | Many intentionally start from resource names | Keep name conveniences documented; direct IDs and complete field coverage use the existing API-shaped launch sections linked below |
| Hermes `FountainTools._run` | User tool accepts names; plugin owns polling, turn tracking and wait=false | Resolve names and translate tool arguments once, then pass an API-shaped map through the internal client. Preserve the tool schema and polling behavior |
| `examples/deepagents-contractor` | LangChain-compatible wrapper over the OpenAI-compatible endpoint; its `run` is not the native SDK helper | Retain until protocol retirement [#2252](https://github.com/managoat/fountain/issues/2252) provides its migration |
| SDK conformance/tests | Exercise supported public conveniences and behavior | Keep independent coverage; do not mechanically migrate tests away from the compatibility API they verify |
| CLI `run` and agent-manifest examples | User-facing name/flag conveniences and CLI-owned following | Retain the public CLI path; `conv create --file` is the complete API-shaped creation path |

For resource IDs or full API-field coverage, use the existing request APIs:
[TypeScript `runRequest`](../sdk/typescript/README.md#api-shaped-launches),
[Python `run_request`](../sdk/python/README.md#api-shaped-launches), and
[Elixir `run_request`](../sdk/elixir/README.md#api-shaped-launches).
Local run options stay outside API-shaped request bodies. These packaged README
sections already shipped with the foundation; this caller migration leaves
those packages unchanged.

No public SDK helper is removed by caller migration. The remaining name-based
examples are evidence that those conveniences still serve a purpose. Their
implementations should share the launch behavior rather than duplicate it
([#2250](https://github.com/managoat/fountain/issues/2250)).

## Demo applications

Read-only inventory of `managoat/demos` at
`8fb083dc967fca74d89bd1d417b379a4afe5288b`:

- Workbench uses `api.data` with its product-specific `startBody`; Workbench
  and Salon pin TypeScript SDK 1.25.0.
- Mission Control, Fountain Conversations and Paddock pass API-shaped input
  objects through local HTTP clients, with handwritten input-type subsets.
- Fountain Team, Drydock, Switchyard and Paddock's proxy build inputs around
  app-owned project/channel/sandbox policies.
- No SDK `fountain.run`, `client.run` or `sdk.run` call was found in that
  snapshot. Generic `.run` search hits also include database calls.

Those apps own their thread persistence and streams, and some create promptless
tabs. Replacing every creation call with `runRequest` would change behavior.
[managoat/demos#76](https://github.com/managoat/demos/issues/76) owns generated
input adoption, SDK upgrades and app-specific validation. This inventory is not
a claim that those external applications were migrated.

## Remaining gates

The next genuine optional field should record the server changes, generated
diffs and caller edits it actually needs. The foundation's current propagation
evidence is a temporary synthetic field, not an invented public API field.
Swift/CLI tagged release availability is tracked in
[#2248](https://github.com/managoat/fountain/issues/2248).
