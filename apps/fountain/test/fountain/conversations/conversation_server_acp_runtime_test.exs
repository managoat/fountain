defmodule Fountain.Conversations.ConversationServerAcpRuntimeTest do
  @moduledoc """
  A turn on the `acp` runtime (#1634), through a real `ConversationServer`.

  The protocol half is already pinned by `conversation_server_acp_test.exs`
  and is the same code here. What this file pins is what is different: the
  command the agent named is what gets spawned, no inference credential is
  resolved and no model is pinned, the stop reason still ends the turn with a
  null usage, `session/cancel` still reaches the process, and
  `session/request_permission` still honours the agent's policy.
  """

  use Fountain.ConversationServerCase

  @command "chant acp --env prod"

  defp acp_agent(user, overrides \\ []) do
    insert_agent(
      Keyword.merge([user_id: user.id, runtime: "acp", runtime_command: @command], overrides)
    )
  end

  # The same wiring `conversation_server_acp_test.exs` uses: every byte the
  # server writes to stdin arrives here as `{:wrote, line}`, and the command's
  # ref is ours so a test can feed stdout back.
  #
  # `decrypted_for_user` is left at `stub_happy_sprite/1`'s empty map on
  # purpose. This runtime must run a turn on an account that holds no
  # inference credential at all.
  defp start_acp_turn(conv) do
    stub_happy_sprite()

    test = self()
    ref = make_ref()

    Mimic.stub(Managoat.Sandbox.Sprites, :spawn, fn _h, cmd, args, opts ->
      send(test, {:spawned, cmd, args, opts})
      {:ok, %Managoat.Sandbox.Command{provider: :sprites, ref: ref}}
    end)

    Mimic.stub(Managoat.Sandbox.Sprites, :close_stdin, fn _c ->
      send(test, :stdin_closed)
      :ok
    end)

    Mimic.stub(Managoat.Sandbox.Sprites, :stop_command, fn _c ->
      send(test, :command_stopped)
      :ok
    end)

    Mimic.stub(Managoat.Sandbox.Sprites, :write_stdin, fn _c, data ->
      send(test, {:wrote, IO.iodata_to_binary(data)})
      :ok
    end)

    {pid, _mon, :alive} =
      start_server(conv, initial_prompt: "converge", runtime: Fountain.CommandRuntime)

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    {pid, ref}
  end

  defp next_write do
    assert_receive {:wrote, line}, 1_000
    Jason.decode!(line)
  end

  defp reply(pid, ref, id, result) do
    line = Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => result}) <> "\n"
    send(pid, {:stdout, %{ref: ref}, line})
    settle(pid)
  end

  defp notify(pid, ref, update) do
    line =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "method" => "session/update",
        "params" => %{"sessionId" => "sess_1", "update" => update}
      }) <> "\n"

    send(pid, {:stdout, %{ref: ref}, line})
    settle(pid)
  end

  # See the note on `settle/1` in conversation_server_acp_test.exs: a report
  # crosses three mailboxes, and the peer may already be gone.
  defp settle(pid) do
    peer = :sys.get_state(pid).acp_peer

    if is_pid(peer) do
      try do
        _ = :sys.get_state(peer)
      catch
        :exit, _ -> :ok
      end
    end

    _ = :sys.get_state(pid)
    :ok
  end

  defp drive_to_prompt(pid, ref) do
    %{"id" => init_id, "method" => "initialize"} = next_write()
    reply(pid, ref, init_id, %{"agentCapabilities" => %{"loadSession" => true}})

    %{"id" => new_id, "method" => "session/new"} = next_write()
    reply(pid, ref, new_id, %{"sessionId" => "sess_1"})

    %{"id" => prompt_id, "method" => "session/prompt"} = next_write()
    settle(pid)
    prompt_id
  end

  describe "spawn" do
    setup do
      user = insert_verified_user()
      conv = insert_conversation(agent: acp_agent(user), user_id: user.id)
      {pid, ref} = start_acp_turn(conv)
      {:ok, user: user, conv: conv, pid: pid, ref: ref}
    end

    test "runs the agent's own command as a shell line inside the sandbox" do
      assert_receive {:spawned, "env",
                      ["MANAGOAT_CONVERSATION_ID=" <> _, "FOUNTAIN_CONVERSATION_ID=" <> _ | argv],
                      opts}

      assert argv == ["bash", "-lc", @command]
      assert opts[:stdin] == true
    end

    test "writes initialize rather than the prompt, exactly as the LLM runtimes do" do
      assert %{"method" => "initialize"} = next_write()
    end

    test "session/new carries no model to pin", %{pid: pid, ref: ref} do
      %{"id" => init_id} = next_write()
      reply(pid, ref, init_id, %{"agentCapabilities" => %{"loadSession" => true}})

      assert %{"method" => "session/new", "params" => params} = next_write()
      refute Map.has_key?(params, "model")
    end
  end

  describe "a full turn on an account with no inference credential" do
    setup do
      user = insert_verified_user()
      conv = insert_conversation(agent: acp_agent(user), user_id: user.id)
      {pid, ref} = start_acp_turn(conv)
      {:ok, user: user, conv: conv, pid: pid, ref: ref}
    end

    test "blocks reach the transcript and the stop reason closes the turn", %{
      conv: conv,
      pid: pid,
      ref: ref
    } do
      prompt_id = drive_to_prompt(pid, ref)

      notify(pid, ref, %{
        "sessionUpdate" => "tool_call",
        "toolCallId" => "t1",
        "title" => "lifecycle apply",
        "kind" => "execute",
        "status" => "pending"
      })

      notify(pid, ref, %{
        "sessionUpdate" => "tool_call_update",
        "toolCallId" => "t1",
        "status" => "completed"
      })

      notify(pid, ref, %{
        "sessionUpdate" => "agent_message_chunk",
        "content" => %{"type" => "text", "text" => "3 resources converged"}
      })

      reply(pid, ref, prompt_id, %{"stopReason" => "end_turn"})

      events = Conversations._unsafe_list_log_events(conv.id)
      acp_events = Enum.filter(events, &(&1.stream == "acp"))

      blocks = Enum.flat_map(acp_events, &Fountain.Conversations.Blocks.for_event/1)
      assert Enum.any?(blocks, &(&1.kind == :tool_use and &1.name == "lifecycle apply"))
      assert Enum.any?(blocks, &(&1.kind == :tool_result and &1.tool_id == "t1"))
      assert Enum.any?(blocks, &(&1.kind == :text and &1.body =~ "converged"))

      assert [turn] = Conversations._unsafe_list_turns(conv.id)
      assert turn.status == "completed"
      refute is_nil(turn.ended_at)
      assert Conversations._unsafe_get_conversation!(conv.id).status == "idle"
    end

    test "the turn carries no usage, so nothing prices it by tokens", %{
      conv: conv,
      pid: pid,
      ref: ref
    } do
      prompt_id = drive_to_prompt(pid, ref)
      reply(pid, ref, prompt_id, %{"stopReason" => "end_turn"})

      assert [%{usage: nil}] = Conversations._unsafe_list_turns(conv.id)

      conv = Conversations._unsafe_get_conversation!(conv.id)
      assert conv.usage_input_tokens == 0
      assert conv.usage_output_tokens == 0
    end

    test "the model selection reports that nothing was requested", %{
      conv: conv,
      pid: pid,
      ref: ref
    } do
      prompt_id = drive_to_prompt(pid, ref)
      reply(pid, ref, prompt_id, %{"stopReason" => "end_turn"})

      stages =
        conv.id
        |> Conversations._unsafe_list_log_events()
        |> Enum.filter(&(&1.kind == "stage" and &1.stage == "model"))

      # Every turn reports its selection. This runtime pins nothing, so the
      # report is "the runtime's own", and the failed state that a refused
      # pin produces is unreachable here.
      assert [%{state: "done"} = selected] = stages
      assert %{"requested_model" => nil, "status" => "selected"} = Jason.decode!(selected.data)
      refute Enum.any?(stages, &(&1.state == "failed"))
    end

    test "a refusal stop reason still ends the turn", %{conv: conv, pid: pid, ref: ref} do
      prompt_id = drive_to_prompt(pid, ref)
      reply(pid, ref, prompt_id, %{"stopReason" => "refusal"})

      assert [turn] = Conversations._unsafe_list_turns(conv.id)
      refute turn.status == "running"
      assert Conversations._unsafe_get_conversation!(conv.id).status == "idle"
    end
  end

  describe "interrupt" do
    test "reaches the command as session/cancel and ends the turn interrupted" do
      user = insert_verified_user()
      conv = insert_conversation(agent: acp_agent(user), user_id: user.id)
      {pid, ref} = start_acp_turn(conv)
      _prompt_id = drive_to_prompt(pid, ref)

      assert :ok = GenServer.call(pid, :interrupt)

      assert %{"method" => "session/cancel", "params" => %{"sessionId" => "sess_1"}} =
               next_write()

      assert_receive :stdin_closed, 1_000
      assert_receive :command_stopped, 1_000

      assert [turn] = Conversations._unsafe_list_turns(conv.id)
      assert turn.status == "interrupted"
    end
  end

  describe "permission requests" do
    test "a request from the command is held and rendered, and the answer goes back" do
      user = insert_verified_user()
      agent = acp_agent(user, permission_policy: %{"execute" => "ask"})
      conv = insert_conversation(agent: agent, user_id: user.id)
      {pid, ref} = start_acp_turn(conv)
      _init = next_write()

      line =
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 401,
          "method" => "session/request_permission",
          "params" => %{
            "toolCall" => %{"title" => "lifecycle apply", "kind" => "execute"},
            "options" => [
              %{"optionId" => "yes", "kind" => "allow_once"},
              %{"optionId" => "no", "kind" => "reject_once"}
            ]
          }
        }) <> "\n"

      send(pid, {:stdout, %{ref: ref}, line})
      settle(pid)

      request_id = :sys.get_state(pid).current_turn.pending_permission["request_id"]
      assert request_id =~ ~r/^401\./

      blocks =
        conv.id
        |> Conversations._unsafe_list_log_events()
        |> Enum.filter(&(&1.stream == "acp"))
        |> Enum.flat_map(&Fountain.Conversations.Blocks.for_event/1)

      assert block = Enum.find(blocks, &(&1.kind == :permission_request))
      assert block.name == "lifecycle apply"

      assert :ok = GenServer.call(pid, {:answer_permission, request_id, "yes"})
      assert %{"id" => 401, "result" => %{"outcome" => %{"optionId" => "yes"}}} = next_write()
    end

    test "an auto_deny policy answers without asking anybody" do
      user = insert_verified_user()
      agent = acp_agent(user, permission_policy: %{"execute" => "auto_deny"})
      conv = insert_conversation(agent: agent, user_id: user.id)
      {pid, ref} = start_acp_turn(conv)
      _init = next_write()

      line =
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 402,
          "method" => "session/request_permission",
          "params" => %{
            "toolCall" => %{"title" => "rm -rf /", "kind" => "execute"},
            "options" => [
              %{"optionId" => "yes", "kind" => "allow_once"},
              %{"optionId" => "no", "kind" => "reject_once"}
            ]
          }
        }) <> "\n"

      send(pid, {:stdout, %{ref: ref}, line})
      settle(pid)

      assert %{"id" => 402, "result" => %{"outcome" => %{"optionId" => "no"}}} = next_write()
      assert is_nil(:sys.get_state(pid).current_turn.pending_permission)
    end
  end

  describe "an agent deleted under a live conversation" do
    test "refuses the turn rather than spawning nothing" do
      user = insert_verified_user()
      agent = acp_agent(user)
      conv = insert_conversation(agent: agent, user_id: user.id)

      # Deleting an agent nilifies its conversations' pointer, and the command
      # lived on the agent. Every other runtime resolves its argv from a table
      # and carries on; this one has nothing left to run.
      {:ok, _} = Fountain.Agents.delete_agent(agent)

      {pid, _ref} = start_acp_turn(conv)

      # No turn row, the way a sandbox at capacity opens none, and a stage
      # event on the feed saying why.
      assert [] = Conversations._unsafe_list_turns(conv.id)
      refute_receive {:spawned, _cmd, _args, _opts}, 200

      stage =
        conv.id
        |> Conversations._unsafe_list_log_events()
        |> Enum.find(&(&1.kind == "stage" and &1.stage == "turn" and &1.state == "failed"))

      assert stage.data =~ "no_runtime_command"
      assert Process.alive?(pid)
    end
  end
end
