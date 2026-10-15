defmodule Managoat.ACP.Testing.ScriptedAgent do
  @moduledoc """
  An ACP agent inside the BEAM, for driving a `Managoat.ACP.Peer` in tests.

  It is the other end of the transport seam: `writer/1` is the function a
  test hands to `Peer.start/1`, and every frame the peer writes arrives here,
  is decoded, and is answered the way a well-behaved adapter would answer
  it. Replies go back into the peer through `Managoat.ACP.Peer.stdout/2`
  once `connect/2` has told the agent which peer it is talking to; frames
  written before that (the `initialize` the peer sends on start) are held
  and answered on connect.

  Test-only (`test/support`): Fountain's tests run a real peer against it
  without a sandbox, a port or a stub.

      {:ok, agent} = ScriptedAgent.start_link(updates: [text_chunk("hello")])

      {:ok, peer} =
        Peer.start(
          owner: self(),
          writer: ScriptedAgent.writer(agent),
          ref: make_ref(),
          prompt: "say hello",
          mode: :run,
          session_id: nil
        )

      :ok = ScriptedAgent.connect(agent, peer)

      assert_receive {:acp, _, {:session, "scripted-session"}}
      assert_receive {:acp, _, {:lines, "acp", line}}
      assert_receive {:acp, _, {:done, "end_turn", nil}}

  ## What it answers

  | client → agent | reply |
  |---|---|
  | `initialize` | `agentCapabilities` from `:capabilities`, `authMethods` from `:auth_methods` |
  | `authenticate` | `{}` |
  | `session/new` | `sessionId` from `:session_id`, merged with `:session_result` (put `configOptions` or `models` there to make the peer pin a model) |
  | `session/resume`, `session/load` | `:session_result` |
  | `session/set_config_option` | with no `configOptions` in `:session_result`, `{}`. With them, what the pinned adapters do: an id not listed is refused (`-32602`), as is a value outside a select's `options` (an option with no `options` list takes any value) or a non-boolean for a `boolean` option other than `"on"`/`"off"`; otherwise the option's `currentValue` becomes the value and the reply is the whole `configOptions` list, which later session results and setters also see |
  | `session/set_model` | `{}` |
  | `session/prompt` | the turn: `session/request_permission` first when `:permission` is set, then every map in `:updates` as a `session/update` notification, then the response with `:stop_reason` and `:usage` |
  | `session/cancel` | the outstanding prompt's response with `stopReason: "cancelled"` |
  | anything else with an id | a `-32601` error |

  A `:permission` is `%{"toolCall" => …, "options" => […]}` in the protocol's
  own shape; the agent sends it as a request and waits for the peer's answer
  before streaming the updates, exactly as a blocked adapter would. The
  answer's `outcome` is reported to the observer.

  ## What the observer sees

  Every frame the peer writes is reported to `:observer` (the process that
  started the agent, by default) as `{:scripted_agent, :wrote, decoded}`,
  so a test can assert on the wire as well as on what the owner received;
  and a permission answer as `{:scripted_agent, :permission_answered,
  outcome}`. Requests the agent sends carry ids from its own counter, which
  starts at 0 per turn — claude-agent-acp's measured habit, and the reason
  the peer mints public request ids.
  """

  use GenServer

  alias Managoat.ACP.{Peer, Protocol}

  @default_session_id "scripted-session"

  defstruct peer: nil,
            observer: nil,
            session_id: @default_session_id,
            capabilities: %{},
            auth_methods: [],
            session_result: %{},
            updates: [],
            stop_reason: "end_turn",
            usage: nil,
            permission: nil,
            next_id: 0,
            outbox: [],
            prompt_id: nil,
            pending_permission_id: nil

  @doc """
  Start an agent. Options: `:session_id`, `:capabilities`, `:auth_methods`,
  `:session_result`, `:updates`, `:stop_reason`, `:usage`, `:permission`,
  `:observer` (default: the caller), plus `:name`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, Keyword.put_new(opts, :observer, self()), gen_opts)
  end

  @doc """
  The writer to pass to `Managoat.ACP.Peer.start/1` as `writer:`.

  Total, as the transport contract requires: an agent that has stopped
  answers `{:error, :agent_exited}`, which the peer reports as
  `{:failed, {:acp_write_failed, :agent_exited}}` — the same shape a sandbox
  whose runtime exited produces.
  """
  @spec writer(GenServer.server()) :: Managoat.ACP.Transport.writer()
  def writer(agent) do
    fn iodata ->
      try do
        GenServer.call(agent, {:from_client, IO.iodata_to_binary(iodata)})
      catch
        :exit, _ -> {:error, :agent_exited}
      end
    end
  end

  @doc """
  Tell the agent which peer to answer. Frames written before this call are
  answered now, in order.
  """
  @spec connect(GenServer.server(), pid()) :: :ok
  def connect(agent, peer) when is_pid(peer), do: GenServer.call(agent, {:connect, peer})

  @doc "Send one `session/update` notification to the peer, out of turn or in it."
  @spec update(GenServer.server(), map()) :: :ok
  def update(agent, update) when is_map(update), do: GenServer.call(agent, {:update, update})

  @doc "Send an arbitrary line to the peer, newline appended if missing."
  @spec raw(GenServer.server(), binary()) :: :ok
  def raw(agent, line) when is_binary(line), do: GenServer.call(agent, {:raw, line})

  # ── callbacks ─────────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    {:ok, struct!(__MODULE__, Keyword.take(opts, Map.keys(%__MODULE__{}) -- [:__struct__]))}
  end

  @impl true
  def handle_call({:connect, peer}, _from, state) do
    state = %{state | peer: peer}
    state = Enum.reduce(Enum.reverse(state.outbox), %{state | outbox: []}, &emit(&2, &1))
    {:reply, :ok, state}
  end

  def handle_call({:from_client, line}, _from, state) do
    {messages, ""} = Protocol.feed("", line)

    state =
      Enum.reduce(messages, state, fn message, state ->
        send(state.observer, {:scripted_agent, :wrote, decoded(line)})
        handle(message, state)
      end)

    {:reply, :ok, state}
  end

  def handle_call({:update, update}, _from, state) do
    {:reply, :ok, session_update(state, update)}
  end

  def handle_call({:raw, line}, _from, state) do
    line = if String.ends_with?(line, "\n"), do: line, else: line <> "\n"
    {:reply, :ok, emit(state, line)}
  end

  # ── the script ────────────────────────────────────────────────────────────

  defp handle({:request, id, "initialize", _params}, state) do
    respond(state, id, %{
      "protocolVersion" => 1,
      "agentCapabilities" => state.capabilities,
      "authMethods" => state.auth_methods
    })
  end

  defp handle({:request, id, "authenticate", _params}, state), do: respond(state, id, %{})

  defp handle({:request, id, "session/new", _params}, state) do
    respond(state, id, Map.put(state.session_result, "sessionId", state.session_id))
  end

  defp handle({:request, id, method, _params}, state)
       when method in ["session/resume", "session/load"] do
    respond(state, id, state.session_result)
  end

  defp handle({:request, id, "session/set_config_option", params}, state) do
    case Map.get(state.session_result, "configOptions") do
      options when is_list(options) -> set_config_option(state, id, options, params)
      _ -> respond(state, id, %{})
    end
  end

  defp handle({:request, id, "session/set_model", _params}, state), do: respond(state, id, %{})

  defp handle({:request, id, "session/prompt", _params}, state) do
    state = %{state | prompt_id: id}

    case state.permission do
      nil -> run_turn(state)
      permission -> ask_permission(state, permission)
    end
  end

  defp handle({:request, id, method, _params}, state) do
    emit(state, Protocol.error(id, Protocol.method_not_found(), "#{method} is not supported"))
  end

  defp handle({:notification, "session/cancel", _params}, %{prompt_id: id} = state)
       when not is_nil(id) do
    respond(%{state | prompt_id: nil}, id, %{"stopReason" => "cancelled"})
  end

  defp handle({:notification, _method, _params}, state), do: state

  # The peer answered a request this agent sent — only permission requests
  # go that way.
  defp handle({:response, id, result}, %{pending_permission_id: id} = state) do
    send(state.observer, {:scripted_agent, :permission_answered, Map.get(result, "outcome")})
    run_turn(%{state | pending_permission_id: nil})
  end

  defp handle({:response, _id, _result}, state), do: state
  defp handle({:error_response, _id, _error}, state), do: state
  defp handle({:invalid, _line}, state), do: state

  defp ask_permission(state, permission) do
    id = state.next_id

    %{state | next_id: id + 1, pending_permission_id: id}
    |> emit(Protocol.request(id, "session/request_permission", permission))
  end

  defp run_turn(%{prompt_id: nil} = state), do: state

  defp run_turn(state) do
    state = Enum.reduce(state.updates, state, &session_update(&2, &1))

    result =
      %{"stopReason" => state.stop_reason}
      |> then(&if state.usage, do: Map.put(&1, "usage", state.usage), else: &1)

    respond(%{state | prompt_id: nil}, state.prompt_id, result)
  end

  defp session_update(state, update) do
    emit(
      state,
      Protocol.notification("session/update", %{
        "sessionId" => state.session_id,
        "update" => update
      })
    )
  end

  defp set_config_option(state, id, options, %{"configId" => config_id} = params) do
    value = Map.get(params, "value")

    case Enum.find(options, &(Map.get(&1, "id") == config_id)) do
      nil ->
        refuse(state, id, "Unknown config option: #{config_id}")

      option ->
        case accepted_value(option, value) do
          {:ok, current} ->
            options =
              Enum.map(options, fn
                %{"id" => ^config_id} = o -> Map.put(o, "currentValue", current)
                o -> o
              end)

            state = put_in(state.session_result["configOptions"], options)
            respond(state, id, %{"configOptions" => options})

          :error ->
            refuse(state, id, "Invalid value for config option #{config_id}: #{inspect(value)}")
        end
    end
  end

  defp set_config_option(state, id, _options, _params),
    do: refuse(state, id, "configId is required")

  defp accepted_value(%{"type" => "boolean"}, value) when is_boolean(value), do: {:ok, value}
  defp accepted_value(%{"type" => "boolean"}, "on"), do: {:ok, true}
  defp accepted_value(%{"type" => "boolean"}, "off"), do: {:ok, false}
  defp accepted_value(%{"type" => "boolean"}, _value), do: :error

  defp accepted_value(option, value) when is_binary(value) do
    case Map.get(option, "options") do
      values when is_list(values) and values != [] ->
        valid =
          values
          |> Enum.flat_map(fn o -> Map.get(o, "options") || [o] end)
          |> Enum.map(&Map.get(&1, "value"))

        if value in valid or value == Map.get(option, "currentValue"),
          do: {:ok, value},
          else: :error

      _ ->
        {:ok, value}
    end
  end

  defp accepted_value(_option, _value), do: :error

  # Invalid params, which is what codex-acp answers; claude-agent-acp's is an
  # internal error with the same sentence. The peer reads the sentence.
  defp refuse(state, id, message), do: emit(state, Protocol.error(id, -32_602, message))

  defp respond(state, id, result), do: emit(state, Protocol.response(id, result))

  # Before `connect/2` the reply waits; after it, it goes straight into the
  # peer as a stdout chunk would.
  defp emit(%{peer: nil} = state, iodata), do: %{state | outbox: [iodata | state.outbox]}

  defp emit(state, iodata) do
    Peer.stdout(state.peer, IO.iodata_to_binary(iodata))
    state
  end

  defp decoded(line) do
    case Jason.decode(String.trim_trailing(line, "\n")) do
      {:ok, map} -> map
      _ -> line
    end
  end
end
