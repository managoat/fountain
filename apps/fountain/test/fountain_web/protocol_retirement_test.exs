defmodule FountainWeb.ProtocolRetirementTest do
  @moduledoc """
  The retired compatibility surfaces (ADR 0057, #2252): the OpenAI-compatible
  gateway at `/v1`, the AG-UI run endpoint, and the caller-tool MCP adapter
  the two dialects fed.

  This suite is the guard that neither comes back by accident — a new route at
  one of these paths turns it red — and the record of what a client that still
  calls one actually sees. That is not one answer but three, and which one a
  caller gets is decided by the pipeline the path now falls through to rather
  than by anything either dialect ever did:

    * `/v1/*` matches no route at all. Phoenix renders `NoRouteError` as
      **404** `{"errors": {"detail": "Not Found"}}` for every Accept header,
      with or without a key, because nothing authenticates first.
    * `/api/agui/*` and `/api/mcp/caller/*` fall through to
      `FountainWeb.Plugs.ApiNotFound`,
      whose scope pipes through `:accepts_json` inside the `:api` pipeline. An
      authenticated JSON client gets **404**; an unauthenticated one gets
      **401**, because `TenantAPIAuth` runs first; and a client
      sending `Accept: text/event-stream` — exactly what an AG-UI client sends
      — is refused by content negotiation with **406**.

  The 401 and the 406 are the shared unmatched-`/api` behaviour, not surviving
  dialect handlers: the cross-checks below assert that an `/api` path which
  never existed answers each case identically. ADR 0057 records this as the
  retirement behaviour; "ordinary 404" is true only of `/v1`.
  """
  use FountainWeb.ConnCase, async: false

  setup do
    user = insert_verified_user()
    agent = insert_agent(user_id: user.id)
    conv = insert_conversation(user_id: user.id, agent: agent, status: "idle")
    {_key, raw} = insert_api_key(user)
    %{agent: agent, conv: conv, raw: raw}
  end

  describe "the OpenAI-compatible gateway is gone" do
    test "POST /v1/chat/completions is 404 for a JSON client", ctx do
      conn =
        ctx.conn
        |> authed_with_key(ctx.raw)
        |> post_json("/v1/chat/completions", %{
          "model" => ctx.agent.id,
          "messages" => [%{"role" => "user", "content" => "hi"}]
        })

      assert json_response(conn, 404) == %{"errors" => %{"detail" => "Not Found"}}
      assert_no_dialect_envelope(conn)
    end

    test "POST /v1/chat/completions is 404 for a streaming client too", ctx do
      conn =
        ctx.conn
        |> authed_with_key(ctx.raw)
        |> put_req_header("accept", "text/event-stream")
        |> post_json("/v1/chat/completions", %{
          "model" => ctx.agent.id,
          "messages" => [%{"role" => "user", "content" => "hi"}],
          "stream" => true
        })

      assert json_response(conn, 404) == %{"errors" => %{"detail" => "Not Found"}}
      refute conn.resp_body =~ "data:"
    end

    test "GET /v1/models and GET /v1/models/:model are 404", ctx do
      for path <- ["/v1/models", "/v1/models/#{ctx.agent.id}"] do
        conn = ctx.conn |> authed_with_key(ctx.raw) |> get(path)
        assert json_response(conn, 404) == %{"errors" => %{"detail" => "Not Found"}}
      end
    end

    test "a keyless call is 404 rather than 401: no route means no auth to fail", ctx do
      conn = get(ctx.conn, "/v1/models")
      assert json_response(conn, 404) == %{"errors" => %{"detail" => "Not Found"}}
    end
  end

  describe "the AG-UI run endpoint is gone" do
    test "POST /api/agui/:agent_id is the unmatched-path 404 for a JSON client", ctx do
      assert agui(ctx, &post_json(&1, "/api/agui/#{ctx.agent.id}", run_input())) ==
               unknown_api(ctx, &post_json(&1, "/api/never-existed/x", run_input()))
    end

    test "an AG-UI client's event-stream Accept is refused by negotiation with 406", ctx do
      assert_raise Phoenix.NotAcceptableError, fn ->
        ctx.conn
        |> authed_with_key(ctx.raw)
        |> put_req_header("accept", "text/event-stream")
        |> post_json("/api/agui/#{ctx.agent.id}", run_input())
      end

      # The same refusal an /api path that never existed gets, so 406 is
      # content negotiation and not a dialect handler still on its feet.
      assert_raise Phoenix.NotAcceptableError, fn ->
        ctx.conn
        |> authed_with_key(ctx.raw)
        |> put_req_header("accept", "text/event-stream")
        |> post_json("/api/never-existed/x", run_input())
      end
    end

    test "a keyless AG-UI call is 401, the shared /api answer before dispatch", ctx do
      conn = post_json(ctx.conn, "/api/agui/#{ctx.agent.id}", run_input())
      assert json_response(conn, 401)["reason"] == "api_key_invalid"
    end

    test "no dialect envelope survives on the retired path", ctx do
      conn =
        ctx.conn
        |> authed_with_key(ctx.raw)
        |> post_json("/api/agui/#{ctx.agent.id}", run_input())

      assert_no_dialect_envelope(conn)
    end
  end

  describe "the caller-tool MCP adapter is gone" do
    test "POST /api/mcp/caller/:conversation_id is the unmatched-path 404", ctx do
      assert caller_mcp(ctx, ctx.conv.id) == unknown_api_at("/api/never-existed/x", ctx)
    end

    test "a conversation the caller does not own answers the same way", ctx do
      # It used to be a tenant-scoped 404 from `build_ctx/2`. Now it is the
      # same unmatched-path 404 every other id gets, which is the point: the
      # route cannot be probed for whether a conversation exists.
      assert caller_mcp(ctx, Ecto.UUID.generate()) == caller_mcp(ctx, ctx.conv.id)
    end

    test "the team MCP adapter's route is untouched", _ctx do
      paths = Enum.map(FountainWeb.Router.__routes__(), & &1.path)

      assert "/api/mcp/team/:conversation_id" in paths
      refute "/api/mcp/caller/:conversation_id" in paths
    end
  end

  describe "the neighbours that stay" do
    test "the native API still answers the same key, so this is removal and not breakage", ctx do
      conn = ctx.conn |> authed_with_key(ctx.raw) |> get("/api/conversations")

      assert %{"data" => [_ | _]} = json_response(conn, 200)
    end

    test "no route in the router points at a retired dialect", _ctx do
      paths = Enum.map(FountainWeb.Router.__routes__(), & &1.path)

      refute Enum.any?(paths, &String.starts_with?(&1, "/v1"))
      refute Enum.any?(paths, &String.starts_with?(&1, "/api/agui"))
      refute Enum.any?(paths, &String.starts_with?(&1, "/api/mcp/caller"))

      # Guard the guard: the same walk still sees the routes that stay.
      assert "/api/conversations" in paths
      assert "/api/mcp/team/:conversation_id" in paths
    end
  end

  defp run_input,
    do: %{
      "threadId" => "thread",
      "runId" => "run",
      "messages" => [%{"role" => "user", "content" => "hi"}]
    }

  defp agui(ctx, fun), do: ctx.conn |> authed_with_key(ctx.raw) |> fun.() |> summary()
  defp unknown_api(ctx, fun), do: ctx.conn |> authed_with_key(ctx.raw) |> fun.() |> summary()
  defp summary(conn), do: {conn.status, Jason.decode!(conn.resp_body)}

  defp caller_mcp(ctx, conv_id),
    do:
      unknown_api_at(
        "/api/mcp/caller/#{conv_id}",
        ctx,
        %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"}
      )

  defp unknown_api_at(path, ctx, body \\ %{}),
    do: ctx.conn |> authed_with_key(ctx.raw) |> post_json(path, body) |> summary()

  # An OpenAI error body is `{"error": {"type": ..., "code": ...}}` and AG-UI's
  # is a `RUN_ERROR` event. Neither shape may survive the route.
  defp assert_no_dialect_envelope(conn) do
    refute conn.resp_body =~ "RUN_ERROR"
    refute conn.resp_body =~ "invalid_request_error"
    body = Jason.decode!(conn.resp_body)
    refute is_map(body["error"]) and Map.has_key?(body["error"], "type")
  end
end
