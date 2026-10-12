defmodule FountainWeb.Plugs.ApiNotFoundTest do
  @moduledoc """
  An `/api` path no core route matches.

  Through the real endpoint and router, because the properties under test are
  properties of the mount: that the `:api` pipeline ran first and that core
  routes were tried before it.
  """
  use FountainWeb.ConnCase, async: true

  setup do
    user = insert_verified_user()
    {_record, raw_key} = insert_api_key(user)
    %{raw_key: raw_key}
  end

  test "an unknown path is refused without a key, like a real one", %{conn: conn} do
    conn = get(conn, "/api/nothing-serves-this")

    assert json_response(conn, 401)["reason"] == "api_key_invalid"
  end

  test "an unknown path is 404 JSON for an authenticated caller", ctx do
    conn =
      ctx.conn
      |> authed_with_key(ctx.raw_key)
      |> get("/api/nothing-serves-this/at-all")

    assert json_response(conn, 404) == %{"error" => "Not found", "reason" => "not_found"}
  end

  test "a bare /api is 404 rather than crashing on an empty path", ctx do
    conn =
      ctx.conn
      |> authed_with_key(ctx.raw_key)
      |> get("/api")

    assert json_response(conn, 404)["reason"] == "not_found"
  end

  test "a core route is served by core even though the fall-through is mounted at /api",
       ctx do
    conn =
      ctx.conn
      |> authed_with_key(ctx.raw_key)
      |> get("/api/agents")

    assert %{"data" => _} = json_response(conn, 200)
  end

  test "the public spec route is untouched", %{conn: conn} do
    assert conn |> get("/api/openapi.json") |> json_response(200)
  end
end
