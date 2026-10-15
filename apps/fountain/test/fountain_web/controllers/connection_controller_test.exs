defmodule FountainWeb.ConnectionControllerTest do
  @moduledoc """
  `/api/connections`, the callback and the client ID metadata document
  (ADR 0085), against `Fountain.Connections.FakeProvider`. Every response is
  checked against its operation's schema by the suite's guard.
  """
  use FountainWeb.ConnCase, async: true

  alias Fountain.Connections
  alias Fountain.Connections.FakeProvider

  setup %{conn: conn} do
    user = insert_verified_user()
    {:ok, {_key, raw}} = Fountain.Accounts.create_api_key(user.id, "t")
    FakeProvider.stub()

    api =
      conn
      |> put_req_header("authorization", "Bearer #{raw}")
      |> put_req_header("accept", "application/json")

    {:ok, api: api, user: user}
  end

  test "create, finish in the browser, list, get, reconnect, delete", %{
    api: api,
    conn: conn,
    user: user
  } do
    body =
      api
      |> post_json("/api/connections", %{url: FakeProvider.server_url()})
      |> json_response(201)

    assert %{"connection" => %{"id" => id, "status" => "pending"}, "authorize_url" => url} = body
    refute Map.has_key?(body["connection"], "access_token")

    state = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query() |> Map.fetch!("state")

    callback =
      conn
      |> login_user(user)
      |> get("/connections/callback", %{"state" => state, "code" => "good-code"})

    assert redirected_to(callback) == "/account?open=connections"
    assert Phoenix.Flash.get(callback.assigns.flash, :info) =~ "Connected"

    assert %{"data" => [%{"id" => ^id, "status" => "active"}]} =
             api |> get("/api/connections") |> json_response(200)

    assert %{"id" => ^id, "status" => "active", "expires_at" => _} =
             api |> get("/api/connections/#{id}") |> json_response(200)

    assert %{"authorize_url" => "https://auth.example.com/authorize?" <> _} =
             api |> post("/api/connections/#{id}/authorize") |> json_response(200)

    assert api |> delete("/api/connections/#{id}") |> response(204)
    assert api |> get("/api/connections/#{id}") |> json_response(404)
  end

  test "refusals carry a code and a sentence", %{api: api} do
    assert %{"error" => "invalid_url", "message" => _} =
             api
             |> post_json("/api/connections", %{url: "http://x.example"})
             |> json_response(422)

    assert %{"error" => "unsafe_url"} =
             api
             |> post_json("/api/connections", %{url: "https://private.example.com/mcp"})
             |> json_response(422)

    %{"connection" => %{"id" => id}} =
      api
      |> post_json("/api/connections", %{url: FakeProvider.server_url()})
      |> json_response(201)

    assert %{"error" => "connection_exists", "connection_id" => ^id} =
             api
             |> post_json("/api/connections", %{url: FakeProvider.server_url()})
             |> json_response(409)
  end

  test "a server with no registration asks for a client", %{api: api} do
    FakeProvider.stub(registration: false, cimd: false)

    assert %{"error" => "client_required", "message" => message} =
             api
             |> post_json("/api/connections", %{url: FakeProvider.server_url()})
             |> json_response(422)

    assert message =~ "/connections/callback"

    assert %{"connection" => %{"registration" => "pasted"}} =
             api
             |> post_json("/api/connections", %{url: FakeProvider.server_url(), client_id: "mine"})
             |> json_response(201)
  end

  test "another account's connection is not found", %{api: api} do
    other = insert_verified_user()
    {:ok, pending, _} = Connections.create(other.id, %{"url" => FakeProvider.server_url()})

    assert api |> get("/api/connections/#{pending.id}") |> json_response(404)
    assert api |> delete("/api/connections/#{pending.id}") |> json_response(404)
    assert api |> post("/api/connections/#{pending.id}/authorize") |> json_response(404)
  end

  test "the callback needs a signed-in browser, and only the starter's", %{api: api, conn: conn} do
    %{"authorize_url" => url} =
      api
      |> post_json("/api/connections", %{url: FakeProvider.server_url()})
      |> json_response(201)

    state = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query() |> Map.fetch!("state")

    signed_out = get(conn, "/connections/callback", %{"state" => state, "code" => "good-code"})
    assert redirected_to(signed_out) =~ "/auth/login"

    stranger =
      conn
      |> login_user(insert_verified_user())
      |> get("/connections/callback", %{"state" => state, "code" => "good-code"})

    assert Phoenix.Flash.get(stranger.assigns.flash, :error) =~ "another account"
    refute_received {:provider, "POST", "token.example.com", _, _, _}
  end

  test "the client ID metadata document is public JSON", %{conn: conn} do
    body = conn |> get("/connections/client.json") |> json_response(200)
    assert body["client_id"] =~ "/connections/client.json"
    assert body["redirect_uris"] == [Connections.redirect_uri()]
  end
end
