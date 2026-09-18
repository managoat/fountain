defmodule Fountain.Factory do
  @moduledoc """
  Test factories for AoD. Lean and explicit — no factory_bot magic.

  Each `*_attrs/1` returns a map suitable for the corresponding context's
  create function. `insert_*/1` writes the row through the regular
  changeset so tests have realistic data, but factories accept *both*
  keyword lists and atom-keyed maps for ergonomics in tests.
  """

  alias Fountain.Repo
  require Ecto.Query
  alias Fountain.Conversations.{Conversation, LogEvent, Sandbox, Turn}

  defp uniq, do: System.unique_integer([:positive, :monotonic]) |> Integer.to_string()

  # ── users ─────────────────────────────────────────────────────────────────

  def user_attrs(overrides \\ %{}) do
    Map.merge(
      %{"email" => "user#{uniq()}@example.com", "password" => "password123"},
      to_string_map(overrides)
    )
  end

  def insert_user(overrides \\ %{}) do
    attrs = user_attrs(overrides)
    {:ok, user} = Fountain.Accounts.register_user(attrs)
    user
  end

  @doc """
  A verified user, with everything verification gives an account: the $5
  opening credit (ADR 0031) and the `starter` agent (ADR 0038). Both are real
  rows, because both are what a verified account really has — see
  `insert_empty_user/1` and `insert_user_without_agents/1` for the tests that
  need one of them gone.
  """
  def insert_verified_user(overrides \\ %{}) do
    user = insert_user(overrides)
    {:ok, verified} = Fountain.Accounts.verify_email(user)
    verified
  end

  @doc """
  A verified user. The same as `insert_verified_user/1` since ADR 0031 — there
  is no subscription to be active — kept so the many tests that reach for
  "an account that may spend" keep reading.
  """
  def insert_active_user(overrides \\ %{}), do: insert_verified_user(overrides)

  @doc """
  Delete the starter agent verification plants (ADR 0038, #1389).

  Every verified account owns one, so `insert_verified_user/1` no longer
  produces an account with no agents. Tests whose subject is a *controlled* set
  of agents — a filter's arithmetic, the empty state, an export's contents —
  call this first and then insert exactly what they mean to count. Tests whose
  subject is a real surface should show the starter rather than delete it: an
  account listing its agents genuinely has this one.

  Deletes the row directly rather than through `Agents.delete_agent/2`, so a
  test asserting on the audit trail sees no `agent.deleted` it did not cause.
  Raises when there is no starter to delete, so this cannot quietly become a
  no-op if the planting moves.
  """
  def delete_starter_agent(%{id: user_id}), do: delete_starter_agent(user_id)

  def delete_starter_agent(user_id) when is_binary(user_id) do
    name = Fountain.Agents.Starter.name()

    {1, _} =
      Repo.delete_all(
        Ecto.Query.from(a in Fountain.Agents.Agent,
          where: a.user_id == ^user_id and a.name == ^name
        )
      )

    :ok
  end

  @doc """
  A verified user with no agents: `insert_verified_user/1` with the starter
  agent removed. See `delete_starter_agent/1`.
  """
  def insert_user_without_agents(overrides \\ %{}) do
    user = insert_verified_user(overrides)
    :ok = delete_starter_agent(user)
    user
  end

  @doc """
  A verified user with an empty ledger: the opening credit every verified
  account gets (ADR 0031) wiped and the balance recomputed to zero. For the
  tests that assert exact ledger arithmetic from a blank slate; such an
  account cannot spend until a test grants it something.
  """
  def insert_empty_user(overrides \\ %{}) do
    user = insert_verified_user(overrides)
    uid = user.id
    Repo.delete_all(Ecto.Query.from(e in Fountain.Credits.LedgerEntry, where: e.user_id == ^uid))

    Repo.delete_all(
      Ecto.Query.from(a in Fountain.Audit.Event,
        where: a.user_id == ^uid and like(a.action, "credit.%")
      )
    )

    Fountain.Credits.recompute_balance(user.id)
    Repo.reload!(user)
  end

  def insert_api_key(user, name \\ nil, opts \\ []) do
    name = name || "key-#{uniq()}"
    {:ok, {key_record, raw_key}} = Fountain.Accounts.create_api_key(user.id, name, opts)
    {key_record, raw_key}
  end

  @doc """
  A key with the narrow scope handed to sandboxes — the credential an agent
  running inside a sprite actually holds.
  """
  def insert_sprite_api_key(user, opts \\ []) do
    insert_api_key(user, "sprite:#{uniq()}", Keyword.put_new(opts, :scopes, ["sprite"]))
  end

  # ── OAuth clients (#1125) ─────────────────────────────────────────────────

  def oauth_client_attrs(overrides \\ %{}) do
    Map.merge(
      %{"name" => "app-#{uniq()}", "redirect_uris" => ["https://app-#{uniq()}.test/callback"]},
      to_string_map(overrides)
    )
  end

  @doc """
  A registered OAuth client. `published: true` is written straight to the row
  because publishing is an operator flip with no self-serve path -- there is
  no context function that would do it.
  """
  def insert_oauth_client(overrides \\ %{}) do
    overrides = to_string_map(overrides)
    {user_id, overrides} = Map.pop_lazy(overrides, "user_id", fn -> insert_verified_user().id end)
    {published, overrides} = Map.pop(overrides, "published", false)

    {:ok, client} = Fountain.OAuth.create_client(user_id, oauth_client_attrs(overrides))

    if published do
      client
      |> Ecto.Changeset.change(published: true)
      |> Fountain.Repo.update!()
    else
      client
    end
  end

  # ── connections (#1178) ───────────────────────────────────────────────────

  @doc """
  A stored platform connection with a refresh token and a fresh access token,
  as `Fountain.Connections.connect/4` would persist after a consent. No
  network: the grant map is what `OAuth.exchange_code/4` returns. The
  provider defaults to the fixture extension's (`fixture-svc`), the one
  platform provider every suite has since Google, Microsoft and Slack became
  extensions of their own (#2152); pass `provider: "google"` (a slug, or a
  `%Provider{}` for a tenant's own) where a suite has that extension loaded.
  """
  def insert_connection(user, overrides \\ %{}) do
    overrides = Map.new(overrides, fn {k, v} -> {to_string(k), v} end)
    provider = overrides["provider"] || "fixture-svc"

    grant = %{
      refresh_token: Map.get(overrides, "refresh_token", "refresh-#{uniq()}"),
      access_token: overrides["access_token"] || "access-#{uniq()}",
      expires_at:
        overrides["expires_at"] ||
          DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second),
      scopes: overrides["scopes"] || ["read"],
      account_email: overrides["account_email"] || "user-#{uniq()}@example.com"
    }

    {:ok, conn} = Fountain.Connections.connect(user.id, provider, grant)
    conn
  end

  @doc """
  A tenant `oauth2` provider (#1186): the tenant's own app registration at
  a service, with its endpoints on the Req.Test host.
  """
  def insert_provider(user, overrides \\ %{}) do
    {:ok, provider} = Fountain.Connections.create_provider(user.id, provider_attrs(overrides))
    provider
  end

  def provider_attrs(overrides \\ %{}) do
    overrides = to_string_map(overrides)
    n = uniq()

    Map.merge(
      %{
        "slug" => "svc-#{n}",
        "name" => "Service #{n}",
        "kind" => "oauth2",
        "authorize_url" => "https://svc.example/oauth/authorize",
        "token_url" => "https://svc.example/oauth/token",
        "userinfo_url" => "https://svc.example/user",
        "account_label_path" => "login",
        "scopes" => ["read"],
        "client_id" => "client-#{n}",
        "client_secret" => "secret-#{n}",
        "token_hosts" => ["api.svc.example"]
      },
      overrides
    )
  end

  # ── environments ──────────────────────────────────────────────────────────

  def env_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        "name" => "env-#{uniq()}",
        "packages" => %{},
        "env_vars" => %{},
        "setup_script" => "",
        "networking_type" => "unrestricted",
        "networking_config" => %{},
        "repositories" => []
      },
      to_string_map(overrides)
    )
  end

  def insert_env(overrides \\ %{}) do
    overrides = to_string_map(overrides)
    overrides = Map.put_new_lazy(overrides, "user_id", fn -> insert_verified_user().id end)
    {:ok, env} = Fountain.Environments.create_environment(env_attrs(overrides))
    env
  end

  def insert_secret(env, overrides \\ %{}) do
    attrs =
      %{"key" => "TEST_KEY_#{uniq()}", "value" => "test-value-#{uniq()}"}
      |> Map.merge(to_string_map(overrides))

    {:ok, dek} = Fountain.Crypto.load_tenant_key(env.user_id)
    {:ok, secret} = Fountain.Environments.upsert_secret(env, attrs, dek)
    secret
  end

  # ── vaults ────────────────────────────────────────────────────────────────

  def vault_attrs(overrides \\ %{}) do
    Map.merge(
      %{"name" => "vault-#{uniq()}", "description" => ""},
      to_string_map(overrides)
    )
  end

  def insert_vault(overrides \\ %{}) do
    overrides = to_string_map(overrides)
    overrides = Map.put_new_lazy(overrides, "user_id", fn -> insert_verified_user().id end)
    {:ok, vault} = Fountain.Vaults.create_vault(vault_attrs(overrides))
    vault
  end

  def insert_vault_secret(vault, overrides \\ %{}) do
    attrs =
      %{"key" => "TEST_KEY_#{uniq()}", "value" => "test-value-#{uniq()}"}
      |> Map.merge(to_string_map(overrides))

    {:ok, dek} = Fountain.Crypto.load_tenant_key(vault.user_id)
    {:ok, secret} = Fountain.Vaults.upsert_secret(vault, attrs, dek)
    secret
  end

  # ── agents ────────────────────────────────────────────────────────────────

  def agent_attrs(overrides \\ %{}) do
    overrides = to_string_map(overrides)
    runtime = Map.get(overrides, "runtime", "claude")

    Map.merge(
      %{
        "name" => "agent-#{uniq()}",
        # The changeset requires the provider prefix to match the runtime
        # (#553), so a call site that overrides only :runtime still gets a
        # model its runtime can actually reach. The acp runtime is the
        # inverse: no model at all, and a command instead (#1634).
        "model" => default_model_for(runtime),
        "runtime" => runtime,
        "skills" => [],
        "mcp_servers" => %{},
        "metadata" => %{}
      }
      |> Map.merge(default_command_for(runtime)),
      overrides
    )
  end

  defp default_model_for("codex"), do: "openai/gpt-5.3-codex"
  defp default_model_for("gemini"), do: "google/gemini-3.1-pro-preview"
  defp default_model_for("acp"), do: nil
  defp default_model_for(_runtime), do: "anthropic/claude-sonnet-4-6"

  defp default_command_for("acp"), do: %{"runtime_command" => "fixture-agent"}
  defp default_command_for(_runtime), do: %{}

  def insert_agent(overrides \\ %{}) do
    overrides = to_string_map(overrides)
    overrides = Map.put_new_lazy(overrides, "user_id", fn -> insert_verified_user().id end)
    {:ok, agent} = Fountain.Agents.create_agent(agent_attrs(overrides))
    agent
  end

  # ── conversations / sandboxes / turns ─────────────────────────────────────

  def insert_sandbox(overrides \\ %{}) do
    overrides_map = to_atom_map(overrides)
    user_id = Map.get(overrides_map, :user_id) || insert_verified_user().id

    attrs =
      %{machine_name: "test-sprite-#{uniq()}", status: "pending", user_id: user_id}
      |> Map.merge(overrides_map)

    attrs =
      if attrs[:mode] == "persistent",
        do: Map.put_new_lazy(attrs, :runtime, fn -> sandbox_runtime(overrides_map) end),
        else: attrs

    sandbox =
      %Sandbox{}
      |> Sandbox.changeset(attrs)
      |> Repo.insert!()

    # `inserted_at` is when a sandbox started costing money, so anything
    # testing spend attribution has to be able to place one in the past. The
    # changeset does not cast it (nothing in the app sets it), so back-date the
    # row directly.
    case Map.get(overrides_map, :inserted_at) do
      nil -> sandbox
      at -> sandbox |> Ecto.Changeset.change(inserted_at: at) |> Repo.update!()
    end
  end

  defp sandbox_runtime(%{agent_id: agent_id}) when is_binary(agent_id) do
    case Repo.get(Fountain.Agents.Agent, agent_id) do
      nil -> "claude"
      agent -> agent.runtime
    end
  end

  defp sandbox_runtime(_attrs), do: "claude"

  def insert_conversation(overrides \\ %{}) do
    overrides_map = to_atom_map(overrides)

    agent =
      Map.get(overrides_map, :agent) ||
        case Map.get(overrides_map, :agent_id) do
          nil -> nil
          agent_id -> Repo.get(Fountain.Agents.Agent, agent_id)
        end

    user_id =
      Map.get(overrides_map, :user_id) ||
        (agent && agent.user_id) ||
        insert_verified_user().id

    sandbox = Map.get(overrides_map, :sandbox) || insert_sandbox(user_id: user_id)

    base = %{
      sandbox_id: sandbox.id,
      agent_id: agent && agent.id,
      user_id: user_id,
      # A conversation's runtime is snapshotted from its agent in production;
      # a factory row that disagrees with its own agent misleads every test
      # that branches on it.
      runtime: (agent && agent.runtime) || "claude",
      status: "pending"
    }

    attrs = Map.merge(base, Map.drop(overrides_map, [:sandbox, :agent]))

    %Conversation{}
    |> Conversation.changeset(attrs)
    |> Repo.insert!()
    |> Repo.preload([:sandbox, :agent])
  end

  def insert_turn(conv, overrides \\ %{}) do
    attrs =
      %{
        conversation_id: conv.id,
        turn_number: Fountain.Conversations._unsafe_next_turn_number(conv.id),
        prompt: "test prompt",
        status: "pending"
      }
      |> Map.merge(to_atom_map(overrides))

    %Turn{}
    |> Turn.changeset(attrs)
    |> Repo.insert!()
  end

  def insert_log_event(conv, overrides \\ %{}) do
    attrs =
      %{
        conversation_id: conv.id,
        kind: "output",
        stream: "stdout",
        data: "test data",
        inserted_at: DateTime.utc_now() |> DateTime.truncate(:second)
      }
      |> Map.merge(to_atom_map(overrides))

    %LogEvent{}
    |> LogEvent.changeset(attrs)
    |> Repo.insert!()
  end

  # ── key helpers ───────────────────────────────────────────────────────────

  # Always return a map keyed by strings.
  def to_string_map(input) when is_list(input), do: input |> Map.new() |> to_string_map()

  def to_string_map(input) when is_map(input) do
    Map.new(input, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end

  # Always return a map keyed by atoms (where atoms exist).
  def to_atom_map(input) when is_list(input), do: input |> Map.new() |> to_atom_map()

  def to_atom_map(input) when is_map(input) do
    Map.new(input, fn
      {k, v} when is_atom(k) -> {k, v}
      {k, v} when is_binary(k) -> {safe_to_existing_atom(k, k), v}
    end)
  end

  defp safe_to_existing_atom(s, fallback) do
    String.to_existing_atom(s)
  rescue
    ArgumentError -> fallback
  end
end
