defmodule FountainWeb.SearchControllerTest do
  @moduledoc "`GET /api/search` (#826)."
  use FountainWeb.ConnCase, async: true

  alias Fountain.Conversations

  setup do
    user = insert_verified_user()
    {_key, raw_key} = insert_api_key(user)
    agent = insert_agent(user_id: user.id, runtime: "claude")
    conv = insert_conversation(user_id: user.id, agent: agent, title: "Rotate the vault key")
    {:ok, user: user, raw_key: raw_key, agent: agent, conv: conv}
  end

  defp acp_text(text) do
    Jason.encode!(%{
      "jsonrpc" => "2.0",
      "method" => "session/update",
      "params" => %{
        "sessionId" => "s",
        "update" => %{
          "sessionUpdate" => "agent_message_chunk",
          "content" => %{"type" => "text", "text" => text}
        }
      }
    })
  end

  defp finished_turn(conv, prompt, reply) do
    turn = insert_turn(conv, prompt: prompt, status: "running")
    insert_log_event(conv, %{turn_id: turn.id, stream: "acp", data: acp_text(reply)})

    {:ok, turn} =
      Conversations._unsafe_update_turn(turn, %{
        status: "completed",
        ended_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

    turn
  end

  test "hits with kind, ids, snippet and ts; meta paging", %{
    conn: conn,
    raw_key: key,
    conv: conv,
    agent: agent
  } do
    turn = finished_turn(conv, "how do I rotate the key?", "Use `managoat vault rotate`.")

    body =
      conn
      |> authed_with_key(key)
      |> get("/api/search", q: "rotate", limit: 2)
      |> json_response(200)

    assert body["meta"] == %{"limit" => 2, "offset" => 0, "has_more" => true}
    assert length(body["data"]) == 2

    body =
      conn
      |> authed_with_key(key)
      |> get("/api/search", q: "rotate", limit: 10)
      |> json_response(200)

    assert body["meta"]["has_more"] == false
    kinds = body["data"] |> Enum.map(& &1["kind"]) |> Enum.sort()
    assert kinds == ["prompt", "reply", "title"]

    reply = Enum.find(body["data"], &(&1["kind"] == "reply"))
    assert reply["conversation_id"] == conv.id
    assert reply["agent_id"] == agent.id
    assert reply["turn_id"] == turn.id
    assert reply["turn_number"] == turn.turn_number
    assert reply["snippet"] =~ "vault rotate"
    assert {:ok, _, _} = DateTime.from_iso8601(reply["ts"])

    title = Enum.find(body["data"], &(&1["kind"] == "title"))
    assert title["turn_id"] == nil
  end

  test "filters and kinds pass through", %{conn: conn, raw_key: key, conv: conv, user: user} do
    finished_turn(conv, "rotate now", "rotated")
    other = insert_conversation(user_id: user.id, agent: insert_agent(user_id: user.id))
    finished_turn(other, "rotate later", "rotated")

    body =
      conn
      |> authed_with_key(key)
      |> get("/api/search", q: "rotate", conversation_id: other.id, kinds: "prompt")
      |> json_response(200)

    assert [%{"kind" => "prompt", "conversation_id" => id}] = body["data"]
    assert id == other.id

    future = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.to_iso8601()

    assert %{"data" => []} =
             conn
             |> authed_with_key(key)
             |> get("/api/search", q: "rotate", since: future)
             |> json_response(200)
  end

  test "never crosses tenants", %{conn: conn, conv: conv} do
    finished_turn(conv, "rotate the secret", "rotated")
    {_k, other_key} = insert_api_key(insert_verified_user())

    assert %{"data" => []} =
             conn
             |> authed_with_key(other_key)
             |> get("/api/search", q: "rotate")
             |> json_response(200)
  end

  test "422 without q or with a bad since (the spec); 400 on a blank q", %{
    conn: conn,
    raw_key: key
  } do
    assert conn |> authed_with_key(key) |> get("/api/search") |> json_response(422)

    assert %{"error" => "q_required"} =
             conn |> authed_with_key(key) |> get("/api/search", q: "  ") |> json_response(400)

    assert conn
           |> authed_with_key(key)
           |> get("/api/search", q: "x", since: "yesterday")
           |> json_response(422)
  end

  test "401 without a key", %{conn: conn} do
    assert conn |> get("/api/search", q: "x") |> json_response(401)
  end
end
