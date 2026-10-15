defmodule FountainWeb.PasswordResetControllerTest do
  use FountainWeb.ConnCase, async: true
  use Oban.Testing, repo: Fountain.Repo

  alias Fountain.Accounts
  alias Fountain.Workers.PasswordResetEmail

  describe "GET /auth/forgot-password" do
    test "renders the forgot password form", %{conn: conn} do
      conn = get(conn, ~p"/auth/forgot-password")
      assert html_response(conn, 200) =~ "reset"
    end
  end

  describe "POST /api/auth/forgot" do
    test "always returns 200 regardless of whether email exists", %{conn: conn} do
      conn =
        conn
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> post("/api/auth/forgot", Jason.encode!(%{email: "nobody@example.com"}))

      assert json_response(conn, 200)["message"] =~ "registered"
    end

    test "returns 200 for a real user too (no enumeration)", %{conn: conn} do
      user = insert_verified_user()

      conn =
        conn
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> post("/api/auth/forgot", Jason.encode!(%{email: user.email}))

      assert json_response(conn, 200)["message"] =~ "registered"
    end

    test "returns 200 even with no email param", %{conn: conn} do
      conn =
        conn
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> post("/api/auth/forgot", Jason.encode!(%{}))

      assert json_response(conn, 200)
    end

    test "enqueues a durable reset email for a registered address", %{conn: conn} do
      user = insert_verified_user()

      conn =
        conn
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> post("/api/auth/forgot", Jason.encode!(%{email: user.email}))

      assert json_response(conn, 200)["message"] =~ "registered"
      assert_enqueued(worker: PasswordResetEmail, args: %{user_id: user.id})
    end

    test "enqueues nothing for an unknown address", %{conn: conn} do
      conn
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> post("/api/auth/forgot", Jason.encode!(%{email: "nobody@example.com"}))

      refute_enqueued(worker: PasswordResetEmail)
    end
  end

  describe "GET /auth/reset/:token" do
    test "renders reset form for valid token", %{conn: conn} do
      user = insert_verified_user()

      token =
        Phoenix.Token.sign(
          FountainWeb.Endpoint,
          "password_reset",
          {user.id, user.session_version}
        )

      conn = get(conn, ~p"/auth/reset/#{token}")
      assert html_response(conn, 200) =~ "new password"
    end

    test "redirects with error for invalid token", %{conn: conn} do
      conn = get(conn, ~p"/auth/reset/badtoken")
      assert redirected_to(conn) == ~p"/auth/forgot-password"
    end

    test "redirects with error when reset token has expired", %{conn: conn} do
      user = insert_verified_user()

      expired_token =
        Phoenix.Token.sign(
          FountainWeb.Endpoint,
          "password_reset",
          {user.id, user.session_version},
          signed_at: 0
        )

      conn = get(conn, ~p"/auth/reset/#{expired_token}")
      assert redirected_to(conn) == ~p"/auth/forgot-password"
    end
  end

  describe "POST /auth/reset" do
    test "updates password and drops session", %{conn: conn} do
      user = insert_verified_user()
      old_hash = Accounts.get_user(user.id).password_hash

      token =
        Phoenix.Token.sign(
          FountainWeb.Endpoint,
          "password_reset",
          {user.id, user.session_version}
        )

      conn = post(conn, ~p"/auth/reset", %{"token" => token, "password" => "newpassword123"})
      assert redirected_to(conn) == ~p"/auth/login"

      updated = Accounts.get_user(user.id)
      refute updated.password_hash == old_hash
      # session_version bumped — old sessions invalidated
      assert updated.session_version > user.session_version
    end

    test "re-renders form with error on short password", %{conn: conn} do
      user = insert_verified_user()

      token =
        Phoenix.Token.sign(
          FountainWeb.Endpoint,
          "password_reset",
          {user.id, user.session_version}
        )

      conn = post(conn, ~p"/auth/reset", %{"token" => token, "password" => "short"})
      assert html_response(conn, 422) =~ "new password"
    end

    test "redirects with error for invalid token", %{conn: conn} do
      conn =
        post(conn, ~p"/auth/reset", %{"token" => "badtoken", "password" => "validpassword123"})

      assert redirected_to(conn) == ~p"/auth/forgot-password"
    end

    test "redirects with error when user no longer exists in database", %{conn: conn} do
      # Sign a token with a UUID that doesn't correspond to any user
      missing_id = Ecto.UUID.generate()
      token = Phoenix.Token.sign(FountainWeb.Endpoint, "password_reset", {missing_id, 1})

      conn = post(conn, ~p"/auth/reset", %{"token" => token, "password" => "validpassword123"})
      assert redirected_to(conn) == ~p"/auth/forgot-password"
    end

    test "redirects with error when reset token has expired", %{conn: conn} do
      user = insert_verified_user()

      expired_token =
        Phoenix.Token.sign(
          FountainWeb.Endpoint,
          "password_reset",
          {user.id, user.session_version},
          signed_at: 0
        )

      conn =
        post(conn, ~p"/auth/reset", %{"token" => expired_token, "password" => "newpassword123"})

      assert redirected_to(conn) == ~p"/auth/forgot-password"
    end

    # #325: tokens used to stay valid for the rest of their hour after a
    # successful reset — anyone who later obtained the link (shared inbox,
    # forwarded mail, proxy log) could re-reset the password.
    test "a token cannot be replayed after a successful reset", %{conn: conn} do
      user = insert_verified_user()

      token =
        Phoenix.Token.sign(
          FountainWeb.Endpoint,
          "password_reset",
          {user.id, user.session_version}
        )

      conn1 = post(conn, ~p"/auth/reset", %{"token" => token, "password" => "newpassword123"})
      assert redirected_to(conn1) == ~p"/auth/login"
      hash_after_first = Accounts.get_user(user.id).password_hash

      conn2 = post(conn, ~p"/auth/reset", %{"token" => token, "password" => "attackerpass99"})
      assert redirected_to(conn2) == ~p"/auth/forgot-password"

      # The replay changed nothing.
      assert Accounts.get_user(user.id).password_hash == hash_after_first

      # The form view refuses it too.
      assert redirected_to(get(conn, ~p"/auth/reset/#{token}")) == ~p"/auth/forgot-password"
    end

    test "any token issued before the last successful reset is dead", %{conn: conn} do
      user = insert_verified_user()

      sign = fn ->
        Phoenix.Token.sign(
          FountainWeb.Endpoint,
          "password_reset",
          {user.id, user.session_version}
        )
      end

      earlier_token = sign.()
      used_token = sign.()

      assert redirected_to(
               post(conn, ~p"/auth/reset", %{
                 "token" => used_token,
                 "password" => "newpassword123"
               })
             ) == ~p"/auth/login"

      conn =
        post(conn, ~p"/auth/reset", %{"token" => earlier_token, "password" => "otherpass123"})

      assert redirected_to(conn) == ~p"/auth/forgot-password"
    end

    test "legacy bare-user_id tokens are refused", %{conn: conn} do
      user = insert_verified_user()
      legacy = Phoenix.Token.sign(FountainWeb.Endpoint, "password_reset", user.id)

      conn = post(conn, ~p"/auth/reset", %{"token" => legacy, "password" => "newpassword123"})
      assert redirected_to(conn) == ~p"/auth/forgot-password"
    end

    test "returns 422 with error json when token and password are both missing", %{conn: conn} do
      conn =
        conn
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> post(~p"/auth/reset", Jason.encode!(%{}))

      assert json_response(conn, 422)["error"] == "token and password are required"
    end
  end
end
