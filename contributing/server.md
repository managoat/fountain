# Server conventions

Read the relevant sections when changing `apps/` or server configuration.
Paths below are relative to the repository root. These are the server's
implementation rules; [CONTRIBUTING.md](../CONTRIBUTING.md) covers checks and PRs.

## Tenant isolation

Every user-facing query is scoped by `user_id`: `Agents.get_agent(id, user_id)`,
`Agents.list_agents(user_id, filters)`. Functions that bypass scoping carry the
`_unsafe_` prefix, on *every* unscoped function, so a call site never has to
be researched. **Never call one as the first fetch in a user-facing request.**
Legitimate callers: an admin surface behind `require_admin`, a system sweep
(the rehydrator, `SandboxReaper`), a GenServer that already established
ownership, or a user-facing call site directly after a tenant-scoped parent
fetch, adjacent and in the same function, with a comment naming the fetch:

```elixir
# ownership established by the scoped get_vault above
vault = Vaults.get_vault(vault_id, user.id)
secrets = Vaults._unsafe_list_secrets(vault)
```

A credo check (`credo/checks/unsafe_call_ownership.ex`) enforces the shape.

## Secrets

Environment and vault values are envelope-encrypted with a per-tenant DEK
derived from `MASTER_SECRETS_KEY`:

```elixir
{:ok, dek} = Fountain.Crypto.load_tenant_key(user_id)
Environments.upsert_secret(env, %{"key" => "TOKEN", "value" => "plaintext"}, dek)  # string keys
%{"TOKEN" => "plaintext"} = Environments.decrypted_env(env, dek)                    # a plain map
```

`Fountain.Substitution.apply(value, vars)` resolves `${VAR}` (and `$$` to `$`)
recursively through maps and lists, returning `{:ok, result}` or
`{:error, {:missing_vars, sorted_list}}` with **every** missing var.

## Audit

**Mutations audit in the context, not the caller** (ADR 0013). The context
records its own event; the caller supplies attribution only:

```elixir
def create_agent(attrs, opts \\ []) do
  %Agent{} |> Agent.changeset(attrs) |> Repo.insert() |> audited("agent.created", opts)
end
Agents.create_agent(attrs, Audited.attribution(conn))   # or (socket); actor: "system:<worker>" from a worker
```

- **Never audit inside a transaction.** `record/1` is best-effort by
  rescuing, and a rescue does not survive an aborted transaction.
- **Never record values.** Update events name changed fields
  (`Audit.changed_fields/1`); secret and credential events record keys, sizes
  and providers.
- **Only record what happened.** A rejected changeset or a no-op sync
  records nothing.

The actor vocabulary is closed (`self`, `ui`, `api`, `sprite`, `admin`,
`admin:<operator_id>`, `system:<worker>`); a bare `"system"` is a defect, so
the unauthenticated routes pass an explicit actor. `audit_guardrail_test.exs`
fails on a new context mutation until it audits or is excluded with a reason.
`Audit.record!/1` is test-only.

## Concurrency and usage (ADR 0005, 0042)

Nothing is priced, granted or gated on spend: credits and billing were removed
on 2026-10-12 (ADR 0031, retired).

- **The cap is an override else a ceiling.** `Quotas.sandbox_limit/1` is the
  account's `sandbox_limit_override` when an operator set one, else
  `SANDBOX_CAP_CEILING`; `SANDBOX_FLEET_CEILING` is global and `:fleet_full`
  is 503. Both are enforced under the reservation lock in
  `Quotas.with_sandbox_reservation/3`. Anything that displays a cap uses
  `Quotas.sandbox_limit_for/1`.
- **A turn hour is not a sandbox hour.** `usage_events` (`Fountain.Usage`)
  record `turn_seconds` per turn; `busy_seconds` in `Fountain.Machines.Usage`
  is the union of intervals and relates to a provider bill. Several
  conversations share one sandbox, so the two differ and must not be swapped.

## Surfaces

The browser UI is an **operator console** (dashboard, agents, environments,
vaults, audit, keys, account, admin). Watching a conversation and messaging a
team are separate apps on `/api` ([managoat/demos](https://github.com/managoat/demos));
`Fountain.Apps` is the only place that knows where they live, and retired
`/conversations*`, `/team*` and `/onboarding*` URLs 404. **A
conversation-facing feature goes in the app; marketing copy goes in
[managoat/site](https://github.com/managoat/site)** (ADR 0034). The boundary is
`docs/concepts/surfaces.md`.

## Web plumbing

- `FountainWeb.Live.Hooks` `on_mount` guards: `require_authenticated_user`
  and `require_pending_verification` use `redirect` (`{:redirect, _}` in
  tests); `require_admin` sends a non-admin on with `push_navigate`
  (`{:live_redirect, _}`).
- `FountainWeb.Plugs.RateLimit` is ETS-backed per node and runs twice on
  `:api`, by IP before auth and by API key after. `config/test.exs` keys it
  per test process (`rate_limit_test_isolation`).
- `UeberAuthController` skips `plug Ueberauth` under `ueberauth_test_mode` so
  tests can set `conn.assigns` by hand.

## Tests

- `use Fountain.DataCase, async: true` for anything touching the database;
  `use ExUnit.Case, async: true` otherwise. StreamData and Mimic are
  installed; prefer real changesets over mocks.
- Factories are in `test/support/factory.ex`, imported by `DataCase`:
  `insert_verified_user()`, `insert_agent(user_id: ...)`, `insert_env`,
  `insert_vault`. `*_attrs/1` helpers return **string-keyed** maps.
- `mix test` at the umbrella root runs everything. CI's partitions run from
  `apps/fountain`.
- A test that fails and then passes with no code change is investigated, not
  re-run: [failure handling](../CONTRIBUTING.md#if-a-test-went-red-and-then-green).

## Things not to do

- Don't call `_unsafe_*` without established ownership (above).
- Don't lower the test pool size below 20, and don't remove
  `ueberauth_test_mode` or `rate_limit_test_isolation` from `config/test.exs`.
- Don't add `async: false` unless the test genuinely needs global state.
- Don't start fire-and-forget work with `Task.async`: it links, nothing
  awaits it, and a transient failure takes the caller down (#1040). Use
  `Task.Supervisor.start_child(Fountain.TaskSupervisor, fun)`; `DataCase`
  waits for those before stopping the sandbox owner.
- Don't describe unbuilt behaviour as built in an ADR or a docstring. Say
  `**Status:** Proposed` or "not yet built", and remove the caveat in the PR
  that builds it.
- Check that an issue or PR reference supports the statement it accompanies.
