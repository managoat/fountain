defmodule Fountain.Conversations.ConversationServerAcpFixtureTest do
  @moduledoc """
  Conformance: a whole turn against a real ACP program (#1634).

  Every other test in this tree hand-feeds the protocol, so it proves what
  Fountain does with bytes it wrote itself. This one runs
  `test/fixtures/acp_agent.exs` as its own OS process, hands its stdio to a
  `ConversationServer` through `Fountain.FixtureAcpProcess`, and asserts on
  what lands in the transcript. Nothing in the loop knows the program, and
  the program knows nothing about Fountain.

  It is the acp runtime end to end: an agent that names a command, a turn
  with no model and no inference credential, tool-call and message blocks on
  the feed, the stop reason closing the turn, and a permission request the
  agent's policy answers.
  """

  use Fountain.ConversationServerCase

  alias Fountain.Conversations.Blocks

  defp launch(prompt, agent_overrides \\ []) do
    user = insert_verified_user()

    agent =
      insert_agent(
        Keyword.merge(
          [
            user_id: user.id,
            runtime: "acp",
            # `elixir` is on PATH inside the test VM, and the fixture is what
            # `FixtureAcpProcess` actually runs; the string is here so the
            # agent is configured the way a real one would be.
            runtime_command: "elixir #{Fountain.FixtureAcpProcess.fixture_path()}"
          ],
          agent_overrides
        )
      )

    conv = insert_conversation(agent: agent, user_id: user.id)

    stub_happy_sprite()

    _ref = Fountain.FixtureAcpProcess.stub_spawn()

    {pid, _mon, :alive} =
      start_server(conv, initial_prompt: prompt, runtime: Fountain.CommandRuntime)

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    {conv, pid}
  end

  # The agent is a separate OS process, so there is nothing to synchronise on
  # but the result. Poll the row the turn writes.
  defp await_turn(conv_id, status, timeout \\ 15_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    await_turn(conv_id, status, deadline, nil)
  end

  defp await_turn(conv_id, status, deadline, last) do
    turn = conv_id |> Conversations._unsafe_list_turns() |> List.first()

    cond do
      turn && turn.status == status ->
        turn

      System.monotonic_time(:millisecond) > deadline ->
        flunk("turn never reached #{status}; last was #{inspect(last || turn)}")

      true ->
        Process.sleep(50)
        await_turn(conv_id, status, deadline, turn)
    end
  end

  # The conversation row goes back to idle *after* the turn row closes, so a
  # turn that reached `completed` is not yet proof the conversation did. Wait
  # on the row the assertion reads.
  defp await_conversation(conv_id, status, timeout \\ 15_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    await_conversation(conv_id, status, deadline, nil)
  end

  defp await_conversation(conv_id, status, deadline, last) do
    conv = Conversations._unsafe_get_conversation!(conv_id)

    cond do
      conv.status == status ->
        conv

      System.monotonic_time(:millisecond) > deadline ->
        flunk("conversation never reached #{status}; last was #{inspect(last || conv.status)}")

      true ->
        Process.sleep(50)
        await_conversation(conv_id, status, deadline, conv.status)
    end
  end

  defp blocks(conv_id) do
    conv_id
    |> Conversations._unsafe_list_log_events()
    |> Enum.filter(&(&1.stream == "acp"))
    |> Enum.flat_map(&Blocks.for_event/1)
  end

  describe "a real ACP program, driven to completion" do
    test "the turn completes on the agent's stop reason, with its blocks on the feed" do
      {conv, _pid} = launch("converge the fleet")

      turn = await_turn(conv.id, "completed")

      # No model was pinned and no token figure came back, so the turn
      # carries no usage.
      assert is_nil(turn.usage)
      refute is_nil(turn.ended_at)

      blocks = blocks(conv.id)
      assert Enum.any?(blocks, &(&1.kind == :tool_use and &1.name == "lifecycle apply"))
      assert Enum.any?(blocks, &(&1.kind == :tool_result and &1.tool_id == "converge"))
      assert Enum.any?(blocks, &(&1.kind == :text and &1.body =~ "converged 3 resources"))

      conv_row = await_conversation(conv.id, "idle")
      assert conv_row.runtime_session_id == "fixture-session"
    end

    test "protocol chatter stays off the transcript" do
      {conv, _pid} = launch("converge the fleet")
      _turn = await_turn(conv.id, "completed")

      events = Conversations._unsafe_list_log_events(conv.id)
      refute Enum.any?(events, &(is_binary(&1.data) and &1.data =~ "protocolVersion"))
    end

    test "a permission request the policy denies ends the turn without a human" do
      # The fixture asks before it converges when the prompt mentions "ask",
      # and answers a denial with a `refusal` stop reason.
      {conv, _pid} =
        launch("ask before you converge", permission_policy: %{"execute" => "auto_deny"})

      turn = await_turn(conv.id, "failed")
      assert is_nil(turn.pending_permission)

      # Denied, so the fixture never ran its tool call.
      refute Enum.any?(blocks(conv.id), &(&1.kind == :tool_use))
    end

    test "a model call that failed outright is a failed turn, with the provider's words" do
      # The fixture plays codex-acp's out-of-credits sequence (#2545): retried
      # stream errors, the thread in systemError, the error as reply text, and
      # still `end_turn`.
      {conv, _pid} = launch("you are out of credits")

      turn = await_turn(conv.id, "failed")
      refute is_nil(turn.ended_at)

      assert [%{"reason" => reason, "stop_reason" => "end_turn"}] =
               conv.id
               |> Conversations._unsafe_list_log_events()
               |> Enum.filter(
                 &(&1.kind == "stage" and &1.stage == "turn" and &1.state == "failed")
               )
               |> Enum.map(&Jason.decode!(&1.data))

      assert reason =~ "You have no credits remaining."

      # The reply is still on the feed for a reader.
      assert Enum.any?(blocks(conv.id), &(&1.kind == :text and &1.body =~ "no credits"))
      assert await_conversation(conv.id, "idle")
    end

    test "a permission request the policy allows lets the program carry on" do
      {conv, _pid} =
        launch("ask before you converge", permission_policy: %{"execute" => "auto_allow"})

      _turn = await_turn(conv.id, "completed")

      blocks = blocks(conv.id)
      assert Enum.any?(blocks, &(&1.kind == :tool_use and &1.name == "lifecycle apply"))
      assert Enum.any?(blocks, &(&1.kind == :text and &1.body =~ "converged 3 resources"))
    end
  end
end
