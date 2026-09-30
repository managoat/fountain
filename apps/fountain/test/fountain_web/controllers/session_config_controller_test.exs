defmodule FountainWeb.SessionConfigControllerTest do
  @moduledoc """
  `session_config` over the API (ADR 0062): the agent round-trips it, a prompt
  carries it to the server as that turn's options, the conversation and its
  turns report it, and a malformed map is 422 at every door.
  """

  use FountainWeb.ConnCase, async: true
  use Mimic

  alias Fountain.Conversations.ConversationServer

  setup do
    user = insert_active_user()
    {_key, raw_key} = insert_api_key(user)
    {:ok, user: user, raw_key: raw_key}
  end

  describe "agents" do
    test "POST and PUT round-trip session_config; null clears it", %{conn: conn, raw_key: key} do
      body =
        conn
        |> authed_with_key(key)
        |> post_json("/api/agents", %{
          "name" => "effort-agent",
          "model" => "anthropic/claude-sonnet-4-6",
          "runtime" => "claude",
          "session_config" => %{"effort" => "high", "fast" => true}
        })
        |> json_response(201)

      assert body["data"]["session_config"] == %{"effort" => "high", "fast" => true}
      id = body["data"]["id"]

      body =
        build_conn()
        |> authed_with_key(key)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> put("/api/agents/#{id}", Jason.encode!(%{"session_config" => nil}))
        |> json_response(200)

      assert body["data"]["session_config"] == %{}
    end

    test "a malformed session_config is 422", %{conn: conn, raw_key: key} do
      conn =
        conn
        |> authed_with_key(key)
        |> post_json("/api/agents", %{
          "name" => "bad-agent",
          "model" => "anthropic/claude-sonnet-4-6",
          "runtime" => "claude",
          "session_config" => %{"model" => "anthropic/claude-opus-5"}
        })

      assert json_response(conn, 422)
    end
  end

  describe "POST /api/conversations/:id/prompts" do
    test "carries the turn's session_config with the prompt", %{
      conn: conn,
      user: user,
      raw_key: key
    } do
      conv = insert_conversation(user_id: user.id)
      test = self()

      stub(ConversationServer, :send_prompt, fn _id, _prompt, _images, opts ->
        send(test, {:prompt_opts, opts})
        :ok
      end)

      conn
      |> authed_with_key(key)
      |> post_json("/api/conversations/#{conv.id}/prompts", %{
        "prompt" => "think hard",
        "session_config" => %{"effort" => "max", "fast" => false}
      })
      |> json_response(200)

      assert_received {:prompt_opts, opts}
      assert opts[:session_config] == %{"effort" => "max", "fast" => false}
    end

    test "a malformed session_config is 422 and nothing is sent", %{
      conn: conn,
      user: user,
      raw_key: key
    } do
      conv = insert_conversation(user_id: user.id)
      reject(&ConversationServer.send_prompt/4)

      for bad <- [%{"model" => "x"}, %{"effort" => 3}, %{"bad id" => "x"}] do
        conn =
          build_conn()
          |> authed_with_key(key)
          |> post_json("/api/conversations/#{conv.id}/prompts", %{
            "prompt" => "x",
            "session_config" => bad
          })

        assert json_response(conn, 422), inspect(bad)
      end

      _ = conn
    end
  end

  test "the conversation and its turns report their options", %{
    conn: conn,
    user: user,
    raw_key: key
  } do
    options = [%{"id" => "effort", "type" => "select", "currentValue" => "high"}]

    conv = insert_conversation(user_id: user.id, session_config: %{"effort" => "high"})
    # Only the turn machine writes it; see `TurnMachine.handle/3`.
    :ok = Fountain.Conversations._unsafe_put_session_config_options(conv.id, options)

    selection = %{"requested" => %{"effort" => "high"}, "applied" => %{"effort" => "high"}}
    insert_turn(conv, config_selection: selection)

    body =
      conn |> authed_with_key(key) |> get("/api/conversations/#{conv.id}") |> json_response(200)

    assert body["data"]["session_config"] == %{"effort" => "high"}
    assert body["data"]["session_config_options"] == options

    [turn] =
      build_conn()
      |> authed_with_key(key)
      |> get("/api/conversations/#{conv.id}/turns")
      |> json_response(200)
      |> Map.fetch!("data")

    assert turn["config_selection"] == selection
  end
end
