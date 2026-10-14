defmodule Fountain.Conversations.ConversationServerSessionIsolationTest do
  use Fountain.ConversationServerCase

  alias Managoat.ACP.Protocol
  alias Managoat.Sandbox.{Command, Session}

  defp settle(pid) do
    state = :sys.get_state(pid)
    if state.acp_peer, do: :sys.get_state(state.acp_peer)
    :sys.get_state(pid)
  end

  defp update_frame(session_id, text) do
    Protocol.notification("session/update", %{
      sessionId: session_id,
      update: %{sessionUpdate: "agent_message_chunk", content: %{type: "text", text: text}}
    })
    |> IO.iodata_to_binary()
  end

  defp permission(session_id) do
    Protocol.request(8, "session/request_permission", %{
      sessionId: session_id,
      toolCall: %{title: "run command", kind: "execute"},
      options: [%{optionId: "yes", kind: "allow_always"}]
    })
    |> IO.iodata_to_binary()
  end

  defp deliver(pid, data) do
    ref = :sys.get_state(pid).current_command_ref
    send(pid, {:stdout, %{ref: ref}, data})
    settle(pid)
  end

  defp start_owner(conv) do
    {pid, _, :alive} = start_server(conv)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    pid
  end

  test "two owners restart on one sandbox without crossing output or permission policies" do
    user = insert_verified_user()
    agent = insert_agent(user_id: user.id, runtime: "claude")
    sandbox = insert_sandbox(user_id: user.id, status: "ready")

    conversations =
      for {session_id, policy} <- [{"session-a", "ask"}, {"session-b", "auto_allow"}] do
        conv =
          insert_conversation(
            user_id: user.id,
            agent: agent,
            sandbox: sandbox,
            status: "running",
            runtime_session_id: session_id,
            permission_policy: %{"execute" => policy}
          )

        turn = insert_turn(conv, %{status: "running", prompt: "long task", acp_prompt_id: 4})
        {conv, turn}
      end

    stub_happy_sprite()
    test = self()

    sessions =
      for {{_conv, _}, index} <- Enum.with_index(conversations, 31_820) do
        # What Sprites actually reports after env/node execs the runtime.
        %Session{id: to_string(index), command: "codex app-server"}
      end

    session_ids =
      Map.new(Enum.zip(conversations, sessions), fn {{conv, _}, session} ->
        {conv.id, session.id}
      end)

    Mimic.stub(Managoat.Sandbox.Sprites, :exec, fn
      _, "sh", ["-c", _script, "fountain-session-identity" | ids], _ ->
        output = for {conv_id, id} <- session_ids, id in ids, into: "", do: "#{id} #{conv_id}\n"
        {:ok, output, 0}

      _, _, _, _ ->
        {:ok, "", 0}
    end)

    Mimic.stub(Managoat.Sandbox.Sprites, :list_sessions, fn _ -> {:ok, Enum.reverse(sessions)} end)

    Mimic.stub(Managoat.Sandbox.Sprites, :attach, fn _, id, _ ->
      send(test, {:attached, id})
      {:ok, %Command{provider: :sprites, ref: make_ref()}}
    end)

    Mimic.stub(Managoat.Sandbox.Sprites, :write_stdin, fn command, data ->
      send(test, {:wrote, command.ref, Jason.decode!(IO.iodata_to_binary(data))})
      :ok
    end)

    Mimic.stub(Managoat.Sandbox.Sprites, :close_stdin, fn _ -> :ok end)
    Mimic.stub(Managoat.Sandbox.Sprites, :stop_command, fn _ -> :ok end)

    # Both owners are alive and have persisted output before the restart.
    owners =
      for {conv, turn} <- conversations do
        pid = start_owner(conv)
        assert_receive {:attached, id}
        assert id == session_ids[conv.id]
        deliver(pid, update_frame(conv.runtime_session_id, "before restart"))
        {pid, turn}
      end

    for {pid, turn} <- owners do
      GenServer.stop(pid, :shutdown)
      assert Fountain.Repo.reload!(turn).status == "running"
    end

    [{a, turn_a}, {b, turn_b}] = conversations
    owner_a = start_owner(a)
    assert_receive {:attached, id_a}
    assert id_a == session_ids[a.id]
    owner_b = start_owner(b)
    assert_receive {:attached, id_b}
    assert id_b == session_ids[b.id]

    for {pid, conv, other} <- [{owner_a, a, b}, {owner_b, b, a}] do
      # Own buffered history is deduplicated, unseen own output is retained;
      # an accidentally misrouted foreign frame never enters the event log.
      deliver(
        pid,
        update_frame(conv.runtime_session_id, "before restart") <>
          update_frame(other.runtime_session_id, "foreign") <>
          update_frame(conv.runtime_session_id, "during restart") <>
          update_frame(conv.runtime_session_id, "live")
      )
    end

    # B must not grant A's execute request from its auto-allow policy.
    state_b = deliver(owner_b, permission(a.runtime_session_id))
    ref_b = state_b.current_command_ref

    assert_receive {:wrote, ^ref_b,
                    %{"id" => 8, "result" => %{"outcome" => %{"outcome" => "cancelled"}}}}

    assert state_b.current_turn.pending_permission == nil

    state_a = deliver(owner_a, permission(a.runtime_session_id))
    assert state_a.current_turn.pending_permission["request_id"]
    ref_a = state_a.current_command_ref
    refute_received {:wrote, ^ref_a, _}

    deliver(owner_b, permission(b.runtime_session_id))
    assert_receive {:wrote, ^ref_b, %{"result" => %{"outcome" => %{"optionId" => "yes"}}}}

    for {pid, conv, turn} <- [{owner_a, a, turn_a}, {owner_b, b, turn_b}] do
      deliver(pid, IO.iodata_to_binary(Protocol.response(4, %{stopReason: "end_turn"})))
      assert Fountain.Repo.reload!(turn).status == "completed"

      frames =
        Conversations._unsafe_list_log_events(conv.id)
        |> Enum.filter(&(&1.stream == "acp"))
        |> Enum.map(fn event ->
          assert event.turn_id == turn.id
          frame = Jason.decode!(event.data)
          assert frame["params"]["sessionId"] == conv.runtime_session_id
          frame
        end)

      texts =
        for %{
              "method" => "session/update",
              "params" => %{"update" => %{"content" => %{"text" => text}}}
            } <- frames,
            do: text

      assert texts == ["before restart", "during restart", "live"]
    end
  end

  test "an idle owner reaps only its own process after the command tag disappears" do
    user = insert_verified_user()
    agent = insert_agent(user_id: user.id)
    sandbox = insert_sandbox(user_id: user.id, status: "ready")
    idle = insert_conversation(user_id: user.id, agent: agent, sandbox: sandbox, status: "idle")

    busy =
      insert_conversation(user_id: user.id, agent: agent, sandbox: sandbox, status: "running")

    turn = insert_turn(busy, %{status: "running", acp_prompt_id: 4})
    stub_happy_sprite()
    test = self()

    Mimic.stub(Managoat.Sandbox.Sprites, :list_sessions, fn _ ->
      {:ok,
       [
         %Session{id: "22", command: "codex app-server"},
         %Session{id: "11", command: "codex app-server"}
       ]}
    end)

    Mimic.stub(Managoat.Sandbox.Sprites, :exec, fn
      _, "sh", ["-c", _, "fountain-session-identity" | _], _ ->
        {:ok, "11 #{idle.id}\n22 #{busy.id}\n", 0}

      _, _, _, _ ->
        {:ok, "", 0}
    end)

    Mimic.stub(Managoat.Sandbox.Sprites, :attach, fn _, id, _ ->
      send(test, {:attached, id})
      {:ok, %Command{provider: :sprites, ref: id}}
    end)

    Mimic.stub(Managoat.Sandbox.Sprites, :stop_command, fn command ->
      send(test, {:stopped, command.ref})
      :ok
    end)

    Mimic.stub(Managoat.Sandbox.Sprites, :close_stdin, fn command ->
      send(test, {:closed_stdin, command.ref})
      :ok
    end)

    start_owner(idle)
    assert_receive {:attached, "11"}
    assert_receive {:closed_stdin, "11"}
    assert_receive {:stopped, "11"}
    refute_received {:attached, "22"}
    assert Fountain.Repo.reload!(turn).status == "running"
  end

  test "unreadable or malformed process identities never authorize a session" do
    alias Fountain.Conversations.Identity
    handle = stub_happy_sprite()
    sessions = [%Session{id: "11", command: "codex app-server"}]

    for result <- [
          {:error, :unavailable},
          {:ok, "", 1},
          {:ok, "11 not-a-uuid\n99 #{Ecto.UUID.generate()}\n", 0}
        ] do
      Mimic.stub(Managoat.Sandbox.Sprites, :exec, fn _, _, _, _ -> result end)
      assert Identity.session_owners(handle, sessions) == %{"11" => nil}
    end
  end

  test "process inspection is limited to numeric Sprites session ids without command tags" do
    alias Fountain.Conversations.Identity
    user = insert_verified_user()
    handle = stub_happy_sprite()
    test = self()

    sessions = [
      %Session{id: "../environ"},
      %Session{id: "12", command: "env FOUNTAIN_CONVERSATION_ID=#{user.id} codex-acp"}
    ]

    Mimic.stub(Managoat.Sandbox.Sprites, :exec, fn _, _, _, _ ->
      send(test, :inspected)
      {:ok, "", 0}
    end)

    assert Identity.session_owners(handle, sessions)["12"] == user.id
    refute_received :inspected

    assert Identity.session_owners(%{handle | provider: :e2b}, [%Session{id: "11"}]) == %{
             "11" => nil
           }

    refute_received :inspected
  end
end
