# Sandbox name retirement plan

Status: the internal field change is implemented. Database and public contract
retirement remain open in [#2108](https://github.com/managoat/fountain/issues/2108).
No removal release is scheduled for those contracts.

## Current boundary

`Fountain.Conversations.Sandbox.machine_name` is the single application field for
the provider-scoped machine name. Ecto maps it to the existing `sprite_name`
column. Internal changeset attributes, queries, fixtures, runner lookup and
provider handle construction use `machine_name`. There is no second struct field
or fallback input alias. Internal scripts and extensions that construct Sandbox
attributes must use the new field when upgrading their application code.

| Surface | Current name and next step |
| --- | --- |
| Ecto schema and lifecycle | `machine_name`, mapped with `source: :sprite_name` |
| PostgreSQL `sandboxes` | `sprite_name`; historical migrations and operational SQL remain valid |
| Conversation create input | `sprite_name` suffix and existing validation error codes |
| Conversation, sandbox and admin JSON; OpenAPI | `sprite_name`; explicit serializers translate the internal field |
| TypeScript SDK | Existing `sprite_name` wire field and its accessor |
| CLI conversation display | Reads the existing `sprite_name` response key |
| Billing, audit and persisted provisioning stage metadata | Existing `sprite_name` keys; no rewrite of history |
| Provisioning telemetry | Existing `sprite_name` metadata key |
| Provider adapters | Existing `Handle.name` values; `provider`, `provider_meta` and `provider_instance_id` unchanged |

Existing rows need no migration or backfill. New code reads the same column as
old code, including during a rolling deploy. Lookup, attach, reset, checkpoint,
execution fences, retirement and reaper queries all use the same stored name.
The account prefix, caller suffix rules and runner name format do not change.
This does not claim in-place BEAM hot-code upgrade compatibility for old Sandbox
structs; deploy the application through its normal node replacement path.

## Remaining stages

1. Audit supported API clients, SDK consumers, event readers and operational SQL.
   Record their owners and release floors before promising a removal date.
   Introduce a public `machine_name` field only through an explicit contract
   change, with SDK releases, generated OpenAPI and conformance updates together.
   Define how conflicting request fields behave during any transition.
2. Establish the database identity policy in
   [#1919](https://github.com/managoat/fountain/issues/1919). Audit production
   duplicates before enforcing a new name-based unique index. The existing
   provider-instance identity recording and indexes are separate and unchanged
   by this field mapping.
3. Plan a forward-only database transition after the supported writer and SQL
   consumer floors are known. Release migrations run before all old nodes exit,
   so a direct column rename in the first new release is unsafe. Any replacement
   column needs a staged write/read transition and verification before retiring
   the old column. Preserve actual provider names and existing rows throughout.
4. Choose and publish the API and database removal release with upgrade notes
   after those inventories and transition evidence exist. Keep historical event
   readers working for the retained history, even after live producers change.
   Remove the Ecto source mapping only when the database transition completes.

The first stage reduces internal provider-specific naming without changing any
of these outstanding storage, event or public contracts. It does not close
#2108 or resolve #1919.
