defmodule FountainWeb.ChannelResumeTest do
  use FountainWeb.ConnCase, async: false
  use Mimic

  alias Fountain.Repo
  alias Fountain.Conversations.ConversationServer
  alias Fountain.Conversations.Launch

  setup do
    user = insert_verified_user()
    agent = insert_agent(user_id: user.id)

    owner = self()
    stub(ConversationServer, :queue_initial_prompt, fn _, _, _ -> send(owner, :queued) end)

    stub_server_start(fn _, _ ->
      send(owner, :worker_started)
      {:ok, owner}
    end)

    %{user: user, agent: agent}
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

  test "a suspended binding remains available for read-only lookup", ctx do
    conv = bound(ctx, "parked")
    conv.sandbox |> Ecto.Changeset.change(status: "suspended") |> Repo.update!()
    attrs = attrs(ctx, "parked")

    assert Launch.channel_conversation(attrs).id == conv.id
    assert Repo.reload!(conv.sandbox).status == "suspended"
    refute_received :worker_started
  end

  test "a channel resumes its existing binding", ctx do
    conv = bound(ctx, "existing")

    assert {:ok, resumed, :resumed} =
             Launch.start_or_resume_conversation(attrs(ctx, "existing"))

    assert resumed.id == conv.id
    refute_received :worker_started
  end

  test "another tenant cannot resume or look up the binding", ctx do
    _conv = bound(ctx, "private")
    foreign = insert_verified_user()
    foreign_attrs = Map.put(attrs(ctx, "private"), "user_id", foreign.id)
    assert {:error, :not_found} = Launch.start_or_resume_conversation(foreign_attrs)
    assert Launch.channel_conversation(foreign_attrs) == nil
    refute_received :worker_started
  end

  test "explicit fresh rotation unbinds the old conversation", ctx do
    conv = bound(ctx, "rotate")

    assert {:ok, fresh, :created} =
             Launch.start_or_resume_conversation(Map.put(attrs(ctx, "rotate"), "fresh", true))

    refute fresh.id == conv.id
    assert Repo.reload!(conv).channel_id == nil
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
end
