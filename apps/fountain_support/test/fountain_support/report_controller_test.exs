defmodule FountainSupport.ReportControllerTest do
  use FountainWeb.ConnCase, async: true

  setup do
    user = insert_verified_user()
    {_key, raw_key} = insert_api_key(user)
    {:ok, user: user, raw_key: raw_key}
  end

  describe "POST /api/support/reports" do
    test "files a report with context and returns it", %{conn: conn, raw_key: key} do
      body =
        conn
        |> authed_with_key(key)
        |> post_json("/api/support/reports", %{
          "category" => "stuck",
          "message" => "Koda sits at starting",
          "context" => %{"conversation_id" => "c1", "agent_name" => "Koda"},
          "client" => "fountain-team test"
        })
        |> json_response(201)

      assert %{
               "data" => %{
                 "id" => id,
                 "category" => "stuck",
                 "message" => "Koda sits at starting",
                 "context" => %{"conversation_id" => "c1"},
                 "status" => "new",
                 "has_screenshot" => false
               }
             } = body

      assert %{"data" => [%{"id" => ^id}]} =
               conn |> authed_with_key(key) |> get("/api/support/reports") |> json_response(200)

      assert %{"data" => %{"id" => ^id}} =
               conn
               |> authed_with_key(key)
               |> get("/api/support/reports/#{id}")
               |> json_response(200)
    end

    test "rejects a bad category or an empty message", %{conn: conn, raw_key: key} do
      # the OpenAPI cast rejects the enum before the context sees it, and
      # renders it as `{error, errors}` like every other validation 422 (#1431)
      assert %{"error" => "validation_failed", "errors" => %{"category" => [_ | _]}} =
               conn
               |> authed_with_key(key)
               |> post_json("/api/support/reports", %{"category" => "rant", "message" => "x"})
               |> json_response(422)

      assert %{"error" => "validation_failed", "errors" => %{"message" => [_ | _]}} =
               conn
               |> authed_with_key(key)
               |> post_json("/api/support/reports", %{"category" => "bug", "message" => ""})
               |> json_response(422)

      # and a changeset error for what the schema cannot express (a huge context)
      big = %{"blob" => String.duplicate("x", 70 * 1024)}

      assert %{"errors" => %{"context" => [_]}} =
               conn
               |> authed_with_key(key)
               |> post_json("/api/support/reports", %{
                 "category" => "bug",
                 "message" => "x",
                 "context" => big
               })
               |> json_response(422)
    end

    test "another tenant cannot read it", %{conn: conn, raw_key: key} do
      %{"data" => %{"id" => id}} =
        conn
        |> authed_with_key(key)
        |> post_json("/api/support/reports", %{"category" => "bug", "message" => "mine"})
        |> json_response(201)

      {_k, other_key} = insert_api_key(insert_verified_user())

      conn
      |> authed_with_key(other_key)
      |> get("/api/support/reports/#{id}")
      |> json_response(404)
    end

    test "requires auth", %{conn: conn} do
      conn
      |> post_json("/api/support/reports", %{"category" => "bug", "message" => "x"})
      |> json_response(401)
    end
  end
end
