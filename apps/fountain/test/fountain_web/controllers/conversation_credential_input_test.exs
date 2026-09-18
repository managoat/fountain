defmodule FountainWeb.ConversationCredentialInputTest do
  use FountainWeb.ConnCase, async: true
  use Mimic
  alias Fountain.Repo
  alias Fountain.Conversations.Launch

  setup do
    user = insert_verified_user()
    agent = insert_agent(user_id: user.id)
    {_key, raw} = insert_api_key(user)
    sandbox = insert_sandbox(user_id: user.id, agent_id: agent.id, status: "ready")

    conv =
      insert_conversation(
        user_id: user.id,
        agent: agent,
        sandbox: sandbox,
        status: "idle",
        channel_id: "existing"
      )

    owner = self()

    stub_server_start(fn _, _ ->
      send(owner, :worker_started)
      {:ok, owner}
    end)

    %{user: user, agent: agent, raw: raw, conv: conv}
  end

  for value <- ["not-a-uuid", 123, true, false, [], %{}], channel <- [nil, "existing"] do
    test "refuses #{inspect(value)} credential ID for channel #{inspect(channel)}", c do
      attrs = %{
        "agent_id" => c.agent.id,
        "inference_credential_id" => unquote(Macro.escape(value))
      }

      attrs = if unquote(channel), do: Map.put(attrs, "channel_id", unquote(channel)), else: attrs
      before = Repo.reload!(c.conv)

      conn =
        c.conn
        |> authed_with_key(c.raw)
        |> put_req_header("content-type", "application/json")
        |> post("/api/conversations", attrs)

      # Before the public schema declares this field, the context returns
      # not-found. Once declared, request validation may refuse it first.
      assert conn.status in [404, 422]

      assert json_response(conn, conn.status)["error"] in [
               "inference_credential_not_found",
               "validation_failed"
             ]

      assert Repo.reload!(c.conv) == before
      assert Repo.aggregate(Fountain.Conversations.Conversation, :count) == 1
      refute_received :worker_started

      assert is_nil(Launch.channel_conversation(Map.put(attrs, "user_id", c.user.id)))
    end
  end
end
