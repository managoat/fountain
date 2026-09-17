defmodule FountainWeb.SavedAllowanceChannelTest do
  use FountainWeb.ConnCase, async: false
  use Mimic

  alias Fountain.{Conversations, Repo}
  alias Fountain.Conversations.{ConversationServer, ExecutionAllowance}
  alias Fountain.Conversations.Launch

  setup do
    user = insert_verified_user()
    agent = insert_agent(user_id: user.id)
    {_key, raw} = insert_api_key(user)

    owner = self()
    stub(ConversationServer, :queue_initial_prompt, fn _, _, _ -> send(owner, :queued) end)

    stub(Horde.DynamicSupervisor, :start_child, fn _, _ ->
      send(owner, :worker_started)
      {:ok, owner}
    end)

    %{user: user, agent: agent, raw: raw}
  end

  for malformed <- [false, true] do
    test "native refuses a malformed=#{malformed} policy before admitting the channel", ctx do
      channel = channel(:native)
      conv = bound(ctx, channel)
      allowance = save(conv, %{max_model_turns: 2})

      error =
        if unquote(malformed) do
          allowance
          |> Ecto.Changeset.change(limits: %{"private-field" => "do not echo"})
          |> Repo.update!()

          {:error, {:execution_limits_invalid, "unknown_field"}}
        else
          {:error, {:execution_limits_unsupported, ["max_model_turns"]}}
        end

      # Model the downstream prompt guard: it already refuses, but that is
      # too late if channel admission let the request touch the row first.
      owner = self()

      stub(ConversationServer, :send_prompt, fn _, _, _, _ ->
        send(owner, :prompt_attempted)
        error
      end)

      before = Repo.reload!(conv)
      conn = request(ctx, :native, channel)
      assert Repo.reload!(conv) == before
      refute_received :prompt_attempted
      refute_received :queued
      refute_received :worker_started
      assert Conversations._unsafe_list_turns(conv.id) == []
      body = json_response(conn, 422)

      code =
        if unquote(malformed),
          do: "execution_limits_invalid",
          else: "execution_limits_unsupported"

      assert body["error"] == code

      refute Jason.encode!(body) =~ "private-field"
      refute Jason.encode!(body) =~ "do not echo"
    end
  end

  test "a rejected label mutation does not bind a legacy channel", ctx do
    conv = bound(ctx, "bad-labels")
    before = Repo.reload!(conv)
    assert is_nil(before.inference_source)

    assert {:error, _} =
             Launch.start_or_resume_conversation(
               Map.put(attrs(ctx, "bad-labels"), "labels", %{"bad" => ["not a string"]})
             )

    assert Repo.reload!(conv) == before
  end

  test "a successful channel label audit runs after its binding transaction", ctx do
    conv = bound(ctx, "label-audit")
    owner = self()

    expect(Fountain.Audit, :record, fn %{action: "conversation.labels_set"} ->
      send(owner, {:audit_transaction, Repo.in_transaction?()})
      assert Repo.reload!(conv).labels == %{"result" => "ready"}
      assert is_map(Repo.reload!(conv).inference_source)
      {:ok, nil}
    end)

    assert {:ok, _, :resumed} =
             Launch.start_or_resume_conversation(
               Map.put(attrs(ctx, "label-audit"), "labels", %{"result" => "ready"})
             )

    assert_received {:audit_transaction, false}
  end

  test "a successful legacy resume returns its committed source binding", ctx do
    conv = bound(ctx, "bind-success")
    assert is_nil(conv.inference_source)

    assert {:ok, resumed, :resumed} =
             Launch.start_or_resume_conversation(attrs(ctx, "bind-success"))

    assert is_map(resumed.inference_source)
    assert Repo.reload!(conv).inference_source == resumed.inference_source
  end

  test "a suspended binding is refused and remains available for read-only lookup", ctx do
    conv = bound(ctx, "parked")
    conv.sandbox |> Ecto.Changeset.change(status: "suspended") |> Repo.update!()
    save(conv, %{wall_time_seconds: 30})
    attrs = attrs(ctx, "parked")

    assert {:error, {:execution_limits_unsupported, ["wall_time_seconds"]}} =
             Launch.start_or_resume_conversation(attrs)

    assert Launch.channel_conversation(attrs).id == conv.id
    assert Repo.reload!(conv.sandbox).status == "suspended"
    refute_received :worker_started
  end

  test "absent and empty allowances resume the existing binding", ctx do
    for {channel, limits} <- [{"absent", nil}, {"empty", %{}}] do
      conv = bound(ctx, channel)
      if limits, do: save(conv, limits)

      assert {:ok, resumed, :resumed} =
               Launch.start_or_resume_conversation(attrs(ctx, channel))

      assert resumed.id == conv.id
      refute_received :worker_started
    end
  end

  test "another tenant cannot resume the binding or inspect its policy", ctx do
    conv = bound(ctx, "private")
    save(conv, %{max_model_turns: 2})
    foreign = insert_verified_user()
    foreign_attrs = Map.put(attrs(ctx, "private"), "user_id", foreign.id)
    assert {:error, :not_found} = Launch.start_or_resume_conversation(foreign_attrs)
    assert Launch.channel_conversation(foreign_attrs) == nil
    refute_received :worker_started
  end

  test "explicit fresh rotation does not inherit the old conversation allowance", ctx do
    conv = bound(ctx, "rotate")
    save(conv, %{max_model_turns: 2})

    assert {:ok, fresh, :created} =
             Launch.start_or_resume_conversation(Map.put(attrs(ctx, "rotate"), "fresh", true))

    refute fresh.id == conv.id
    assert Repo.reload!(conv).channel_id == nil
    assert Repo.get!(ExecutionAllowance, fresh.id).limits == %{}
    assert Repo.get!(ExecutionAllowance, conv.id).limits == %{"max_model_turns" => 2}
    assert_received :worker_started
  end

  defp bound(ctx, channel),
    do:
      insert_conversation(
        user_id: ctx.user.id,
        agent: ctx.agent,
        channel_id: channel,
        status: "idle"
      )

  defp attrs(ctx, channel),
    do: %{"user_id" => ctx.user.id, "agent_id" => ctx.agent.id, "channel_id" => channel}

  defp save(conv, limits),
    do: conv.id |> ExecutionAllowance.new_changeset(limits) |> Repo.insert!()

  defp channel(:native), do: "native-thread"

  defp request(ctx, :native, channel),
    do:
      ctx.conn
      |> authed_with_key(ctx.raw)
      |> post_json("/api/conversations", Map.delete(attrs(ctx, channel), "user_id"))
end
