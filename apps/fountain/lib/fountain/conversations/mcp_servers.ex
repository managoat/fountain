defmodule Fountain.Conversations.McpServers do
  @moduledoc """
  The MCP server list a runtime receives at `session/new`: the agent-declared
  servers, with their `${VAR}` references resolved against the environment
  and the secrets (`substitute_agent/3`).

  Fountain serves no MCP server of its own back to the sandbox.

  ## `"auth": "conversation"` (ADR 0086)

  An `http` or `sse` entry may ask to be authenticated as the conversation:

      {"salon": {"type": "http", "url": "https://salon.example/mcp", "auth": "conversation"}}

  `for_session/2` gives that entry two headers in the list it builds, and
  nowhere else:

      Authorization: Bearer <the conversation's callback key>
      X-Managoat-Conversation-Id: <the conversation id>

  The key is the plaintext `ConversationServer` holds as `callback_token`,
  the same `sprite`-scoped key the sandbox has as `MANAGOAT_TOKEN`. Every
  ACP runtime receives plain headers, so nothing depends on a runtime
  expanding `${VAR}`. The value is put in at the last moment so that it
  never reaches the stored agent, the resolved document the server keeps
  (`resolved_mcp_servers`), the project files written into the sandbox
  (`for_disk/1` leaves the entry out of them), the transcript or the API. The server
  that receives it checks it with `GET /api/auth/me`, whose
  `conversation_id` names the conversation the key belongs to.

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
  `${VAR}` already resolved and each `"auth": "conversation"` entry given the
  conversation's headers.

  `opts` is what `ConversationServer` unpacks from its state:

    * `:resolved`, the conversation's resolved MCP configuration (see
      `resolve_for_session/2`);
    * `:conversation`, `%{id: conversation_id, token: callback_token}`. A
      `nil` token (a `sandbox_api_access: "none"` conversation, or a mint
      that failed) sends the conversation id and no `Authorization`.

  The list this returns holds the plaintext key. It goes to the peer and
  nowhere else; `Managoat.ACP.Peer`'s `format_status/1` redacts it.
  """
  @spec for_session(Agent.t() | nil, keyword()) :: [map()]
  def for_session(agent, opts) do
    agent
    |> resolve_for_session(Keyword.get(opts, :resolved))
    |> authenticate(Keyword.get(opts, :conversation))
    |> Managoat.Runtimes.ACP.mcp_servers()
  end

  @doc """
  Each `"auth": "conversation"` entry with the flag replaced by the
  conversation's `Authorization` and `X-Managoat-Conversation-Id` headers.
  Headers of the same names the entry carries, in any case, are replaced.
  """
  @spec authenticate(Agent.t() | nil, %{id: String.t(), token: String.t() | nil} | nil) ::
          Agent.t() | nil
  def authenticate(%{mcp_servers: servers} = agent, conversation) when is_map(servers) do
    servers =
      Map.new(servers, fn
        {name, %{"auth" => "conversation"} = entry} ->
          {name, conversation_entry(entry, conversation || %{})}

        other ->
          other
      end)

    %{agent | mcp_servers: servers}
  end

  def authenticate(agent, _conversation), do: agent

  defp conversation_entry(entry, conversation) do
    token = conversation[:token]

    headers =
      (entry["headers"] || %{})
      |> Map.reject(fn {k, _} ->
        String.downcase(to_string(k)) in ["authorization", "x-managoat-conversation-id"]
      end)
      |> put_present("X-Managoat-Conversation-Id", conversation[:id])
      |> put_present("Authorization", is_binary(token) && token != "" && "Bearer " <> token)

    entry |> Map.delete("auth") |> Map.put("headers", headers)
  end

  defp put_present(map, key, value) when is_binary(value) and value != "",
    do: Map.put(map, key, value)

  defp put_present(map, _key, _value), do: map

  @doc """
  The agent as the project files in the sandbox take it (Claude's
  `.mcp.json`, Gemini's `settings.json`): without its `"auth":
  "conversation"` entries. Those reach the runtime over `session/new` only,
  from `for_session/2`, so there is one copy of the server and it is the one
  with the credential. A copy on the sandbox's disk would either lack the
  header or freeze a key that rotates on every reattach.
  """
  @spec for_disk(Agent.t() | nil) :: Agent.t() | nil
  def for_disk(%{mcp_servers: servers} = agent) when is_map(servers),
    do: %{agent | mcp_servers: Map.reject(servers, &match?({_, %{"auth" => "conversation"}}, &1))}

  def for_disk(agent), do: agent

  @doc """
  Put the conversation's already-resolved MCP configuration back onto a
  freshly-fetched agent, for the turn that is about to open a session.

  The turn path re-reads the agent row on every prompt, which is right — an
  edit between turns should take effect — but that row holds the *stored*
  document, with its `${VAR}` references and `$$` escapes unresolved. Sending
  that to ACP `session/new` was #1404: the session copy wins in Claude Code,
  so a header written `Bearer $${MANAGOAT_TOKEN}` reached the server as
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
  `${MANAGOAT_TOKEN}` and `${MANAGOAT_CONVERSATION_ID}` are process
  environment inside the sandbox, never entries in `vars`; a document that
  writes them `$${…}` leaves them for a runtime to expand, which only Claude
  does. The portable way to hand a server the callback credential is
  `"auth": "conversation"`, which `for_session/2` fills from the key the
  server holds when it builds the session list, so the key is never frozen
  into this document.
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
