defmodule FountainWeb.AccountRedirectControllerTest do
  @moduledoc "The console pages that became sections of `/account`."
  use FountainWeb.ConnCase, async: true

  @moved [
    {"/api-keys", "api-keys"},
    {"/account/oauth-apps", "oauth-apps"},
    {"/account/security", "password"},
    {"/account/inference-credentials", "inference-credentials"},
    {"/account/bindings", "bindings"}
  ]

  test "each old page redirects to /account with its section open", %{conn: conn} do
    conn = login_user(conn, insert_verified_user())

    for {old, section} <- @moved do
      assert redirected_to(get(conn, old)) == Fountain.Apps.account_url(section), old
    end
  end

  test "account preserves only supported sections, never a redirect supplied by the visitor", %{
    conn: conn
  } do
    conn = login_user(conn, insert_verified_user())

    assert redirected_to(get(conn, "/account?open=connections")) ==
             Fountain.Apps.account_url("connections")

    assert redirected_to(get(conn, "/account?open=https://evil.test&server=https://evil.test")) ==
             Fountain.Apps.account_url()
  end

  test "bundled app and modules are static, with no LiveView connection", %{conn: conn} do
    response = get(conn, "/account-app/index.html")
    assert html_response(response, 200) =~ "<h1>Account</h1>"
    refute response.resp_body =~ "phx-session"
    assert get_resp_header(response, "referrer-policy") == ["no-referrer"]

    assert get(conn, "/account-app/assets/tokens.css").resp_body ==
             get(conn, "/assets/tokens.css").resp_body

    assert get(conn, "/account-app/images/app-icon.png").status == 200
    module = get(conn, "/account-app/auth.mjs")
    assert module.status == 200
    assert Enum.any?(get_resp_header(module, "content-type"), &String.contains?(&1, "javascript"))
  end

  test "signed out, each bounces to login", %{conn: conn} do
    for {old, _} <- @moved do
      assert redirected_to(get(conn, old)) =~ "/auth/login", old
    end
  end
end
