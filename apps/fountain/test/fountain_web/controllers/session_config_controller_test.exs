defmodule FountainWeb.SessionConfigControllerTest do
  @moduledoc """
  `session_config` over the API (ADR 0062): the agent round-trips it and a
  malformed map is 422; the conversation and its turns report the agent's
  options from launch; a conversation create or a prompt that names options of
  its own is 422 `session_config_agent_only` (addendum of 2026-10-15).
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
    test "a prompt's own session_config is 422 and nothing is sent", %{
      conn: conn,
      user: user,
      raw_key: key
    } do
      conv = insert_conversation(user_id: user.id)
      reject(&ConversationServer.send_prompt/4)

      for config <- [%{"effort" => "max"}, %{"mode" => "bypassPermissions"}] do
        body =
          build_conn()
          |> authed_with_key(key)
          |> post_json("/api/conversations/#{conv.id}/prompts", %{
            "prompt" => "x",
            "session_config" => config
          })
          |> json_response(422)

        assert body["error"] == "session_config_agent_only", inspect(config)
      end

      _ = conn
    end

    test "null and {} are accepted, and nothing rides with the prompt", %{
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

      for config <- [nil, %{}] do
        build_conn()
        |> authed_with_key(key)
        |> post_json("/api/conversations/#{conv.id}/prompts", %{
          "prompt" => "think hard",
          "session_config" => config
        })
        |> json_response(200)

        assert_received {:prompt_opts, opts}
        refute Keyword.has_key?(opts, :session_config)
      end

      _ = conn
    end
  end

  describe "POST /api/conversations" do
    test "a conversation's own session_config is 422", %{conn: conn, raw_key: key} do
      agent =
        conn
        |> authed_with_key(key)
        |> post_json("/api/agents", %{
          "name" => "effort-agent",
          "model" => "anthropic/claude-sonnet-4-6",
          "runtime" => "claude"
        })
        |> json_response(201)

      body =
        build_conn()
        |> authed_with_key(key)
        |> post_json("/api/conversations", %{
          "agent_id" => agent["data"]["id"],
          "session_config" => %{"effort" => "high"}
        })
        |> json_response(422)

      assert body["error"] == "session_config_agent_only"
      assert body["message"] =~ "set it on the agent"
    end
  end

  test "a stored harness mode option is not served", %{conn: conn, user: user, raw_key: key} do
    effort = %{"id" => "effort", "type" => "select", "currentValue" => "high"}
    conv = insert_conversation(user_id: user.id)

    # A row written before the turn machine filtered them.
    :ok =
      Fountain.Conversations._unsafe_put_session_config_options(conv.id, [
        %{"id" => "mode", "currentValue" => "bypassPermissions"},
        effort
      ])

    body =
      conn |> authed_with_key(key) |> get("/api/conversations/#{conv.id}") |> json_response(200)

    assert body["data"]["session_config_options"] == [effort]
  end

  test "the conversation and its turns report their options", %{
    conn: conn,
    user: user,
    raw_key: key
  } do
    options = [%{"id" => "effort", "type" => "select", "currentValue" => "high"}]

    agent =
      insert_agent(user_id: user.id, runtime: "claude", session_config: %{"effort" => "high"})

    conv = insert_conversation(user_id: user.id, agent: agent)
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
