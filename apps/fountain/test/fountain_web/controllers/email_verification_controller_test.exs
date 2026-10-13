defmodule FountainWeb.EmailVerificationControllerTest do
  use FountainWeb.ConnCase, async: true
  use Mimic

  alias Fountain.Accounts

  describe "GET /users/confirm/:token" do
    test "verifies email, sets session, and redirects to the verified landing", %{
      conn: conn
    } do
      user = insert_user()
      assert is_nil(user.email_verified_at)

      token = Phoenix.Token.sign(FountainWeb.Endpoint, "email_verification", user.id)
      conn = get(conn, ~p"/users/confirm/#{token}")

      assert redirected_to(conn) == ~p"/dashboard"
      assert get_session(conn, :user_id) == user.id

      # User should be verified in DB
      updated = Accounts.get_user!(user.id)
      refute is_nil(updated.email_verified_at)
    end

    test "attributes the verification to the browser, not to the system", %{conn: conn} do
      # The link is clicked before a session exists, so derivation would report
      # "system" for a person reading their mail. Bare "system" is a defect
      # signal, not an actor (ADR 0013).
      user = insert_user()

      token = Phoenix.Token.sign(FountainWeb.Endpoint, "email_verification", user.id)
      get(conn, ~p"/users/confirm/#{token}")

      event =
        user.id
        |> Fountain.Audit.list_recent_for_user(50)
        |> Enum.find(&(&1.action == "auth.email.verified"))

      assert event, "verifying through the browser route must be audited"
      assert event.actor == "ui"
    end

    test "redirects an already-verified user to the dashboard", %{
      conn: conn
    } do
      user = insert_verified_user()

      token = Phoenix.Token.sign(FountainWeb.Endpoint, "email_verification", user.id)
      conn = get(conn, ~p"/users/confirm/#{token}")

      assert redirected_to(conn) == ~p"/dashboard"
      assert get_session(conn, :user_id) == user.id
    end

    test "redirects with error when user no longer exists in database", %{conn: conn} do
      # Sign a token with a UUID that doesn't correspond to any user
      missing_id = Ecto.UUID.generate()
      token = Phoenix.Token.sign(FountainWeb.Endpoint, "email_verification", missing_id)
      conn = get(conn, ~p"/users/confirm/#{token}")

      assert redirected_to(conn) == ~p"/auth/login"
    end

    test "redirects with error for expired token", %{conn: conn} do
      user = insert_user()

      # Sign the token as if it were issued 2 days ago (> 24h max_age).
      # Phoenix.Token.sign/4 accepts `signed_at:` in seconds.
      two_days_ago = System.system_time(:second) - 2 * 24 * 60 * 60

      token =
        Phoenix.Token.sign(FountainWeb.Endpoint, "email_verification", user.id,
          signed_at: two_days_ago
        )

      conn = get(conn, ~p"/users/confirm/#{token}")

      assert redirected_to(conn) == ~p"/auth/login"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "expired"
    end

    test "redirects with error for invalid token", %{conn: conn} do
      conn = get(conn, ~p"/users/confirm/thisisnotavalidtoken")
      assert redirected_to(conn) == ~p"/auth/login"
    end

    test "redirects with error when verify_email returns an error changeset", %{conn: conn} do
      user = insert_user()

      # Stub Accounts.verify_email/2 to simulate a DB-level failure so that
      # the {:error, _changeset} branch is exercised. Arity 2 since #593: the
      # controller passes attribution through so the context can record
      # `auth.email.verified` itself.
      stub(Accounts, :verify_email, fn _user, _opts ->
        changeset =
          %Fountain.Accounts.User{}
          |> Ecto.Changeset.change()
          |> Ecto.Changeset.add_error(:email, "simulated failure")

        {:error, changeset}
      end)

      token = Phoenix.Token.sign(FountainWeb.Endpoint, "email_verification", user.id)
      conn = get(conn, ~p"/users/confirm/#{token}")

      assert redirected_to(conn) == ~p"/auth/login"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "went wrong"
    end
  end
end
