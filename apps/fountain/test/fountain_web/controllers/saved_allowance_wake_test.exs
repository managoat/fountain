defmodule FountainWeb.SavedAllowanceWakeTest do
  use FountainWeb.ConnCase, async: true
  use Mimic

  alias Fountain.{Conversations, Repo}
  alias Fountain.Conversations.{ConversationServer, ExecutionAllowance, Sandbox}
  alias Fountain.Conversations.Interruption
  alias Fountain.Conversations.Wake

  setup do
    user = insert_verified_user()
    agent = insert_agent(user_id: user.id)
    {_key, raw} = insert_api_key(user)
    owner = self()

    stub(Managoat.Sandbox.Sprites, :get, fn handle ->
      send(owner, :provider_probe)
      {:ok, %{status: :running, raw: %{name: handle.name}}}
    end)

    stub(Managoat.Sandbox.Sprites, :resume, fn handle ->
      send(owner, :provider_resume)
      {:ok, handle}
    end)

    stub(Horde.DynamicSupervisor, :start_child, fn _, _ ->
      send(owner, :worker_start)
      {:ok, owner}
    end)

    stub(ConversationServer, :queue_initial_prompt, fn _, _, _ ->
      send(owner, :prompt_queued)
      :ok
    end)

    %{user: user, agent: agent, raw: raw}
  end

  for status <- ~w(ready suspended pending starting terminated failed) do
    test "saved limits refuse a #{status} sandbox wake before side effects", ctx do
      sandbox = insert_sandbox(user_id: ctx.user.id, status: unquote(status))
      conv = conversation(ctx, sandbox) |> Repo.reload!()
      save(conv, %{max_model_turns: 2})
      count = Repo.aggregate(Sandbox, :count)

      for prompt <- [nil, "continue"] do
        assert {:error, {:execution_limits_unsupported, ["max_model_turns"]}} =
                 Wake.wake_conversation(conv.id, prompt)
      end

      assert Repo.reload!(conv) == conv
      assert Repo.reload!(sandbox) == sandbox
      assert Repo.aggregate(Sandbox, :count) == count
      assert Conversations._unsafe_list_turns(conv.id) == []
      refute_side_effects()
    end
  end

  test "the prompt API reports 422 instead of queueing a dormant conversation", ctx do
    conv = conversation(ctx, insert_sandbox(user_id: ctx.user.id, status: "ready"))
    save(conv, %{wall_time_seconds: 30})

    body =
      ctx.conn
      |> authed_with_key(ctx.raw)
      |> post_json("/api/conversations/#{conv.id}/prompts", %{prompt: "continue"})
      |> json_response(422)

    assert body["error"] == "execution_limits_unsupported"
    assert body["message"] =~ "wall_time_seconds"
    refute_side_effects()
  end

  test "malformed saved policy returns a safe 422", ctx do
    conv = conversation(ctx, insert_sandbox(user_id: ctx.user.id, status: "ready"))
    allowance = save(conv, %{})

    allowance
    |> Ecto.Changeset.change(limits: %{"private-value" => "do not echo"})
    |> Repo.update!()

    body =
      ctx.conn
      |> authed_with_key(ctx.raw)
      |> post_json("/api/conversations/#{conv.id}/prompts", %{prompt: "continue"})
      |> json_response(422)

    assert body == %{
             "error" => "execution_limits_invalid",
             "errors" => %{"execution_limits" => ["invalid unknown_field"]}
           }

    refute_side_effects()
  end

  test "another tenant's conversation remains a 404", ctx do
    other = insert_conversation()
    save(other, %{max_model_turns: 2})

    ctx.conn
    |> authed_with_key(ctx.raw)
    |> post_json("/api/conversations/#{other.id}/prompts", %{prompt: "continue"})
    |> json_response(404)

    refute_side_effects()
  end

  test "absent and empty allowances still wake and queue the prompt", ctx do
    for limits <- [:absent, %{}] do
      conv = conversation(ctx, insert_sandbox(user_id: ctx.user.id, status: "ready"))
      if limits != :absent, do: save(conv, limits)
      assert {:ok, _} = Wake.wake_conversation(conv.id, "continue")
      assert_received :provider_probe
      assert_received :worker_start
      assert_received :prompt_queued
    end
  end

  test "a saved limit does not prevent reconnecting to interrupt a running turn", ctx do
    conv = conversation(ctx, insert_sandbox(user_id: ctx.user.id, status: "ready"))
    conv = conv |> Ecto.Changeset.change(status: "running") |> Repo.update!()
    save(conv, %{max_model_turns: 2})
    owner = self()

    peer =
      spawn(fn ->
        receive do
          {:"$gen_call", from, :interrupt} ->
            send(owner, :interrupted)
            GenServer.reply(from, :ok)
        end
      end)

    on_exit(fn -> Process.exit(peer, :kill) end)
    stub(Horde.DynamicSupervisor, :start_child, fn _, _ -> {:ok, peer} end)

    expect(Horde.Registry, :lookup, fn Fountain.ConversationRegistry, id ->
      assert id == conv.id
      []
    end)

    expect(Horde.Registry, :lookup, fn Fountain.ConversationRegistry, id ->
      assert id == conv.id
      [{peer, nil}]
    end)

    assert :ok = Interruption.interrupt(conv.id)
    assert_received :interrupted
    assert_received :provider_probe
    refute_received :prompt_queued
  end

  test "cancellation does not wake an idle conversation", ctx do
    conv = conversation(ctx, insert_sandbox(user_id: ctx.user.id, status: "ready"))
    save(conv, %{max_model_turns: 2})
    assert {:error, :not_running} = Interruption.wake_for_interrupt(conv.id)
    refute_side_effects()
  end

  defp conversation(ctx, sandbox),
    do:
      insert_conversation(
        user_id: ctx.user.id,
        agent: ctx.agent,
        sandbox: sandbox,
        status: "idle"
      )

  defp save(conv, limits),
    do: conv.id |> ExecutionAllowance.new_changeset(limits) |> Repo.insert!()

  defp refute_side_effects do
    refute_received :provider_probe
    refute_received :provider_resume
    refute_received :worker_start
    refute_received :prompt_queued
  end
end
