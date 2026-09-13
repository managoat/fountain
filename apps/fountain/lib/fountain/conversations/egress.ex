defmodule Fountain.Conversations.Egress do
  @moduledoc """
  Everything ADR 0019 wired into a conversation: which secrets are brokered,
  the connections that contribute tokens, the proxy session's life, and the
  network floor.

  Talks to `Fountain.Broker` (the facade over its backends since #1357,
  never a backend) and `Fountain.Connections`. Functions over rows and
  values, not over server state (#1369): `ConversationServer` keeps the
  fields the session, its placeholders and its bindings live in, unpacks
  them for each call and applies what comes back. Two places that change
  more than one field at once (mint, the OAuth switch) are the server's
  short wrappers over `prepare/4` and `drop_oauth_token/3`. The third, the
  refresh before a turn, reads seven fields and writes four since #1736, so
  `refresh_before_turn/1` takes the state and names them.

  The split rules, in order, as the server applies them at provision:
  `bindings/1`, `add_connection_secrets/4`, `split_brokered/2`,
  `split_inference/3`. Each is a no-op where no broker is configured.
  """

  alias Fountain.Broker
  alias Fountain.Conversations.Provisioning
  alias Fountain.Conversations.SpriteEnv
  alias Fountain.Environments
  alias Fountain.Vaults

  require Logger

  @typedoc "A proxy session as `Fountain.Broker.prepare/4` returns it, or nil when the conversation has none."
  @type session :: map() | nil

  @doc """
  Whether conversations here are brokered: `Fountain.Broker.configured?/0`.

  It took a `user_id` while ADR 0019 §9's ratchet made brokerage per-tenant.
  That retired on the 2026-09-04 flip to `*`, so the answer is the
  deployment's and the argument would only suggest otherwise.
  """
  @spec brokered?() :: boolean()
  def brokered?, do: Broker.configured?()

  # On a brokered conversation the catalog keys leave the secrets map here,
  # before the MCP substitution and the env are built from it, so both see
  # the placeholder and neither sees the value.
  @spec split_brokered(map(), Broker.bindings()) :: {map(), map()}
  def split_brokered(secrets, bindings) do
    if Broker.configured?(),
      do: Broker.split(secrets, bindings),
      else: {secrets, %{}}
  end

  # A tenant's connections (#1178) contribute their access tokens as
  # synthetic secrets, brokered like inference keys: the sandbox gets a
  # placeholder, the broker gets the value with an implicit bearer binding
  # to the provider's hosts. A tenant's own secret of the same name wins,
  # as does their own binding on it (which is how the token reaches an MCP
  # server they run). Only for brokered tenants — without the broker the
  # token would have to enter the sandbox in the clear, which is the thing
  # connections exist to avoid.
  @spec add_connection_secrets(String.t(), map(), Broker.bindings(), map() | nil) ::
          {map(), Broker.bindings(), [String.t()]}
  def add_connection_secrets(user_id, merged, bindings, agent) do
    if Broker.configured?() do
      connections = active_connections_by_id(user_id)
      synthetic = Fountain.Connections.synthetic_secrets(user_id)
      remote_hosts = remote_connection_hosts(agent, connections)

      {merged, bindings, keys} =
        Enum.reduce(synthetic, {merged, bindings, []}, fn {key, token}, {m, b, keys} ->
          if Map.has_key?(m, key) do
            {m, b, keys}
          else
            b =
              if Map.has_key?(b, key),
                do: b,
                else: Map.put(b, key, connection_bindings(user_id, key, remote_hosts))

            {Map.put(m, key, token), b, [key | keys]}
          end
        end)

      {merged, bindings, Enum.sort(keys)}
    else
      {merged, bindings, []}
    end
  end

  # The provider's own hosts, plus the host of every remote MCP server the
  # agent attaches with this connection (#1186): the broker attaches the
  # bearer to exactly those and nothing else.
  @spec connection_bindings(String.t(), String.t(), %{String.t() => [String.t()]}) ::
          [Fountain.SecretBindings.Binding.t()]
  def connection_bindings(user_id, key, remote_hosts) do
    (Fountain.Connections.implicit_hosts(user_id, key) ++ Map.get(remote_hosts, key, []))
    |> Enum.uniq()
    |> Enum.map(fn host ->
      %Fountain.SecretBindings.Binding{
        key: key,
        host: host,
        auth_type: "bearer",
        headers: %{},
        enabled: true
      }
    end)
  end

  defp active_connections_by_id(user_id) do
    user_id
    |> Fountain.Connections.active_connections()
    |> Map.new(&{&1.id, &1})
  end

  defp remote_connection_hosts(%{mcp_servers: servers}, connections) when is_map(servers),
    do: Fountain.Connections.McpServers.remote_hosts(servers, connections)

  defp remote_connection_hosts(_agent, _connections), do: %{}

  @doc """
  Re-read the deployment's ChatGPT access token for a conversation that runs
  on it (ADR 0047 decision 5). Only when the credentials carry the grant and
  the broker still holds that same value — a tenant's own secret of the
  name, or a grant already dropped, is left alone. A rotated token replaces
  both copies and the caller rewrites the live session's rules; a refresh
  that fails, or a grant gone revoked, leaves the old token in place to
  fail at the proxy with the provider's reason rather than silently here.
  """
  @spec refresh_platform_chatgpt(map(), map()) :: {map(), map(), boolean()}
  def refresh_platform_chatgpt(inference_credentials, brokered) do
    key = Fountain.Conversations.CodexChatGPT.env_key()
    credential = Fountain.Conversations.CodexChatGPT.credential()
    old = Map.get(inference_credentials, credential)

    with true <- is_binary(old) and old != "",
         true <- Map.get(brokered, key) == old,
         {:ok, fresh} when fresh != old <- Fountain.PlatformChatGPT.access_token() do
      {Map.put(inference_credentials, credential, fresh), Map.put(brokered, key, fresh), true}
    else
      _ -> {inference_credentials, brokered, false}
    end
  end

  # Re-read the brokered connection tokens; a rotated one is swapped into
  # `brokered` and the caller re-prepares the vault. A refresh that fails
  # leaves the old token in place: the turn runs on it and, if it has
  # expired, fails at the provider with a reason rather than silently here.
  @spec refresh_connection_secrets([String.t()], String.t(), map()) :: {map(), boolean()}
  def refresh_connection_secrets([], _user_id, brokered), do: {brokered, false}

  def refresh_connection_secrets(keys, user_id, brokered) do
    fresh = user_id |> Fountain.Connections.synthetic_secrets() |> Map.take(keys)

    rotated =
      Enum.filter(fresh, fn {k, v} -> Map.get(brokered, k) != v end)

    if rotated == [] do
      {brokered, false}
    else
      {Map.merge(brokered, Map.new(rotated)), true}
    end
  end

  # Re-read the tenant's own brokered secrets before a turn (#1736), the
  # way `refresh_connection_secrets/3` re-reads the connection tokens.
  # `merged` is the environment + vault merge as `SpriteEnv.merge_secrets/3`
  # returns it now, `tenant_keys` the keys the previous read brokered. An
  # edited value replaces the broker's; a deleted key is dropped, and what
  # it was masking takes the name back, as at provisioning: `underlay` is
  # the map of those values, the runtime's inference credentials and the
  # connection tokens under their env var names. Returns the brokered map,
  # the tenant's brokered keys now, and whether anything moved. Runs after
  # the connection refresh so a tenant's own secret of a connection's name
  # wins, as it does at init.
  @spec refresh_tenant_secrets([String.t()], map(), map(), Broker.bindings(), map()) ::
          {map(), [String.t()], boolean()}
  def refresh_tenant_secrets(tenant_keys, merged, brokered, bindings, underlay) do
    {_sandbox, fresh} = Broker.split(merged, bindings)
    fresh_keys = fresh |> Map.keys() |> Enum.sort()
    removed = tenant_keys -- fresh_keys

    next =
      brokered
      |> Map.drop(removed)
      |> Map.merge(Map.take(underlay, removed))
      |> Map.merge(fresh)

    {next, fresh_keys, next != brokered}
  end

  # An agent whose `mcp_servers` names a connection gets the entry rewritten
  # into the Fountain-served server (#1178), authenticated by the
  # conversation's callback token. Not for an unbrokered tenant: the entry
  # is dropped and the agent runs without it.
  @spec with_connection_servers(map() | nil, String.t(), String.t(), String.t() | nil) ::
          map() | nil
  def with_connection_servers(agent, user_id, conversation_id, callback_token)

  def with_connection_servers(nil, _user_id, _conversation_id, _callback_token), do: nil

  def with_connection_servers(%{mcp_servers: servers} = agent, user_id, conversation_id, token)
      when is_map(servers) do
    brokered = Broker.configured?()
    token = if brokered, do: token
    connections = if brokered, do: active_connections_by_id(user_id), else: %{}

    %{
      agent
      | mcp_servers:
          Fountain.Connections.McpServers.resolve(
            servers,
            conversation_id,
            token,
            connections
          )
    }
  end

  def with_connection_servers(agent, _user_id, _conversation_id, _callback_token), do: agent

  # Only read for a brokered tenant: for everyone else the table is rows
  # nobody consults, and this path stays free of a query.
  @spec bindings(String.t()) :: Broker.bindings()
  def bindings(user_id) do
    if Broker.configured?(),
      do: Fountain.SecretBindings.enabled_by_key(user_id),
      else: %{}
  end

  # Gate 3: the runtime is handed placeholders for its inference credentials
  # and the broker gets the values, with an implicit binding to the provider's
  # host. A tenant's own secret of the same name (already split above) wins
  # over the inference credential, as it wins in the environment.
  @spec split_inference(map(), map(), Broker.bindings()) ::
          {map(), map(), Broker.bindings()}
  def split_inference(inference_creds, brokered, bindings) do
    if Broker.configured?() do
      {env_creds, inference_brokered, implicit} =
        Broker.split_inference(inference_creds, bindings)

      {env_creds, Map.merge(inference_brokered, brokered), Map.merge(implicit, bindings)}
    else
      {inference_creds, brokered, bindings}
    end
  end

  @doc "The proxy variables a session puts in the sandbox's env; none without a session."
  @spec sandbox_env(session()) :: [{String.t(), String.t()}]
  def sandbox_env(nil), do: []
  def sandbox_env(session), do: Broker.sandbox_env(session)

  @doc """
  Mint the conversation's proxy session and start the `broker` stage.
  The stage completes only after `install_ca/3` establishes trust in the
  sandbox. The caller decides whether the conversation is brokered at all
  (`brokered?/1`) and holds the session that comes back.
  """
  @spec prepare(String.t(), map(), Broker.bindings(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def prepare(conversation_id, brokered, bindings, opts) do
    publish_stage(conversation_id, "broker", "started", %{
      keys: brokered |> Map.keys() |> Enum.sort()
    })

    case Broker.prepare(conversation_id, brokered, bindings, opts) do
      {:ok, session} ->
        {:ok, session}

      {:error, reason} ->
        publish_stage(conversation_id, "broker", "failed", %{reason: inspect(reason)})
        {:error, reason}
    end
  end

  @doc """
  The OAuth token was refused: forget it on both sides, so the API key is
  what the substitution carries. Returns the runtime's credentials, the
  brokered map and the bindings without it; the caller then `reprepare/5`s.
  """
  @spec drop_oauth_token(map(), map(), Broker.bindings()) :: {map(), map(), Broker.bindings()}
  def drop_oauth_token(inference_credentials, brokered, bindings) do
    creds = Map.delete(inference_credentials, :claude_code_oauth_token)

    {env_creds, inference_brokered, implicit} =
      Broker.split_inference(creds, bindings)

    brokered =
      brokered
      |> Map.delete("CLAUDE_CODE_OAUTH_TOKEN")
      |> Map.merge(inference_brokered)

    bindings =
      bindings |> Map.delete("CLAUDE_CODE_OAUTH_TOKEN") |> Map.merge(implicit)

    {env_creds, brokered, bindings}
  end

  @doc """
  Replace the session and rebuild the env with the new token; everything
  else in the env is unchanged. No stage is published: this is the refresh
  before a turn and the re-prepare after an OAuth refusal, not provisioning.

  Only the proxy variables are replaced. The CA defaults are constants, they
  are already in the list `SpriteEnv.build/4` produced, and stripping them by
  key would take an `env_vars` override of `SSL_CERT_FILE` with them —
  re-adding the broker's value on top, which is the bug #1674 reported, an
  hour into the conversation rather than at provisioning.

  There is no arm here for a list that carries no CA defaults:
  `prepare_state/1` runs before `build_sprite_env/5` on both entry paths
  (`ConversationServer` lines 863 and 1114), so a brokered conversation's env
  has always been assembled with them.
  """
  @spec reprepare(String.t(), map(), Broker.bindings(), [{String.t(), String.t()}], keyword()) ::
          {:ok, map(), [{String.t(), String.t()}]} | {:error, term()}
  def reprepare(conversation_id, brokered, bindings, sprite_env, opts) do
    case Broker.prepare(conversation_id, brokered, bindings, opts) do
      {:ok, session} ->
        proxy_keys = Broker.proxy_keys()
        kept = Enum.reject(sprite_env, fn {k, _} -> to_string(k) in proxy_keys end)
        {:ok, session, kept ++ Broker.proxy_env(session)}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Rewrite the rules of the conversation's live sessions in place
  (`Fountain.Broker.refresh/4`), keeping the token the sandbox and the idle
  ACP peer already hold (#1736). The refresh before a turn calls this when
  a secret has moved; `reprepare/5` is for a session that is expiring, and
  the new token it mints reaches only the next spawn. `{:ok, 0}` (no live
  session to rewrite) is an error to the caller: the rules went nowhere,
  and a fresh session is the way to carry them.
  """
  @spec refresh_rules(String.t(), map(), Broker.bindings(), keyword()) :: :ok | {:error, term()}
  def refresh_rules(conversation_id, brokered, bindings, opts) do
    case Broker.refresh(conversation_id, brokered, bindings, opts) do
      {:ok, n} when n > 0 -> :ok
      {:ok, 0} -> {:error, :no_live_session}
      {:error, _} = error -> error
    end
  end

  @doc """
  The refresh before a turn, over the server's state (#1736): the secrets
  the broker holds are read again, a change is written into the live
  session's rules with the token kept, and a session near its end is
  replaced before the turn that would outlive it, the env rebuilt with the
  new token for the next spawn. Reads `broker`, `brokered`, `tenant_keys`,
  `connection_keys`, `secret_sources`, `broker_bindings` and
  `inference_credentials` (plus the ids and the DEK); writes `brokered`,
  `tenant_keys`, `broker` and `sprite_env`. Returns the state and whether
  the session token was replaced. The state of an unbrokered conversation
  comes back unchanged.

  The token is in the env of every process the sandbox already runs — the
  idle ACP peer that carries the next turn included — so a new session
  would reach none of them; only the rules can move. A rewrite that fails
  falls through to a fresh session, and the caller closes the idle peer on
  the `true` that comes back, so the next spawn carries the new token. A
  re-mint that fails leaves the turn on the old token, to fail at the
  proxy, which names the cause, rather than silently here.
  """
  @spec refresh_before_turn(map()) :: {map(), boolean()}
  def refresh_before_turn(%{broker: nil} = state), do: {state, false}

  def refresh_before_turn(%{broker: session} = state) do
    {state, changed?} = reread_secrets(state)
    rewritten? = changed? and rewrite_rules(state) == :ok

    if (changed? and not rewritten?) or Broker.expiring?(session) do
      case reprepare(
             state.conversation_id,
             state.brokered,
             state.broker_bindings,
             state.sprite_env,
             network: state.broker_network,
             user_id: state.user_id
           ) do
        {:ok, fresh, sprite_env} ->
          {%{state | broker: fresh, sprite_env: sprite_env}, fresh.token != session.token}

        {:error, reason} ->
          Logger.warning(
            "conv #{state.conversation_id}: broker session refresh failed: #{inspect(reason)}"
          )

          {state, false}
      end
    else
      {state, false}
    end
  end

  # The connection tokens first, then the tenant's own secrets, in the order
  # init merged them: a tenant's secret of a connection's name wins. Two
  # decrypts of two rows per turn; a turn is a sandbox spawn or an ACP
  # prompt, so the read is not what a turn waits on.
  defp reread_secrets(state) do
    # The deployment's ChatGPT grant first (ADR 0047 decision 5): it rotates
    # on the server's own schedule, and the conversation's copy of the
    # credential is what the underlay below is built from.
    {inference_credentials, brokered, grant_rotated?} =
      refresh_platform_chatgpt(state.inference_credentials, state.brokered)

    state = %{state | inference_credentials: inference_credentials}

    {brokered, rotated?} =
      refresh_connection_secrets(state.connection_keys, state.user_id, brokered)

    rotated? = rotated? or grant_rotated?

    # What a deleted tenant secret hands its name back to: the inference
    # credential of that name, or the connection token it had overridden
    # (the connection refresh above has just put the current one in place).
    {_creds, inference, _implicit} =
      Broker.split_inference(state.inference_credentials, state.broker_bindings)

    underlay = Map.merge(inference, Map.take(brokered, state.connection_keys))

    {brokered, tenant_keys, edited?} =
      refresh_tenant_secrets(
        state.tenant_keys,
        tenant_secrets(state),
        brokered,
        state.broker_bindings,
        underlay
      )

    {%{state | brokered: brokered, tenant_keys: tenant_keys}, rotated? or edited?}
  end

  # The environment + vault merge as it stands now. Both fetches are
  # tenant-scoped on the user the server established at init; a row that is
  # gone contributes nothing, so its secrets leave the broker too.
  defp tenant_secrets(%{secret_sources: nil}), do: %{}

  defp tenant_secrets(%{secret_sources: sources} = state) do
    env =
      sources.environment_id &&
        Environments.get_environment(sources.environment_id, state.user_id)

    vault = sources.vault_id && Vaults.get_vault(sources.vault_id, state.user_id)
    SpriteEnv.merge_secrets(env, vault, state.tenant_key)
  end

  defp rewrite_rules(state) do
    case refresh_rules(state.conversation_id, state.brokered, state.broker_bindings,
           network: state.broker_network,
           user_id: state.user_id
         ) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "conv #{state.conversation_id}: broker rules rewrite failed: #{inspect(reason)}"
        )

        :error
    end
  end

  @doc "Keep the minted proxy session in server state; unbrokered state is unchanged."
  def prepare_state(state) do
    if brokered?() do
      case prepare(state.conversation_id, state.brokered, state.broker_bindings,
             network: state.broker_network,
             user_id: state.user_id
           ) do
        {:ok, session} -> {:ok, %{state | broker: session}}
        {:error, _} = error -> error
      end
    else
      {:ok, state}
    end
  end

  @doc "Revoke only the session this preparation returned; a failed mint owns no token."
  def release_prepared({:ok, %{broker: %{token: token}} = state}),
    do: Broker.release_session(state.user_id, state.conversation_id, token)

  def release_prepared(_result), do: :ok

  @doc "Install the broker's CA into the sandbox; nothing to install without a session."
  @spec install_ca(session(), Managoat.Sandbox.Handle.t(), String.t()) :: :ok | {:error, term()}
  def install_ca(nil, _handle, _conversation_id), do: :ok

  def install_ca(session, handle, conversation_id) do
    result = Provisioning.install_broker_ca(handle, conversation_id)

    # Only a conversation's trust setup reaches this path. Broker health
    # probes and session refreshes do not contribute to the failure ratio.
    Fountain.Telemetry.event(
      [:broker, :ca_install],
      %{provider: handle.provider, outcome: ca_install_outcome(result)},
      %{count: 1}
    )

    with :ok <- result do
      publish_stage(conversation_id, "broker", "done", %{
        vault: session.vault,
        expires_at: session.expires_at
      })

      :ok
    end
  end

  defp ca_install_outcome(:ok), do: "ok"
  defp ca_install_outcome({:error, {:broker, :ca_install_exit, _, _}}), do: "exit"
  defp ca_install_outcome({:error, {:broker, :ca_install, _}}), do: "unreachable"
  defp ca_install_outcome({:error, _}), do: "unavailable"

  # Every session of the conversation goes when its sandbox does. Still off
  # the caller's path: deleting rows is local and cannot fail the way a call
  # to a vendor proxy could, but teardown is not a place to start waiting on
  # the database either, and a broker session that outlives its sandbox is
  # swept by `Fountain.Workers.BrokerReaper` regardless.
  @spec release(String.t()) :: :ok
  def release(conversation_id) do
    if Broker.configured?() do
      conv_id = conversation_id
      Task.Supervisor.start_child(Fountain.TaskSupervisor, fn -> Broker.release(conv_id) end)
    end

    :ok
  end

  @doc "The network floor: the environment's policy, or the broker's when brokered."
  @spec apply_policy(Managoat.Sandbox.Handle.t(), map() | nil, String.t(), boolean()) ::
          :ok | {:error, term()}
  def apply_policy(handle, env, conv_id, false),
    do: Provisioning.apply_network_policy(handle, env, conv_id)

  def apply_policy(handle, _env, conv_id, true),
    do: Provisioning.apply_broker_floor(handle, conv_id)

  @doc """
  Reapply policy before an existing machine receives credentials or resumes.

  A machine may predate its tenant's broker enrollment. Policy failures are
  retryable and never establish that its disk is gone. Removing brokering
  restores a limited environment; unrestricted remains a no-op because the
  sandbox abstraction has no policy-reset operation.
  """
  @spec reattach_policy(Managoat.Sandbox.Handle.t(), map() | nil, String.t()) ::
          :ok | {:error, term()}
  def reattach_policy(handle, env, conv_id) do
    brokered? = brokered?()

    with :ok <- Provisioning.check_broker_support(brokered?, handle.provider, env, conv_id) do
      apply_policy(handle, env, conv_id, brokered?)
    end
  end

  defp publish_stage(conv_id, stage, status, meta) do
    Fountain.Conversations.publish_stage(conv_id, stage, status, meta)
  end
end
