defmodule FountainWeb.GmailMcpControllerTest do
  # Turns the broker on and off (global app env).
  use FountainWeb.ConnCase, async: false

  import Fountain.BrokerTestHelpers

  alias Fountain.Connections
  alias Fountain.Connections.{Gmail, Google, OAuth}

  setup do
    user = insert_verified_user()
    {_key, raw_key} = insert_sprite_api_key(user)
    connection = insert_connection(user, account_email: "me@example.com", access_token: "at-live")

    agent =
      insert_agent(
        user_id: user.id,
        mcp_servers: %{"gmail" => %{"connection" => connection.id}}
      )

    conv = insert_conversation(%{user_id: user.id, agent: agent, status: "idle"})
    enable_connections()

    {:ok, user: user, raw_key: raw_key, conv: conv, agent: agent, connection: connection}
  end

  defp rpc(conn, key, conv, connection, method, params \\ %{}) do
    conn
    |> authed_with_key(key)
    |> post_json("/api/mcp/gmail/#{conv.id}/#{connection.id}", %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => method,
      "params" => params
    })
  end

  # The gate here is the broker, like every other runtime path (#1693). The
  # rollout flag decides who may connect an account; a connection that exists
  # keeps working, and the console keeps the door that revokes it.
  test "the rollout flag going off leaves a connection the agent names working", ctx do
    Application.put_env(:fountain, :feature_flag_overrides, %{"connections" => false})

    body =
      rpc(ctx.conn, ctx.raw_key, ctx.conv, ctx.connection, "tools/list") |> json_response(200)

    assert [_ | _] = body["result"]["tools"]
  end

  test "the broker off refuses Gmail", ctx do
    Application.delete_env(:fountain, :broker_listen_port)
    response = rpc(ctx.conn, ctx.raw_key, ctx.conv, ctx.connection, "tools/list", %{})
    assert response.status == 403
  end

  test "serves tools/list for a conversation whose agent names the connection", ctx do
    body =
      rpc(ctx.conn, ctx.raw_key, ctx.conv, ctx.connection, "tools/list") |> json_response(200)

    names = Enum.map(body["result"]["tools"], & &1["name"])
    assert "gmail_search" in names
    assert "gmail_send" in names
    assert "gmail_reply" in names
  end

  test "initialize names the connected account", ctx do
    body =
      rpc(ctx.conn, ctx.raw_key, ctx.conv, ctx.connection, "initialize") |> json_response(200)

    assert body["result"]["serverInfo"]["name"] == "fountain-gmail"
    assert body["result"]["instructions"] =~ "me@example.com"
  end

  test "a tool call reaches Gmail with the connection's token, never the sandbox's", ctx do
    Req.Test.stub(Gmail, fn req ->
      assert Plug.Conn.get_req_header(req, "authorization") == ["Bearer at-live"]

      case req.request_path do
        "/gmail/v1/users/me/labels" ->
          Req.Test.json(req, %{
            "labels" => [%{"id" => "INBOX", "name" => "INBOX", "type" => "system"}]
          })
      end
    end)

    body =
      rpc(ctx.conn, ctx.raw_key, ctx.conv, ctx.connection, "tools/call", %{
        "name" => "gmail_list_labels",
        "arguments" => %{}
      })
      |> json_response(200)

    assert body["result"]["isError"] == false
    assert [%{"text" => text}] = body["result"]["content"]
    assert %{"labels" => [%{"id" => "INBOX"}]} = Jason.decode!(text)
  end

  test "gmail_search lists threads and reads each one's headers with repeated query keys", ctx do
    test_pid = self()

    Req.Test.stub(Gmail, fn req ->
      send(test_pid, {:gmail, req.request_path, req.query_string})

      case req.request_path do
        "/gmail/v1/users/me/threads" ->
          Req.Test.json(req, %{"threads" => [%{"id" => "t1"}], "resultSizeEstimate" => 1})

        "/gmail/v1/users/me/threads/t1" ->
          Req.Test.json(req, %{
            "id" => "t1",
            "messages" => [
              %{
                "id" => "m1",
                "snippet" => "hello there",
                "labelIds" => ["INBOX"],
                "payload" => %{
                  "headers" => [
                    %{"name" => "Subject", "value" => "Hi"},
                    %{"name" => "From", "value" => "a@example.com"}
                  ]
                }
              }
            ]
          })
      end
    end)

    body =
      rpc(ctx.conn, ctx.raw_key, ctx.conv, ctx.connection, "tools/call", %{
        "name" => "gmail_search",
        "arguments" => %{"query" => "newer_than:7d", "max_results" => 3}
      })
      |> json_response(200)

    assert body["result"]["isError"] == false, inspect(body)
    assert [%{"text" => text}] = body["result"]["content"]

    assert %{"threads" => [%{"id" => "t1", "subject" => "Hi", "from" => "a@example.com"}]} =
             Jason.decode!(text)

    assert_received {:gmail, "/gmail/v1/users/me/threads", q}
    assert URI.decode_query(q) == %{"q" => "newer_than:7d", "maxResults" => "3"}

    # Gmail wants a multi-valued parameter as a repeated key; a list value
    # used to raise in URI.encode_query and surface as a 500 (prod, day one).
    assert_received {:gmail, "/gmail/v1/users/me/threads/t1", q}
    assert q =~ "metadataHeaders=From&metadataHeaders=To"
    assert q =~ "format=metadata"
  end

  test "a send is audited as a use of the connection, without the content", ctx do
    Req.Test.stub(Gmail, fn req ->
      assert req.request_path == "/gmail/v1/users/me/messages/send"
      {:ok, body, _} = Plug.Conn.read_body(req)
      %{"raw" => raw} = Jason.decode!(body)
      {:ok, mime} = Base.url_decode64(raw, padding: false)
      assert mime =~ "To: a@example.com"
      assert mime =~ "Subject: hi"
      assert mime =~ "the secret body"
      Req.Test.json(req, %{"id" => "m1", "threadId" => "t1"})
    end)

    body =
      rpc(ctx.conn, ctx.raw_key, ctx.conv, ctx.connection, "tools/call", %{
        "name" => "gmail_send",
        "arguments" => %{"to" => "a@example.com", "subject" => "hi", "body" => "the secret body"}
      })
      |> json_response(200)

    assert body["result"]["isError"] == false

    [event] =
      ctx.user.id
      |> Fountain.Audit.list_recent_for_user(50)
      |> Enum.filter(&(&1.action == "connection.used"))

    assert event.actor == "sprite"
    assert event.metadata["tool"] == "gmail_send"
    assert event.metadata["recipients"] == 1
    refute inspect(event.metadata) =~ "secret body"
    refute inspect(event.metadata) =~ "a@example.com"
  end

  test "a revoked connection answers 'connection revoked', not a 401 from Google", ctx do
    Req.Test.stub(OAuth, fn req -> Req.Test.json(req, %{}) end)
    {:ok, _} = Connections.revoke(ctx.connection)
    Req.Test.stub(Gmail, fn _ -> flunk("Gmail must not be called for a revoked connection") end)

    body =
      rpc(ctx.conn, ctx.raw_key, ctx.conv, ctx.connection, "tools/call", %{
        "name" => "gmail_list_labels",
        "arguments" => %{}
      })
      |> json_response(200)

    assert body["result"]["isError"] == true
    assert [%{"text" => text}] = body["result"]["content"]
    assert text =~ "connection revoked"
  end

  test "an expired token is refreshed before the call, and the turn does not see it", ctx do
    expired = DateTime.utc_now() |> DateTime.add(-5, :second) |> DateTime.truncate(:second)

    connection =
      insert_connection(ctx.user,
        account_email: "me@example.com",
        expires_at: expired,
        refresh_token: "rt"
      )

    Req.Test.stub(OAuth, fn req ->
      assert req.request_path == "/token"
      Req.Test.json(req, %{"access_token" => "at-refreshed", "expires_in" => 3600})
    end)

    Req.Test.stub(Gmail, fn req ->
      assert Plug.Conn.get_req_header(req, "authorization") == ["Bearer at-refreshed"]
      Req.Test.json(req, %{"labels" => []})
    end)

    body =
      rpc(ctx.conn, ctx.raw_key, ctx.conv, connection, "tools/call", %{
        "name" => "gmail_list_labels",
        "arguments" => %{}
      })
      |> json_response(200)

    assert body["result"]["isError"] == false
  end

  test "404 when the agent does not name the connection, the conversation is another tenant's, or the connection is",
       ctx do
    plain_agent = insert_agent(user_id: ctx.user.id)
    plain = insert_conversation(%{user_id: ctx.user.id, agent: plain_agent, status: "idle"})
    assert rpc(ctx.conn, ctx.raw_key, plain, ctx.connection, "tools/list") |> json_response(404)

    other = insert_verified_user()
    {_k, other_key} = insert_sprite_api_key(other)
    enable_connections()
    assert rpc(ctx.conn, other_key, ctx.conv, ctx.connection, "tools/list") |> json_response(404)

    theirs = insert_connection(other)
    assert rpc(ctx.conn, ctx.raw_key, ctx.conv, theirs, "tools/list") |> json_response(404)
  end

  test "400 for a connection on another platform provider: these are Gmail tools (#1299)", ctx do
    slack = insert_connection(ctx.user, provider: "slack", account_email: "jake")

    agent =
      insert_agent(
        user_id: ctx.user.id,
        mcp_servers: %{"slack" => %{"connection" => slack.id}}
      )

    conv = insert_conversation(%{user_id: ctx.user.id, agent: agent, status: "idle"})

    body = rpc(ctx.conn, ctx.raw_key, conv, slack, "tools/list") |> json_response(400)
    assert body["error"] =~ "Google connections only"
  end

  test "403 for an account the broker is not on for", ctx do
    Application.delete_env(:fountain, :broker_listen_port)

    assert rpc(ctx.conn, ctx.raw_key, ctx.conv, ctx.connection, "tools/list")
           |> json_response(403)
  end

  test "a notification gets 202 and no body", ctx do
    conn =
      ctx.conn
      |> authed_with_key(ctx.raw_key)
      |> post_json("/api/mcp/gmail/#{ctx.conv.id}/#{ctx.connection.id}", %{
        "jsonrpc" => "2.0",
        "method" => "notifications/initialized"
      })

    assert response(conn, 202) == ""
  end
end
