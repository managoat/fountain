defmodule Fountain.Conversations.McpConnections do
  @moduledoc """
  How a connection's token reaches a remote MCP server (ADR 0085, decisions
  8 and 9): through the egress broker only.

  An agent's `mcp_servers` entry names a connection under `auth`:

      {"linear": {"type": "http", "url": "https://mcp.linear.app/mcp", "auth": {"connection": "<id>"}}}

  When a conversation provisions, `rewrite/2` turns that entry into an
  ordinary HTTP server with `Authorization: Bearer <placeholder>`, so every
  runtime sees a header and nothing else. The access token becomes a
  brokered secret under the connection's reserved key
  (`Fountain.Connections.broker_key/1`), with an implicit `bearer` binding
  to the server URL's host and no other (`attach/4`). The real token never
  enters the sandbox, the agent record, the transcript or a log; the broker
  registers it for redaction like every brokered value.

  Before each turn, `Egress.refresh_before_turn/1` re-reads each token
  through `reread/1`, which refreshes one that expires within ten minutes.
  During a turn, `schedule/1` arms a timer for ten minutes before the
  earliest expiry; it refreshes the same way and rewrites the live broker
  rules (`Egress.refresh_live/1`), because a turn can outlive an hour-long
  token. The exchange with the provider never runs in the server's process
  (`attach/4`). A connection that is pending, revoked, expired or gone refuses the
  turn with `connection_reconnect_required` (`gate/2`).

  Functions over values and the server's state map, as `Egress` is: the
  fields read and written are `connections`, `connection_expiries`,
  `connection_timer`, `brokered` and `broker_bindings`.
  """

  alias Fountain.{Broker, Connections}
  alias Fountain.SecretBindings.Binding

  # A timer that would fire in the past retries this soon instead.
  @retry_ms 30_000

  @type ref :: %{id: String.t(), key: String.t(), host: String.t()}

  @doc "The connections an agent's MCP servers name, one ref per connection."
  @spec refs(map() | nil) :: [ref()]
  def refs(%{mcp_servers: servers}) when is_map(servers) do
    servers
    |> Enum.sort_by(fn {name, _} -> to_string(name) end)
    |> Enum.flat_map(fn
      {_name, %{"auth" => %{"connection" => id}, "url" => url}}
      when is_binary(id) and is_binary(url) ->
        [%{id: id, key: Connections.broker_key(id), host: host(url)}]

      _ ->
        []
    end)
    |> Enum.uniq_by(& &1.id)
  end

  def refs(_agent), do: []

  @doc """
  The agent with each connection entry made an ordinary HTTP server: `auth`
  removed, `Authorization` set to the bearer placeholder. Any other entry is
  untouched.
  """
  @spec rewrite(map() | nil) :: map() | nil
  def rewrite(%{mcp_servers: servers} = agent) when is_map(servers) do
    servers =
      Map.new(servers, fn
        {name, %{"auth" => %{"connection" => id}} = entry} when is_binary(id) ->
          headers =
            (entry["headers"] || %{})
            |> Map.reject(fn {k, _} -> String.downcase(to_string(k)) == "authorization" end)
            |> Map.put("Authorization", "Bearer " <> placeholder(id))

          {name, entry |> Map.delete("auth") |> Map.put("headers", headers)}

        other ->
          other
      end)

    %{agent | mcp_servers: servers}
  end

  def rewrite(agent), do: agent

  @doc "The placeholder a connection's bearer is written as in the sandbox."
  @spec placeholder(String.t()) :: String.t()
  def placeholder(id), do: Broker.placeholder(Connections.broker_key(id))

  @doc """
  Put each connection's token into the brokered map, with its bearer
  binding. A connection that cannot serve now is left out of the brokered
  map (its turn is refused by `gate/2`) and comes back when it can. Returns
  the brokered map, the bindings and each token's expiry by connection id.

  Tokens due a refresh are refreshed in tasks, waited for at most
  `refresh_wait_ms/0`; one that takes longer is delivered later by
  `{:connection_refreshed, id}` to the caller.
  """
  @spec attach(String.t(), [ref()], map(), Broker.bindings()) ::
          {map(), Broker.bindings(), %{String.t() => DateTime.t() | nil}}
  def attach(user_id, refs, brokered, bindings) do
    tokens = tokens(user_id, refs, brokered)

    Enum.reduce(refs, {brokered, bindings, %{}}, fn ref, {brokered, bindings, expiries} ->
      bindings = Map.put(bindings, ref.key, [bearer_binding(ref)])

      case Map.fetch!(tokens, ref.id) do
        {:ok, token, expires_at} ->
          {Map.put(brokered, ref.key, token), bindings, Map.put(expiries, ref.id, expires_at)}

        {:error, _} ->
          {Map.delete(brokered, ref.key), bindings, expiries}
      end
    end)
  end

  # Each connection's token as stored, read by the caller (the server) from
  # the database alone. The ones due a refresh are exchanged in tasks, all at
  # once, never in the caller: a token endpoint may take its full connect and
  # receive timeouts, and the store retries with backoff after it. The caller
  # waits `refresh_wait_ms/0` for them; a refresh still running after that
  # carries on, leaving the stored token in place for now. Every task that
  # moves a token tells the caller with `{:connection_refreshed, id}`, so a
  # late one still reaches the live rules (`refreshed/1`); a transient
  # failure moves nothing and sends nothing, so it cannot loop. The lease and
  # compare-and-swap in `Connections.refresh/1` are what make a second
  # exchange of the same grant harmless.
  defp tokens(user_id, refs, brokered) do
    stored =
      Map.new(refs, &{&1.id, Connections.token_for_session(user_id, &1.id, refresh: false)})

    due =
      Enum.filter(refs, fn ref ->
        match?({:ok, _, %DateTime{}}, stored[ref.id]) and
          Connections.refresh_due?(elem(stored[ref.id], 2))
      end)

    if due == [], do: stored, else: Map.merge(stored, refresh(user_id, due, brokered))
  end

  defp refresh(user_id, refs, brokered) do
    caller = self()

    tasks =
      Enum.map(refs, fn ref ->
        held = Map.get(brokered, ref.key)

        Task.Supervisor.async_nolink(Fountain.TaskSupervisor, fn ->
          result = Connections.token_for_session(user_id, ref.id)

          unless match?({:ok, ^held, _}, result),
            do: send(caller, {:connection_refreshed, ref.id})

          result
        end)
      end)

    tasks
    |> Task.yield_many(timeout: refresh_wait_ms(), on_timeout: :ignore)
    |> Enum.zip(refs)
    |> Enum.flat_map(fn
      {{_task, {:ok, result}}, ref} -> [{ref.id, result}]
      {{_task, _late_or_exited}, _ref} -> []
    end)
    |> Map.new()
  end

  @doc "How long a server waits for its connections' refreshes before going on."
  @spec refresh_wait_ms() :: non_neg_integer()
  def refresh_wait_ms, do: Application.get_env(:fountain, :connection_refresh_wait_ms, 5_000)

  @doc """
  What the server does on `{:connection_refreshed, id}`: a refresh task
  moved a token. When the caller already took the result within
  `refresh_wait_ms/0` this changes nothing; when the refresh outlasted the
  wait, the tokens are read again and the live rules rewritten
  (`Egress.refresh_live/1`), and during a turn the timer is armed for the
  new expiry.
  """
  @spec refreshed(map()) :: map()
  def refreshed(state) do
    state = Fountain.Conversations.Egress.refresh_live(state)
    if Map.get(state, :current_turn), do: schedule(state), else: state
  end

  # The server URL's host, and nothing else: no wildcard, no other path.
  defp bearer_binding(ref) do
    %Binding{key: ref.key, host: ref.host, auth_type: "bearer", headers: %{}, enabled: true}
  end

  @doc """
  The tokens read again, before a turn or when the timer fires: each one
  refreshed first if it expires within ten minutes. Returns the state and
  whether a brokered value moved.
  """
  @spec reread(map()) :: {map(), boolean()}
  def reread(state) do
    case Map.get(state, :connections, []) do
      [] ->
        {state, false}

      refs ->
        {brokered, bindings, expiries} =
          attach(state.user_id, refs, state.brokered, state.broker_bindings)

        moved? = brokered != state.brokered or bindings != state.broker_bindings

        {%{state | brokered: brokered, broker_bindings: bindings}
         |> Map.put(:connection_expiries, expiries), moved?}
    end
  end

  @doc """
  Whether a turn may run: `:ok`, or
  `{:error, {:connection_reconnect_required, id}}` naming the first
  connection that needs the owner to reconnect.
  """
  @spec gate(String.t(), [ref()]) :: :ok | {:error, {:connection_reconnect_required, String.t()}}
  def gate(user_id, refs) do
    Enum.reduce_while(refs, :ok, fn ref, :ok ->
      case Connections.check_usable(user_id, ref.id) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  @doc """
  Arm the in-turn refresh timer for ten minutes before the earliest expiry,
  replacing any armed one. No connection with an expiry, no timer. The
  server answers `:refresh_connections`.
  """
  @spec schedule(map()) :: map()
  def schedule(state) do
    if timer = Map.get(state, :connection_timer), do: Process.cancel_timer(timer)

    timer =
      case next_refresh_ms(Map.get(state, :connection_expiries, %{})) do
        nil -> nil
        ms -> Process.send_after(self(), :refresh_connections, ms)
      end

    Map.put(state, :connection_timer, timer)
  end

  @doc "Milliseconds until the earliest token is due a refresh, or nil."
  @spec next_refresh_ms(%{String.t() => DateTime.t() | nil}) :: non_neg_integer() | nil
  def next_refresh_ms(expiries) do
    expiries
    |> Map.values()
    |> Enum.reject(&is_nil/1)
    |> Enum.min(DateTime, fn -> nil end)
    |> case do
      nil ->
        nil

      at ->
        due = Connections.refresh_due_at(at)
        ms = DateTime.diff(due, DateTime.utc_now(), :millisecond)
        if ms > 0, do: ms, else: @retry_ms
    end
  end

  defp host(url) do
    case URI.parse(url) do
      %URI{host: host, port: port} when is_binary(host) and port in [nil, 443] ->
        String.downcase(host)

      %URI{host: host, port: port} when is_binary(host) ->
        "#{String.downcase(host)}:#{port}"

      _ ->
        ""
    end
  end
end
