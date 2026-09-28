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
| `examples/deepagents-contractor` | LangChain-compatible wrapper over the OpenAI-compatible endpoint; its `run` was not the native SDK helper | **Removed** with the endpoint it wrapped ([ADR 0057](../decisions/0057-retire-public-compatibility-protocols.md), [#2252](https://github.com/managoat/fountain/issues/2252)). No migration: a stock `ChatOpenAI` has no native equivalent, and `docs/integrations/langchain.md` says so |
| SDK conformance/tests | Exercise supported public conveniences and behavior | Keep independent coverage. The compatibility API they once verified is retired ([ADR 0057](../decisions/0057-retire-public-compatibility-protocols.md)); what remains is native and stays covered on its own terms |
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
- Fountain Team, Drydock and Paddock's proxy build inputs around
  app-owned project/channel/sandbox policies.
- No SDK `fountain.run`, `client.run` or `sdk.run` call was found in that
  snapshot. Generic `.run` search hits also include database calls.

Those apps own their thread persistence and streams, and some create promptless
tabs. Replacing every creation call with `runRequest` would change behavior.
[managoat/demos#76](https://github.com/managoat/demos/issues/76) owned generated
input adoption, SDK upgrades and app-specific validation; it closed with
[managoat/demos#77](https://github.com/managoat/demos/pull/77), merged
2026-09-15: SDK 5.2.1 pins, shared generated input types, app-owned launch
policies, and regression tests. Merged there is not deployed here; this
inventory still claims no deployed-app migration.

## Remaining gates

The next genuine optional field should record the server changes, generated
diffs and caller edits it actually needs. The foundation's current propagation
evidence is a temporary synthetic field, not an invented public API field.
Swift and CLI are available in [v0.17.1](https://github.com/managoat/fountain/releases/tag/v0.17.1).
Release and real-field evidence remains tracked in
[#2248](https://github.com/managoat/fountain/issues/2248).
