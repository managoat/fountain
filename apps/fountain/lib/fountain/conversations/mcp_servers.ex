defmodule Fountain.Conversations.McpServers do
  @moduledoc """
  The MCP server list a runtime receives at `session/new`.

  Two halves. The agent-declared servers, with their `${VAR}` references
  resolved against the environment and the secrets (`substitute_agent/3`),
  and the ones Fountain serves back to the sandbox itself, authenticated with
  the conversation's callback token (`Fountain.Conversations.CallbackKey`):
  installed extensions' tools, the team tools and
  the caller-tool bridge. Each of those decides for itself whether this
  conversation gets it; `fountain_served/2` only asks, in the order the
  server has always appended them.

  Functions over rows and values, not over server state: `ConversationServer`
  unpacks what it holds and passes it in (#1369). Nothing here touches the
  database directly; the Fountain-served lists read the conversation row
  through the context that owns each tool set.
  """

  alias Fountain.Agents.Agent
  alias Fountain.Environments.Environment
  alias Managoat.Substitution

  # Resolve `${VAR}` references in the agent's MCP server config against
  # env_vars + env_secrets + vault_secrets (vault wins). Env vars values
  # are coerced to strings; non-string values further down the tree pass
  # through untouched.
  @spec substitute_agent(Agent.t() | nil, Environment.t() | nil, map()) ::
          {:ok, Agent.t() | nil} | {:error, term()}
  def substitute_agent(nil, _env, _secrets), do: {:ok, nil}

  def substitute_agent(agent, env, secrets) do
    vars = substitution_vars(env, secrets)

    case Substitution.apply(agent.mcp_servers || %{}, vars) do
      {:ok, mcp} -> {:ok, %{agent | mcp_servers: mcp}}
      {:error, _} = err -> err
    end
  end

  @doc """
  The whole `session/new` MCP list for a turn: the agent's own servers, with
  `${VAR}` already resolved and the tenant's brokered connections folded in,
  followed by the ones Fountain serves back to the sandbox.

  `opts` is what `ConversationServer` unpacks from its state — `:user_id`,
  `:conversation_id`, `:callback_token` and `:resolved`, the conversation's
  resolved MCP configuration (see `resolve_for_session/2`).
  """
  @spec for_session(Agent.t() | nil, map(), keyword()) :: [map()]
  def for_session(agent, conv, opts) do
    token = Keyword.get(opts, :callback_token)

    agent
    |> resolve_for_session(Keyword.get(opts, :resolved))
    |> Fountain.Conversations.Egress.with_connection_servers(
      Keyword.fetch!(opts, :user_id),
      Keyword.fetch!(opts, :conversation_id),
      token
    )
    |> Managoat.Runtimes.ACP.mcp_servers()
    |> Kernel.++(fountain_served(conv, token))
  end

  @doc """
  Put the conversation's already-resolved MCP configuration back onto a
  freshly-fetched agent, for the turn that is about to open a session.

  The turn path re-reads the agent row on every prompt, which is right — an
  edit between turns should take effect — but that row holds the *stored*
  document, with its `${VAR}` references and `$$` escapes unresolved. Sending
  that to ACP `session/new` was #1404: the session copy wins in Claude Code,
  so a header written `Bearer $${FOUNTAIN_TOKEN}` reached the server as
  `Bearer $ftn_…`, the runtime having expanded the inner reference and left
  the escape behind. The sandbox's own `.mcp.json` never had the bug, because
  that copy is written from the substituted document — which is exactly the
  point: there must be **one** substitution pass and one effective config,
  not a resolved copy on disk and a raw one on the wire.

  `resolved` is `nil` for an agentless conversation, and for one whose server
  has not provisioned yet; the agent is returned untouched in both cases
  rather than having its configuration blanked.

  Resolution happens once per provision (`substitute_agent/3`), so a reattach
  or a wake re-resolves against the environment and secrets as they are then.
  Values Fountain does not own are deliberately still the runtime's to expand:
  `${FOUNTAIN_TOKEN}` and `${FOUNTAIN_CONVERSATION_ID}` are process
  environment inside the sandbox, never entries in `vars`, so a resumed turn
  reads the current callback credential rather than one frozen into a
  document.
  """
  @spec resolve_for_session(Agent.t() | nil, map() | nil) :: Agent.t() | nil
  def resolve_for_session(nil, _resolved), do: nil
  def resolve_for_session(agent, nil), do: agent
  def resolve_for_session(agent, resolved), do: %{agent | mcp_servers: resolved}

  @doc """
  The variables `${VAR}` resolves against: the environment's `env_vars` with
  keys and values as strings, overridden by the decrypted `secrets`.
  """
  @spec substitution_vars(Environment.t() | nil, map()) :: map()
  def substitution_vars(env, secrets) do
    env_vars =
      if env,
        do: Map.new(env.env_vars || %{}, fn {k, v} -> {to_string(k), to_string(v)} end),
        else: %{}

    Map.merge(env_vars, secrets)
  end

  @doc """
  The Fountain-served servers for a turn, in the order the server has always
  appended them after the agent's own: extensions, team, caller.

  Installed extensions come first (ADR 0043, #1505), in configured order, ahead
  of everything the host serves itself. That ordering is a host decision, not a
  promise to an extension — ADR 0043 fixes "extensions before team" and nothing
  finer. Buzz's reply tools reach a turn through that fan-out since #1507; the
  `buzz/2` clause that used to sit here went with them.
  """
  @spec fountain_served(map(), String.t() | nil) :: [map()]
  def fountain_served(%{id: conv_id} = conv, token) do
    extensions(conv_id, token) ++
      team(conv_id, token) ++
      caller(conv, token)
  end

  # Every installed extension's contribution. `Fountain.Extensions` contains a
  # failure to the extension that caused it: a raise here costs that
  # extension's servers and leaves the rest of this list intact, because the
  # alternative is one broken optional integration ending an unrelated turn.
  @spec extensions(String.t() | nil, String.t() | nil) :: [map()]
  defp extensions(conv_id, token),
    do: Fountain.Extensions.conversation_mcp_servers(conv_id, token)

  # The team tools (#851), for conversations on the team channel.
  @spec team(String.t() | nil, String.t() | nil) :: [map()]
  def team(conv_id, token) when is_binary(token) and is_binary(conv_id),
    do: Fountain.Team.conversation_mcp_servers(conv_id, token)

  def team(_conv_id, _token), do: []

  # The caller-tool bridge (#1202): the tools a chat-completions or AG-UI
  # client defined, served back to the sandbox as one more MCP server. Read
  # off the conversation row at every turn kick, so a list registered by the
  # request that opened this turn is on it.
  @spec caller(map(), String.t() | nil) :: [map()]
  def caller(conv, token) when is_binary(token),
    do: Fountain.CallerTools.conversation_mcp_servers(conv, token)

  def caller(_conv, _token), do: []
end
