defmodule FountainWeb.ConversationPromptSetupTest do
  @moduledoc """
  #2577: a prompt to a server that is still setting up its machine is queued
  behind the setup and answered `queued`, instead of waiting out the 30 s call
  and answering 503 while the prompt runs later anyway.
  """
  use FountainWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Fountain.Conversations.{LogEvent, ServerPhase, Wake}

  setup do
    user = insert_active_user()
    {_record, raw_key} = insert_api_key(user)
    agent = insert_agent(user_id: user.id)
    sandbox = insert_sandbox(user_id: user.id, status: "starting")

    conv =
      insert_conversation(user_id: user.id, agent: agent, sandbox: sandbox, status: "pending")

    %{raw_key: raw_key, conv: conv}
  end

  # A stand-in server: registered under the conversation, in the given phase,
  # reporting every message it gets. It answers no call, as a server inside
  # `handle_continue(:provision)` does not.
  defp stand_in(conv_id, phase) do
    test_pid = self()

    pid =
      spawn(fn ->
        {:ok, _} = Horde.Registry.register(Fountain.ConversationRegistry, conv_id, nil)
        if phase == :setting_up, do: ServerPhase.setting_up(conv_id)
        send(test_pid, :registered)
        relay(test_pid)
      end)

    assert_receive :registered, 2_000
    on_exit(fn -> Process.exit(pid, :kill) end)
    pid
  end

  defp relay(test_pid) do
    receive do
      msg -> send(test_pid, {:server_got, msg})
    end

    relay(test_pid)
  end

  defp prompt(raw_key, conv) do
    build_conn()
    |> authed_with_key(raw_key)
    |> post_json("/api/conversations/#{conv.id}/prompts", %{"prompt" => "hello"})
  end

  test "a server setting up gets the prompt queued, and the request answers at once", ctx do
    stand_in(ctx.conv.id, :setting_up)
    assert ServerPhase.setting_up?(ctx.conv.id)

    {micros, conn} = :timer.tc(fn -> prompt(ctx.raw_key, ctx.conv) end)

    assert json_response(conn, 200)["status"] == "queued"
    assert micros < 5_000_000
    assert_receive {:server_got, {:"$gen_cast", {:initial_prompt, "hello", []}}}, 2_000
  end

  test "a server that has finished setting up still gets the call", ctx do
    stand_in(ctx.conv.id, nil)
    refute ServerPhase.setting_up?(ctx.conv.id)

    # The stand-in never replies, so the request waits on the call; the
    # call is what this asserts, not its timeout.
    Task.start(fn -> prompt(ctx.raw_key, ctx.conv) end)
    assert_receive {:server_got, {:"$gen_call", _from, {:send_prompt, "hello", []}}}, 2_000
  end

  test "a queued prompt that does not run says so on the stream", ctx do
    Wake.report_unrun_prompt(ctx.conv.id, :conversation_busy)

    assert [%{state: "failed", data: data}] =
             Fountain.Repo.all(
               from(e in LogEvent,
                 where:
                   e.conversation_id == ^ctx.conv.id and e.kind == "stage" and e.stage == "wake"
               )
             )

    assert Jason.decode!(data) == %{"reason" => "conversation_busy", "retryable" => true}
  end
end
