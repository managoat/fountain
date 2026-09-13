defmodule FountainWeb.ConnectionControllerTest do
  # Turns the broker on and off (global app env).
  use FountainWeb.ConnCase, async: false

  import Fountain.BrokerTestHelpers

  alias Fountain.Connections
  alias Fountain.Connections.{Google, OAuth}

  setup %{conn: conn} do
    user = insert_verified_user()
    {:ok, {_key, raw}} = Fountain.Accounts.create_api_key(user.id, "t")
    enable_connections()

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{raw}")
      |> put_req_header("accept", "application/json")

    {:ok, conn: conn, user: user}
  end

  test "an account the broker is not on for gets 404 on every route", %{conn: conn} do
    Application.delete_env(:fountain, :broker_listen_port)

    assert %{"error" => "connections_not_enabled"} =
             conn |> get("/api/connections") |> json_response(404)

    assert %{"error" => "connections_not_enabled"} =
             conn |> get("/api/connections/providers") |> json_response(404)
  end

  test "lists, shows and deletes the caller's connections without a token", %{
    conn: conn,
    user: user
  } do
    c = insert_connection(user, account_email: "me@example.com", access_token: "never-shown-at")
    other = insert_verified_user()
    enable_connections()
    insert_connection(other, account_email: "them@example.com")

    body = conn |> get("/api/connections") |> json_response(200)

    assert [
             %{
               "id" => id,
               "account_email" => "me@example.com",
               "status" => "active",
               "env_key" => "GOOGLE_ACCESS_TOKEN"
             }
           ] = body["data"]

    assert id == c.id
    refute inspect(body) =~ "never-shown-at"

    assert %{"id" => ^id, "provider" => "google"} =
             conn |> get("/api/connections/#{id}") |> json_response(200)

    Req.Test.stub(OAuth, fn req -> Req.Test.json(req, %{}) end)
    assert conn |> delete("/api/connections/#{id}") |> response(204)
    assert Connections.list_connections(user.id) == []
    assert conn |> get("/api/connections/#{id}") |> json_response(404)
  end

  test "providers names each platform provider, its scopes and where to start", %{conn: conn} do
    assert %{"data" => [google, microsoft, slack]} =
             conn |> get("/api/connections/providers") |> json_response(200)

    assert google["id"] == "google"
    assert google["slug"] == "google"
    assert google["platform"] == true
    assert google["configured"] == true
    assert google["env_key"] == "GOOGLE_ACCESS_TOKEN"
    assert google["connect_url"] =~ "/connections/google/start"
    assert "https://www.googleapis.com/auth/gmail.modify" in google["scopes"]
    assert "https://www.googleapis.com/auth/calendar" in google["scopes"]

    # The contract a client leans on (#1299): scopes stay in the response, so
    # a catalog can light a product up by matching them.
    assert microsoft["id"] == "microsoft"
    assert microsoft["configured"] == true
    assert microsoft["connect_url"] =~ "/connections/microsoft/start"
    assert Enum.any?(microsoft["scopes"], &(&1 =~ ~r/mail/i))
    assert Enum.any?(microsoft["scopes"], &(&1 =~ ~r/calendar/i))
    assert Enum.any?(microsoft["scopes"], &(&1 =~ ~r/chat/i))

    assert slack["id"] == "slack"
    assert slack["configured"] == true
    assert slack["env_key"] == "SLACK_ACCESS_TOKEN"
    assert Enum.any?(slack["scopes"], &(&1 =~ ~r/chat/i))
  end

  test "a sprite-scoped key cannot see connections", %{user: user} do
    {_k, sprite_key} = insert_sprite_api_key(user)

    build_conn()
    |> put_req_header("authorization", "Bearer #{sprite_key}")
    |> put_req_header("accept", "application/json")
    |> get("/api/connections")
    |> json_response(403)
  end
end
