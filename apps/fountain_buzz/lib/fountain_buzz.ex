defmodule FountainBuzz do
  @moduledoc """
  Context for Buzz identities and the environment a hosted `buzz-acp` runs with
  (ADR 0020, Phase 1 — tracker #735 / gate #736).

  A Buzz identity binds a Nostr keypair (in a vault) to a Fountain agent. This
  context owns the tenant-scoped CRUD for those bindings and the one function
  that turns a binding into a launch spec for `FountainBuzz.Harness`:
  `harness_launch/2` mints a scoped API key for the owner, decrypts the vault's
  `BUZZ_*` secrets **server-side**, and assembles the full process environment.

  The nsec never leaves the server: it goes from the vault into the harness
  process env, and the harness's ACP child (`fountain acp`) authenticates to
  this instance with the freshly-minted key — no human credentials file, and
  nothing about the identity travels into the sandbox.
  """

  import Ecto.Query, only: [from: 2]

  alias Fountain.{Accounts, Audit, Conversations, Crypto, Environments, Repo, Vaults}
  alias FountainBuzz.Identity

  # ── identities (tenant-scoped) ─────────────────────────────────────────────

  @doc "WARNING: lookup by id without owner check. Admin/internal/supervisor use only."
  def _unsafe_get_identity(id), do: Repo.get(Identity, id)

  @doc "List every enabled identity across tenants. System sweep only (the boot supervisor)."
  def _unsafe_list_enabled_identities do
    Repo.all(from i in Identity, where: i.enabled == true)
  end

  @doc "List identities scoped to a user."
  def list_identities(user_id) when is_binary(user_id) do
    Repo.all(
      from i in Identity,
        where: i.user_id == ^user_id,
        order_by: [desc: i.inserted_at, desc: i.id]
    )
  end

  @doc "Fetch one identity scoped to a user. Returns nil if missing or not owned."
  def get_identity(id, user_id) when is_binary(id) and is_binary(user_id) do
    Repo.get_by(Identity, id: id, user_id: user_id)
  end

  @doc """
  Fetch the identity that drives a given vault, scoped to a user. This is how
  a Buzz-driven conversation is recognised: the hosted harness runs
  `fountain acp --agent … --vault <vault>`, so its conversations carry that
  vault. Returns nil if the vault is not a Buzz identity vault (or not owned).
  """
  def get_identity_by_vault(vault_id, user_id) when is_binary(vault_id) and is_binary(user_id) do
    Repo.get_by(Identity, vault_id: vault_id, user_id: user_id)
  end

  @doc "Fetch an identity by its Nostr pubkey, scoped to a user. The convergence key."
  def get_identity_by_pubkey(pubkey, user_id) when is_binary(pubkey) and is_binary(user_id) do
    Repo.get_by(Identity, pubkey: pubkey, user_id: user_id)
  end

  @doc """
  How many hosted agents this tenant has. `BUZZ_IDENTITY_CEILING` bounds it.

  Counts every identity, enabled or not: a disabled row is a slot the tenant
  can re-enable without asking anyone, so a ceiling that ignored them would
  bound nothing.
  """
  @spec identity_count(binary()) :: non_neg_integer()
  def identity_count(user_id) when is_binary(user_id) do
    Repo.aggregate(from(i in Identity, where: i.user_id == ^user_id), :count, :id)
  end

  @doc """
  Identity counts for every tenant with at least one, in a single query — for
  the admin view, which shows the number on every row and must not run a count
  per row (the same contract as `Fountain.Quotas.active_sandbox_counts/0`).

  Returns `%{user_id => count}`; tenants with no identities are absent.
  """
  @spec identity_counts() :: %{optional(binary()) => non_neg_integer()}
  def identity_counts do
    from(i in Identity, group_by: i.user_id, select: {i.user_id, count(i.id)})
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  Provision a Buzz identity from a caller that holds the Nostr key — the
  Fountain-side of the remote-agents provider deploy (ADR 0020 Phase 3, #738).

  Creates the identity's vault (holding `BUZZ_PRIVATE_KEY` / `BUZZ_AUTH_TAG` /
  `BUZZ_RELAY_URL`) and the `Identity` that points an agent at it. **Converges
  on the pubkey**: called again for the same pubkey it returns the existing
  identity and refreshes the vault secrets, so a provider's repeated `deploy` is
  idempotent. Deliberately not wrapped in a transaction — audits must record
  outside one (ADR 0013) — and safe to retry because convergence heals a
  partial run.

  `params` (string-keyed): `"name"`, `"relay_url"`, `"agent_id"`, `"pubkey"`,
  `"private_key_nsec"`, `"auth_tag"` (required); `"display_name"` and
  `"environment_id"` (optional). The environment, when named, must be owned by
  `user_id` — a foreign or unknown id is `{:error, :environment_not_found}` —
  and becomes the baseline every conversation this identity opens is
  provisioned from instead of the agent's own (#783). Re-provisioning without
  it clears a previously set one: the provider's `deploy` is the whole truth.

  `"respond_to"` and `"respond_to_allowlist"` (optional, #790) are the harness's
  inbound author gate — one of `owner-only` / `allowlist` / `anyone` / `nobody`
  and the 64-hex pubkeys admitted in `allowlist` mode. Omitted means
  `owner-only` with an empty list, again because the deploy is the whole truth;
  `allowlist` with no pubkeys is `{:error, %Ecto.Changeset{}}` rather than a
  harness that refuses to start.

  A *new* identity is gated twice (#1017). An enabled identity is a supervised
  `buzz-acp` OS process on Fountain's own pods for as long as it exists, so
  standing one up is spend that no sandbox meter ever reports: `check_spend/1`
  refuses it on an exhausted balance, and `BUZZ_IDENTITY_CEILING` bounds how
  many one tenant may stand up in a burst. Both are skipped when the deploy
  **converges on an identity that already exists**, which adds no standing
  process — refusing a re-deploy would strand a running harness on stale
  credentials, which is strictly worse than letting it refresh them. What
  stops the cost for an account out of credit is
  `FountainBuzz.Workers.HarnessSweep`, which suspends the harness and keeps
  the row.

  Returns `{:ok, %Identity{}}` or `{:error, reason}`.
  """
  def provision_identity(user_id, params, opts \\ []) when is_binary(user_id) do
    with {:ok, fields} <- validate_provision(params),
         :ok <- check_environment(fields.environment_id, user_id),
         :ok <- check_sandbox_mode(fields.sandbox_mode),
         :ok <- check_new_identity_allowed(user_id, fields.pubkey),
         {:ok, dek} <- Crypto.load_tenant_key(user_id),
         {:ok, vault} <- ensure_vault(user_id, fields, dek, opts),
         :ok <- write_buzz_secrets(vault, fields, dek, opts) do
      upsert_identity(user_id, vault, fields, opts)
    end
  end

  # The gate is the balance and the ceiling is the burst bound (ADR 0031,
  # #1017). Both only apply to a provision that would add a standing process:
  # `provision_identity/3` converges on the pubkey, and a converging deploy is
  # maintenance on a slot the tenant already holds.
  defp check_new_identity_allowed(user_id, pubkey) do
    if get_identity_by_pubkey(pubkey, user_id) do
      :ok
    else
      with :ok <- Fountain.Billing.check_spend(user_id) do
        check_identity_ceiling(user_id)
      end
    end
  end

  @doc """
  The per-account ceiling on hosted agents (#1017).

  Public because the admin users column highlights a count that has reached it,
  and the ceiling is this extension's policy rather than the console's.
  """
  def identity_ceiling, do: Application.get_env(:fountain_buzz, :buzz_identity_ceiling, 10)

  defp check_identity_ceiling(user_id) do
    limit = identity_ceiling()
    count = identity_count(user_id)

    if count < limit do
      :ok
    else
      {:error, {:identity_limit_reached, %{count: count, limit: limit}}}
    end
  end

  @provision_required ~w(name relay_url agent_id pubkey private_key_nsec auth_tag)

  defp validate_provision(params) do
    missing = Enum.filter(@provision_required, &blank?(Map.get(params, &1)))

    if missing == [] do
      {:ok,
       %{
         name: params["name"],
         relay_url: params["relay_url"],
         agent_id: params["agent_id"],
         pubkey: params["pubkey"],
         nsec: params["private_key_nsec"],
         auth_tag: params["auth_tag"],
         display_name: params["display_name"],
         environment_id: presence(params["environment_id"]),
         sandbox_mode: presence(params["sandbox_mode"]),
         respond_to: presence(params["respond_to"]) || "owner-only",
         respond_to_allowlist: allowlist(params["respond_to_allowlist"])
       }}
    else
      {:error, {:missing, missing}}
    end
  end

  defp blank?(v), do: is_nil(v) or v == ""

  defp presence(v), do: if(blank?(v), do: nil, else: v)

  # Normalise the allowlist the way buzz-acp does: trim, lowercase, dedupe. A
  # non-list is left as-is so the changeset reports it instead of a crash.
  defp allowlist(nil), do: []

  defp allowlist(list) when is_list(list) do
    list
    |> Enum.map(fn
      v when is_binary(v) -> v |> String.trim() |> String.downcase()
      v -> v
    end)
    |> Enum.reject(&blank?/1)
    |> Enum.uniq()
  end

  defp allowlist(other), do: other

  # Scoped fetch: the environment's secrets materialise in this identity's
  # sandboxes, so a pointer at another tenant's must never be stored.
  # Checked before the vault is created so a typo does not leave a half-
  # provisioned identity behind; nil is the agent's own default.
  defp check_sandbox_mode(nil), do: :ok

  defp check_sandbox_mode(mode) do
    if mode in Fountain.Agents.Agent.sandbox_modes(),
      do: :ok,
      else: {:error, :invalid_sandbox_mode}
  end

  defp check_environment(nil, _user_id), do: :ok

  defp check_environment(id, user_id) do
    case Environments.get_environment(id, user_id) do
      nil -> {:error, :environment_not_found}
      _env -> :ok
    end
  end

  # One vault per identity, named for it. Reused on re-provision.
  defp ensure_vault(user_id, fields, _dek, opts) do
    name = "buzz:" <> fields.name

    case Vaults.get_vault_by_name(name, user_id) do
      %Vaults.Vault{} = vault ->
        {:ok, vault}

      nil ->
        Vaults.create_vault(%{"name" => name, "user_id" => user_id}, opts)
    end
  end

  defp write_buzz_secrets(vault, fields, dek, opts) do
    secrets = [
      {"BUZZ_PRIVATE_KEY", fields.nsec},
      {"BUZZ_AUTH_TAG", fields.auth_tag},
      {"BUZZ_RELAY_URL", fields.relay_url}
    ]

    Enum.reduce_while(secrets, :ok, fn {k, v}, :ok ->
      case Vaults.upsert_secret(vault, %{"key" => k, "value" => v}, dek, opts) do
        {:ok, _} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp upsert_identity(user_id, vault, fields, opts) do
    attrs = %{
      "user_id" => user_id,
      "agent_id" => fields.agent_id,
      "vault_id" => vault.id,
      "environment_id" => fields.environment_id,
      "sandbox_mode" => fields.sandbox_mode,
      "name" => fields.name,
      "relay_url" => fields.relay_url,
      "pubkey" => fields.pubkey,
      "display_name" => fields.display_name,
      "respond_to" => fields.respond_to,
      "respond_to_allowlist" => fields.respond_to_allowlist,
      "enabled" => true
    }

    case get_identity_by_pubkey(fields.pubkey, user_id) do
      %Identity{} = existing -> update_identity(existing, attrs, opts)
      nil -> create_identity(attrs, opts)
    end
  end

  # Every identity field that ends up in the harness env or the ACP child's argv.
  @launch_fields ~w(agent_id relay_url display_name environment_id sandbox_mode respond_to respond_to_allowlist)a

  @doc """
  Whether a re-provision changed anything the running harness was launched
  with — the relay, the display name, the agent, the environment override, or
  the author gate (#790). `harness_launch/2` reads these from the identity row
  at start, so a change only takes effect on a restart; the controller uses
  this to decide whether a converging deploy must bounce the harness. Vault
  secrets are not compared: a rotated key is the owner's `!rotate` to apply.
  """
  @spec launch_config_changed?(Identity.t(), Identity.t()) :: boolean()
  def launch_config_changed?(%Identity{} = before, %Identity{} = after_) do
    Enum.any?(@launch_fields, &(Map.get(before, &1) != Map.get(after_, &1)))
  end

  @doc """
  The MCP server entries to inject into a conversation's `session/new` so the
  sandboxed agent can post to its channel (gate #737). Returns `[]` unless the
  conversation is Buzz-driven (its vault belongs to a Identity); otherwise a
  one-element list pointing the agent's MCP client at Fountain's buzz endpoint,
  authenticated with the conversation's own sprite `token`.

  Ownership: a system-level call from `ConversationServer`, which established
  ownership of the conversation at provision; the `_unsafe_` fetch is scoped
  again by the `get_identity_by_vault` that follows.
  """
  def conversation_mcp_servers(conversation_id, token)
      when is_binary(conversation_id) and is_binary(token) and token != "" do
    with %Conversations.Conversation{vault_id: vid, user_id: uid}
         when is_binary(vid) <- fetch_conv(conversation_id),
         %Identity{} <- get_identity_by_vault(vid, uid) do
      [
        %{
          name: "fountain-buzz",
          type: "http",
          url: Fountain.PublicUrl.base() <> "/api/mcp/buzz/" <> conversation_id,
          headers: [%{name: "Authorization", value: "Bearer " <> token}]
        }
      ]
    else
      _ -> []
    end
  end

  def conversation_mcp_servers(_conversation_id, _token), do: []

  # A malformed id must yield [] (no tools), not a crash — the cast raises.
  defp fetch_conv(conversation_id) do
    # ownership: system-level call from ConversationServer, which owns the
    # conversation; the identity fetched next is re-scoped by user_id, and the
    # result only ever authorises publishing under that same tenant's key.
    Conversations._unsafe_get_conversation(conversation_id)
  rescue
    Ecto.Query.CastError -> nil
  end

  @doc """
  Create a Buzz identity. `attrs` must carry `user_id`, `agent_id`, `vault_id`,
  `name` and `relay_url`. Records `buzz_identity.created`.
  """
  def create_identity(attrs, opts \\ []) do
    %Identity{}
    |> Identity.changeset(attrs)
    |> Repo.insert()
    |> audited("buzz_identity.created", opts)
  end

  @doc "Update a Buzz identity. Records `buzz_identity.updated`."
  def update_identity(%Identity{} = identity, attrs, opts \\ []) do
    identity
    |> Identity.changeset(attrs)
    |> Repo.update()
    |> audited("buzz_identity.updated", opts)
  end

  @doc """
  Change an identity's inbound author gate without a full re-provision (#790):
  `params` (string-keyed) may carry `"respond_to"` and `"respond_to_allowlist"`,
  validated and normalised exactly as `provision_identity/3` does. Nothing else
  on the identity changes. Records `buzz_identity.updated`. The caller restarts
  the harness (`FountainBuzz.Manager.restart_harness/2`) when
  `launch_config_changed?/2` says so — this function only persists.

  This changes only what the *harness accepts* — the `BUZZ_ACP_RESPOND_TO`
  gate and the kind-10100 profile buzz-acp publishes. It does not change what
  other relay users' clients believe (#820): Buzz Desktop deploys a provider
  agent with an owner-signed kind-30177 policy event, and Desktop ≥ 0.5.17
  builds its agent directory from that event and ignores the 10100 when one
  exists. So widening access here from `owner-only` to `anyone` lets the
  harness answer, but a Desktop ≥ 0.5.17 user still cannot @-mention the agent
  (no autocomplete entry, and a free-typed `@name` sends no `p` tag) until the
  owner's desktop republishes the 30177 with the same access — the desktop UI
  refuses to change access on an already-deployed provider agent, so today that
  means editing the desktop's `managed-agents.json` and restarting, or
  recreating the agent. Keep both sides in agreement.

  A later provider deploy sends the desktop's record as the whole truth and
  will overwrite what is set here.
  """
  def update_access(%Identity{} = identity, params, opts \\ []) when is_map(params) do
    attrs =
      %{}
      |> maybe_attr("respond_to", presence(params["respond_to"]))
      |> maybe_attr(
        "respond_to_allowlist",
        if(Map.has_key?(params, "respond_to_allowlist"),
          do: allowlist(params["respond_to_allowlist"]),
          else: nil
        )
      )

    if attrs == %{} do
      {:error, :nothing_to_update}
    else
      update_identity(identity, attrs, opts)
    end
  end

  defp maybe_attr(attrs, _key, nil), do: attrs
  defp maybe_attr(attrs, key, value), do: Map.put(attrs, key, value)

  @doc "Delete a Buzz identity. Records `buzz_identity.deleted`."
  def delete_identity(%Identity{} = identity, opts \\ []) do
    identity
    |> Repo.delete()
    |> audited("buzz_identity.deleted", opts)
  end

  defp audited({:ok, %Identity{} = identity} = ok, action, opts) do
    Audit.record(%{
      user_id: identity.user_id,
      action: action,
      resource_type: "buzz_identity",
      resource_id: identity.id,
      actor: Keyword.get(opts, :actor, "self"),
      request_ip: Keyword.get(opts, :request_ip),
      # Name and the *public* key identify which binding changed without
      # recording the secret — the nsec is never in this trail (ADR 0013).
      metadata: %{"name" => identity.name, "pubkey" => identity.pubkey}
    })

    ok
  end

  defp audited(other, _action, _opts), do: other

  # ── launch spec for the harness ────────────────────────────────────────────

  @typedoc """
  A `FountainBuzz.Harness` launch spec: the command, args, env, and the id of
  the API key minted for this run (so the caller/harness can revoke it on stop).

  * `:command` — path to the `buzz-acp` binary
  * `:args`    — argv (empty; `buzz-acp` is configured entirely by env)
  * `:env`     — `[{name, value}]` for the port
  * `:api_key_id` — the minted key's id, scoped to the owner, revoke on teardown
  """
  @type launch :: %{
          command: String.t(),
          args: [String.t()],
          env: [{String.t(), String.t()}],
          api_key_id: String.t()
        }

  @doc """
  Build the launch spec for a hosted `buzz-acp` bound to `identity`.

  Mints a `["sprite"]`-scoped API key for the owning user (the resource surface a
  sandbox-adjacent process needs, without key management), decrypts the vault's
  `BUZZ_PRIVATE_KEY` / `BUZZ_AUTH_TAG` / `BUZZ_RELAY_URL` server-side, and lays
  out the environment: the Buzz identity vars, the inbound author gate
  (`BUZZ_ACP_RESPOND_TO` and, in allowlist mode, `BUZZ_ACP_RESPOND_TO_ALLOWLIST`,
  #790), the `BUZZ_ACP_*` wiring that points the harness's ACP child at
  `fountain acp --agent … --vault … [--environment …]`, and the
  `FOUNTAIN_*` vars that let that child authenticate back to this instance.

  Options:
  * `:buzz_acp_path` — path to the binary (defaults to app env `:buzz_acp_path`)
  * `:base_url`      — this instance's base URL for the ACP child
                       (defaults to app env `:buzz_acp_base_url`)
  * `:fountain_bin`  — path to the `fountain` CLI in the harness image
                       (defaults to app env `:fountain_cli_path`, else `"fountain"`)
  * `:agents`        — `BUZZ_ACP_AGENTS` pool size (default 1; the desktop's 10 is
                       a desktop assumption)
  * `:actor` / `:request_ip` — attribution for the minted key's audit row

  Returns `{:ok, launch}` or `{:error, reason}`. The agent and vault referenced
  by the identity must exist; a caller that has already established ownership of
  the identity may call this — the mint is scoped to `identity.user_id`.
  """
  @spec harness_launch(Identity.t(), keyword()) :: {:ok, launch()} | {:error, term()}
  def harness_launch(%Identity{} = identity, opts \\ []) do
    command = opts[:buzz_acp_path] || FountainBuzz.Assets.acp_path()
    base_url = opts[:base_url] || Application.get_env(:fountain_buzz, :buzz_acp_base_url)

    fountain_bin =
      opts[:fountain_bin] || Application.get_env(:fountain_buzz, :fountain_cli_path) || "fountain"

    agents = opts[:agents] || 1

    cond do
      is_nil(command) ->
        {:error, :no_buzz_acp_path}

      is_nil(base_url) ->
        {:error, :no_base_url}

      true ->
        with {:ok, dek} <- Crypto.load_tenant_key(identity.user_id),
             {:ok, vault} <- fetch_vault(identity),
             {:ok, {key, raw}} <- mint_key(identity, opts) do
          vault_env = Vaults.decrypted_env(vault, dek)

          env =
            vault_env
            |> buzz_identity_env(identity)
            |> Map.merge(acp_wiring_env(identity, fountain_bin, agents))
            |> Map.merge(fountain_child_env(raw, base_url))
            |> Enum.map(fn {k, v} -> {to_string(k), to_string(v)} end)

          {:ok, %{command: command, args: [], env: env, api_key_id: key.id}}
        end
    end
  end

  @doc """
  Revoke the API key a launch minted. Called when a harness stops so a
  one-conversation credential does not become standing access. Scoped to the
  identity's owner. Returns `{:ok, key}` or `{:error, :not_found}`.
  """
  def revoke_launch_key(%Identity{} = identity, api_key_id, opts \\ []) do
    Accounts.revoke_api_key(identity.user_id, api_key_id, opts)
  end

  defp fetch_vault(%Identity{vault_id: vault_id, user_id: user_id}) do
    # Ownership: the identity is tenant-owned and its vault_id is a same-tenant
    # FK, so a scoped fetch confirms it rather than trusting the pointer.
    case Vaults.get_vault(vault_id, user_id) do
      nil -> {:error, :vault_not_found}
      vault -> {:ok, vault}
    end
  end

  defp mint_key(%Identity{} = identity, opts) do
    name = "buzz-acp:#{identity.name}"

    Accounts.create_api_key(identity.user_id, name,
      scopes: ["sprite"],
      actor: Keyword.get(opts, :actor, "system:buzz_harness"),
      request_ip: Keyword.get(opts, :request_ip)
    )
  end

  # The vault provides BUZZ_PRIVATE_KEY / BUZZ_AUTH_TAG (and may provide
  # BUZZ_RELAY_URL); the identity row is authoritative for the relay, so it wins.
  # The author gate is the identity's too: without BUZZ_ACP_RESPOND_TO the
  # harness defaults to owner-only whatever the desktop's record says (#790).
  defp buzz_identity_env(vault_env, %Identity{} = identity) do
    vault_env
    |> Map.put("BUZZ_RELAY_URL", identity.relay_url)
    |> maybe_put("BUZZ_ACP_DISPLAY_NAME", identity.display_name)
    |> Map.put("BUZZ_ACP_RESPOND_TO", identity.respond_to || "owner-only")
    |> maybe_put_allowlist(identity)
  end

  # buzz-acp warns and ignores the allowlist var outside allowlist mode; only
  # set it where it means something.
  defp maybe_put_allowlist(env, %Identity{respond_to: "allowlist", respond_to_allowlist: list})
       when is_list(list) and list != [] do
    Map.put(env, "BUZZ_ACP_RESPOND_TO_ALLOWLIST", Enum.join(list, ","))
  end

  defp maybe_put_allowlist(env, _identity), do: env

  # Point the harness's ACP child at this Fountain agent + vault (+ environment
  # override, #783; + sandbox mode, ADR 0023), and keep the pool to one (the
  # desktop's 10 is not our assumption).
  defp acp_wiring_env(%Identity{} = identity, fountain_bin, agents) do
    args =
      ["acp", "--agent", identity.agent_id, "--vault", identity.vault_id]
      |> Kernel.++(
        if identity.environment_id, do: ["--environment", identity.environment_id], else: []
      )
      |> Kernel.++(
        if identity.sandbox_mode, do: ["--sandbox-mode", identity.sandbox_mode], else: []
      )
      |> Enum.join(",")

    %{
      "BUZZ_ACP_AGENT_COMMAND" => fountain_bin,
      "BUZZ_ACP_AGENT_ARGS" => args,
      "BUZZ_ACP_AGENTS" => Integer.to_string(agents),
      # Steer the model to the Fountain-hosted buzz_* MCP tools (which sign
      # server-side) instead of a `buzz` CLI it has no key for (#737).
      "BUZZ_ACP_BASE_PROMPT_FILE" => base_prompt_file(),
      # Mirror every ACP frame as NIP-44 kind-24200 telemetry encrypted to the
      # owner, so the Buzz desktop's "ACP activity" panel shows the agent's work.
      # The desktop sets this when it spawns buzz-acp itself; a gateway-hosted
      # harness must too, or the panel stays empty.
      "BUZZ_ACP_RELAY_OBSERVER" => "true"
    }
  end

  # The ACP child authenticates back to this instance with the minted key.
  defp fountain_child_env(raw_key, base_url) do
    %{"FOUNTAIN_API_KEY" => raw_key, "FOUNTAIN_BASE_URL" => base_url}
  end

  defp base_prompt_file do
    Application.get_env(:fountain_buzz, :buzz_base_prompt_file) ||
      Application.app_dir(:fountain_buzz, "priv/buzz-base-prompt.md")
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
