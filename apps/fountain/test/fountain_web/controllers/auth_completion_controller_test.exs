defmodule FountainWeb.AuthCompletionControllerTest do
  @moduledoc """
  Finishing the auth email flows over JSON (#522).

  An API consumer could *start* every one of these — register,
  resend-verification, forgot — and finish none of them: confirmation and
  reset were browser routes. Account activation required a browser round-trip,
  which is the one step a headless bootstrap cannot fake.

  The emailed links still point at the browser routes. These endpoints accept
  the same tokens, so a CLI can say "paste the code from your email".
  """

  use FountainWeb.ConnCase, async: true

  alias Fountain.Accounts

  defp verification_token(user),
    do: Phoenix.Token.sign(FountainWeb.Endpoint, "email_verification", user.id)

  defp reset_token(user),
    do:
      Phoenix.Token.sign(
        FountainWeb.Endpoint,
        "password_reset",
        {user.id, user.session_version}
      )

  defp json_post(conn, path, payload) do
    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "application/json")
    |> post(path, Jason.encode!(payload))
  end

  describe "POST /api/auth/verify" do
    test "verifies an account without a browser", %{conn: conn} do
      user = insert_user()

      body =
        conn
        |> json_post("/api/auth/verify", %{"token" => verification_token(user)})
        |> json_response(200)

      assert body["user_id"] == user.id
      assert body["email_verified"] == true
      assert Accounts.get_user(user.id).email_verified_at
    end

    test "issues no session — an API client wants a key, not a cookie", %{conn: conn} do
      user = insert_user()

      conn = json_post(conn, "/api/auth/verify", %{"token" => verification_token(user)})

      assert json_response(conn, 200)
      assert conn.resp_cookies == %{}
    end

    test "records the audit event the browser route records", %{conn: conn} do
      user = insert_user()

      conn
      |> json_post("/api/auth/verify", %{"token" => verification_token(user)})
      |> json_response(200)

      events = Fountain.Audit.list_recent_for_user(user.id, 50)
      assert event = Enum.find(events, &(&1.action == "auth.email.verified"))

      # This route is `:api_public`, so nothing has authenticated and derived
      # attribution would say "system" — of a CLI finishing a signup. The
      # actor is stated instead (ADR 0013).
      assert event.actor == "api"
    end

    test "is idempotent — a retried request is not an error", %{conn: conn} do
      user = insert_verified_user()

      body =
        conn
        |> json_post("/api/auth/verify", %{"token" => verification_token(user)})
        |> json_response(200)

      assert body["email_verified"] == true
    end

    test "a garbage token is 422, not a 500", %{conn: conn} do
      body = conn |> json_post("/api/auth/verify", %{"token" => "nonsense"}) |> json_response(422)
      assert body["error"] == "invalid_token"
    end

    test "a missing token is 422", %{conn: conn} do
      conn |> json_post("/api/auth/verify", %{}) |> json_response(422)
    end

    test "a token for a deleted user is invalid, not a crash", %{conn: conn} do
      user = insert_user()
      token = verification_token(user)
      {:ok, _} = Fountain.Repo.delete(user)

      body = conn |> json_post("/api/auth/verify", %{"token" => token}) |> json_response(422)
      assert body["error"] == "invalid_token"
    end
  end

  describe "POST /api/auth/reset" do
    setup do
      {:ok, user: insert_verified_user(%{"password" => "old-password-123"})}
    end

    test "resets the password", %{conn: conn, user: user} do
      conn
      |> json_post("/api/auth/reset", %{
        "token" => reset_token(user),
        "password" => "brand-new-password"
      })
      |> json_response(200)

      assert {:ok, _} = Accounts.authenticate_user(user.email, "brand-new-password")
      assert {:error, _} = Accounts.authenticate_user(user.email, "old-password-123")
    end

    test "the token is single-use", %{conn: conn, user: user} do
      token = reset_token(user)

      conn
      |> json_post("/api/auth/reset", %{"token" => token, "password" => "first-new-password"})
      |> json_response(200)

      # session_version moved, so the token that just worked must not work
      # again — the whole point of carrying it inside the token (#325).
      body =
        build_conn()
        |> json_post("/api/auth/reset", %{"token" => token, "password" => "second-password"})
        |> json_response(422)

      assert body["error"] == "invalid_token"
      assert {:ok, _} = Accounts.authenticate_user(user.email, "first-new-password")
    end

    test "a weak password is a changeset error, and the password is unchanged", %{
      conn: conn,
      user: user
    } do
      body =
        conn
        |> json_post("/api/auth/reset", %{"token" => reset_token(user), "password" => "short"})
        |> json_response(422)

      assert body["errors"]["password"]
      assert {:ok, _} = Accounts.authenticate_user(user.email, "old-password-123")
    end

    test "records the audit event", %{conn: conn, user: user} do
      conn
      |> json_post("/api/auth/reset", %{"token" => reset_token(user), "password" => "a-new-one-1"})
      |> json_response(200)

      actions = Fountain.Audit.list_recent_for_user(user.id, 50) |> Enum.map(& &1.action)
      assert "auth.password.reset" in actions
    end

    test "a garbage token is 422", %{conn: conn} do
      body =
        conn
        |> json_post("/api/auth/reset", %{"token" => "nope", "password" => "whatever-123"})
        |> json_response(422)

      assert body["error"] == "invalid_token"
    end

    test "missing params are 422", %{conn: conn} do
      conn |> json_post("/api/auth/reset", %{"token" => "x"}) |> json_response(422)
    end
  end
end
