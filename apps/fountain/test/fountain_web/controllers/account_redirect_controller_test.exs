defmodule FountainWeb.AccountRedirectControllerTest do
  @moduledoc "The console pages that became sections of `/account`."
  use FountainWeb.ConnCase, async: true

  @moved [
    {"/api-keys", "api-keys"},
    {"/account/oauth-apps", "oauth-apps"},
    {"/account/security", "password"}
  ]

  test "each old page redirects to /account with its section open", %{conn: conn} do
    conn = login_user(conn, insert_verified_user())

    for {old, section} <- @moved do
      assert redirected_to(get(conn, old)) == "/account?open=#{section}", old
    end
  end

  test "signed out, each bounces to login", %{conn: conn} do
    for {old, _} <- @moved do
      assert redirected_to(get(conn, old)) =~ "/auth/login", old
    end
  end
end
