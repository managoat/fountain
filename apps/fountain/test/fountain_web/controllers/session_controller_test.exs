defmodule FountainWeb.SessionControllerTest do
  use FountainWeb.ConnCase, async: true
  use Mimic

  describe "GET /auth/login — GitHub button (#336)" do
    test "renders the button when GitHub OAuth is configured", %{conn: conn} do
      # config/test.exs sets a fake client id, so the configured path is the
      # default in the suite.
      body = conn |> get(~p"/auth/login") |> html_response(200)
      assert body =~ "Continue with GitHub"
      assert body =~ ~p"/auth/oauth/github"
    end

    test "hides the button when GitHub OAuth is not configured", %{conn: conn} do
      stub(FountainWeb.OAuth, :github_configured?, fn -> false end)

      body = conn |> get(~p"/auth/login") |> html_response(200)
      refute body =~ "Continue with GitHub"
      refute body =~ ~p"/auth/oauth/github"
    end
  end

  describe "GET /login (legacy route removed, #327)" do
    test "no route exists for the legacy admin login", %{conn: conn} do
      assert get(conn, "/login").status == 404
      assert post(conn, "/login", %{token: "x"}).status == 404
      assert post(conn, "/logout").status == 404
    end
  end

  describe "POST /auth/login — unverified account" do
    test "refuses with a message that says what to do, and issues no session", %{conn: conn} do
      user = insert_user()

      conn =
        post(conn, ~p"/auth/login", %{"email" => user.email, "password" => "password123"})

      body = html_response(conn, 403)
      assert body =~ "Confirm your email address"
      assert body =~ ~p"/auth/resend-verification"
      refute get_session(conn, :user_id)

      assert [event] =
               user.id
               |> Fountain.Audit.list_recent_for_user(10)
               |> Enum.filter(&(&1.action == "auth.login.failed"))

      assert event.metadata["reason"] == "unverified"
    end

    test "a wrong password on an unverified account looks like any bad login", %{conn: conn} do
      user = insert_user()

      conn = post(conn, ~p"/auth/login", %{"email" => user.email, "password" => "wrong"})

      body = html_response(conn, 401)
      assert body =~ "Invalid email or password"
      refute body =~ "Confirm your email"
    end
  end
end
