defmodule Fountain.Conversations.McpServers do
  @moduledoc """
  The MCP server list a runtime receives at `session/new`: the agent-declared
  servers, with their `${VAR}` references resolved against the environment
  and the secrets (`substitute_agent/3`).

  Fountain serves no MCP server of its own back to the sandbox. The last one,
  the team tools (#851), went with the team (ADR 0074).

  Functions over rows and values, not over server state: `ConversationServer`
  unpacks what it holds and passes it in (#1369). Nothing here touches the
  database.
  """

  alias Fountain.Agents.Agent
  alias Fountain.Environments.Environment
  alias Fountain.Substitution

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
  `${VAR}` already resolved.

  `opts` is what `ConversationServer` unpacks from its state; this reads
  `:resolved`, the conversation's resolved MCP configuration (see
  `resolve_for_session/2`).
  """
  @spec for_session(Agent.t() | nil, keyword()) :: [map()]
  def for_session(agent, opts) do
    agent
    |> resolve_for_session(Keyword.get(opts, :resolved))
    |> Managoat.Runtimes.ACP.mcp_servers()
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
end
