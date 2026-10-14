defmodule FountainWeb.ConversationAttachControllerTest do
  # Attaching by `sandbox_id` and persistent homes were removed (ADR 0073):
  # every conversation gets a sandbox of its own. The door refuses both with
  # the reason, keeps accepting `sandbox_mode: "ephemeral"`, and creates
  # nothing on a refusal.
  use FountainWeb.ConnCase, async: true

  import Ecto.Query, only: [from: 2]

  alias Fountain.Conversations.Conversation
  alias Fountain.Repo

  setup do
    user = insert_active_user()
    {_key_record, raw_key} = insert_api_key(user)
    env = insert_env(user_id: user.id)
    agent = insert_agent(user_id: user.id, runtime: "claude", environment_id: env.id)

    sandbox =
      insert_sandbox(
        user_id: user.id,
        status: "ready",
        agent_id: agent.id,
        environment_id: env.id
      )

    first = insert_conversation(user_id: user.id, agent: agent, sandbox: sandbox, status: "idle")
    {:ok, user: user, raw_key: raw_key, agent: agent, sandbox: sandbox, first: first}
  end

  defp create(ctx, body) do
    ctx.conn
    |> authed_with_key(ctx.raw_key)
    |> post_json("/api/conversations", Map.merge(%{"agent_id" => ctx.agent.id}, body))
  end

  defp conversation_count(user_id),
    do: Repo.aggregate(from(c in Conversation, where: c.user_id == ^user_id), :count)

  test "sandbox_id is refused with 422 sandbox_attach_unsupported", ctx do
    before = conversation_count(ctx.user.id)

    body =
      ctx
      |> create(%{"sandbox_id" => ctx.sandbox.id, "prompt" => "hello"})
      |> json_response(422)

    assert body["error"] == "sandbox_attach_unsupported"
    assert conversation_count(ctx.user.id) == before
  end

  test "sandbox_mode persistent is refused with 422 persistent_sandbox_removed", ctx do
    before = conversation_count(ctx.user.id)

    body = ctx |> create(%{"sandbox_mode" => "persistent"}) |> json_response(422)

    assert body["error"] == "persistent_sandbox_removed"
    assert conversation_count(ctx.user.id) == before
  end

  test "sandbox_id null is no attach, and sandbox_mode ephemeral is still accepted", ctx do
    stub_server_start(fn _s, _spec -> {:ok, spawn(fn -> :ok end)} end)

    data =
      ctx
      |> create(%{"sandbox_id" => nil, "sandbox_mode" => "ephemeral"})
      |> json_response(201)
      |> Map.fetch!("data")

    refute data["sandbox_id"] == ctx.sandbox.id
    assert data["sandbox"]["mode"] == "ephemeral"
  end
end
