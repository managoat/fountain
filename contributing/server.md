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

## Concurrency and usage (ADR 0005)

Nothing is priced, granted or gated on spend: credits and billing were removed
on 2026-10-12 (ADR 0031, retired).

- **One ceiling per provider, no per-account cap, no queue.** Each provider
  has its own ceiling (`SANDBOX_FLEET_CEILING_<PROVIDER>`, defaulting to
  `SANDBOX_FLEET_CEILING`), counted across every account; `:fleet_full` is
  503. It is enforced under that provider's reservation lock in
  `Quotas.with_sandbox_reservation/2`, which requires `provider:`. A refused start is the caller's to
  retry. ADR 0042, the bounded queue that used to sit in front of it, is
  retired; its 2026-10-13 addendum records why.
- **No metering.** Usage is plain counts read from the `conversations` and
  `turns` tables (`Conversations.activity_counts/3`, `token_usage/3`); there
  is no event log and no per-provider roll-up of sandbox time. The provider
  invoice is the cost authority (ADR 0079).

## Surfaces

The server-rendered browser UI is an **operator console** (dashboard, audit,
admin). Account settings are session-authenticated LiveViews at `/account`
(ADR 0088), sharing the account contexts with the retained API. Admin-key issuance
stays under `/admin/keys`; ordinary account keys never have admin scope.
Watching a conversation, and configuring agents, environments and
vaults, is a separate app on `/api` ([managoat/demos](https://github.com/managoat/demos))
plus the CLI (ADR 0076); `Fountain.Apps` is the only place that knows where the
app lives, and retired `/conversations*`, `/team*`, `/onboarding*`,
`/agents*`, `/environments*` and `/vaults*` URLs 404. **A conversation-facing
or configuration feature goes in the app, the CLI and the API.** The only public page the
server renders is the manual at `/docs`; `/` redirects to the console. The
boundary is `docs/concepts/surfaces.md`.

## Web plumbing

- `FountainWeb.Live.Hooks` `on_mount` guards: `require_authenticated_user`
  uses `redirect` (`{:redirect, _}` in tests); `require_admin` sends a
  non-admin on with `push_navigate` (`{:live_redirect, _}`).
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
