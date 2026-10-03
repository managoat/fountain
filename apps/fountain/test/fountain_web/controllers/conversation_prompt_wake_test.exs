defmodule FountainWeb.ConversationPromptWakeTest do
  @moduledoc """
  #2561: a prompt to a conversation with no server answers once the wake's own
  refusals have run, and the wake runs behind the response. A wake that then
  fails reports a `wake` `failed` stage. Callers that act on the refusal (the
  sandbox queue, a launch) still wait for the wake.
  """
  # Global, so the stubs reach the wake's task.
  use FountainWeb.ConnCase, async: false
  use Mimic

  import Ecto.Query, only: [from: 2]

  alias Fountain.Conversations.{ConversationServer, LogEvent, Wake}

  setup :set_mimic_global

  setup do
    user = insert_active_user()
    {_record, raw_key} = insert_api_key(user)
    agent = insert_agent(user_id: user.id)
    sandbox = insert_sandbox(user_id: user.id, status: "suspended")
    conv = insert_conversation(user_id: user.id, agent: agent, sandbox: sandbox, status: "idle")
    %{user: user, raw_key: raw_key, conv: conv, sandbox: sandbox}
  end

  defp prompt(raw_key, conv) do
    build_conn()
    |> authed_with_key(raw_key)
    |> post_json("/api/conversations/#{conv.id}/prompts", %{"prompt" => "hello"})
  end

  defp wake_stages(conv_id) do
    Fountain.Repo.all(
      from(e in LogEvent,
        where: e.conversation_id == ^conv_id and e.kind == "stage" and e.stage == "wake",
        order_by: e.id
      )
    )
  end

  test "answers queued before the wake, which runs behind the response", ctx do
    test_pid = self()

    stub(Wake, :wake_conversation, fn id, prompt, _images ->
      send(test_pid, {:waking, id, prompt, self()})
      receive do: (:finish -> {:ok, %{}})
    end)

    assert json_response(prompt(ctx.raw_key, ctx.conv), 200)["status"] == "queued"

    # The response is already back; the wake has started and is still going.
    assert_receive {:waking, id, "hello", waker}, 2_000
    assert id == ctx.conv.id
    assert Process.alive?(waker)
    send(waker, :finish)
  end

  test "a wake that fails behind the response reports a wake failed stage", ctx do
    stub(Wake, :wake_conversation, fn _id, _prompt, _images -> {:error, :sprite_probe_failed} end)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert json_response(prompt(ctx.raw_key, ctx.conv), 200)["status"] == "queued"

        assert eventually(fn -> wake_stages(ctx.conv.id) != [] end)
      end)

    assert [%{state: "failed", data: data}] = wake_stages(ctx.conv.id)
    assert Jason.decode!(data) == %{"reason" => "sprite_probe_failed", "retryable" => true}
    assert log =~ "background wake for a prompt failed"
  end

  test "a refusal that needs no provider still answers the request", ctx do
    reject(&Wake.wake_conversation/3)

    # A machine being torn down: refused at the door, as before.
    fenced =
      ctx.sandbox
      |> Ecto.Changeset.change(transition: "destroying")
      |> Fountain.Repo.update!()

    assert json_response(prompt(ctx.raw_key, ctx.conv), 409)["error"] == "sandbox_reset_pending"

    # A full fleet, for a wake that would add a machine.
    stub(Fountain.Quotas, :check_fleet_ceiling, fn _opts -> {:error, :fleet_full} end)

    fenced
    |> Ecto.Changeset.change(transition: nil)
    |> Fountain.Repo.update!()

    assert json_response(prompt(ctx.raw_key, ctx.conv), 503)["error"] == "fleet_full"
    assert wake_stages(ctx.conv.id) == []
  end

  test "a caller without wake: :background still waits for the wake", ctx do
    stub(Wake, :wake_conversation, fn _id, _prompt, _images -> {:error, :fleet_full} end)

    assert ConversationServer.send_prompt(ctx.conv.id, "hello", [], actor: "test") ==
             {:error, :fleet_full}

    assert wake_stages(ctx.conv.id) == []
  end

  defp eventually(fun, tries \\ 50) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(20) && eventually(fun, tries - 1)
    end
  end
end
