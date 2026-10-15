defmodule FountainWeb.UeberauthController do
  @moduledoc """
  Handles Ueberauth OAuth requests and callbacks.

  Routes:
    GET /auth/oauth/:provider           — request (Ueberauth redirects to provider)
    GET /auth/oauth/:provider/callback  — callback (Ueberauth populates assigns)

  Currently only GitHub is wired (ueberauth_github strategy).
  """

  use FountainWeb, :controller

  # Ueberauth's plug handles the request phase (redirect to the provider)
  # and the callback phase (parse the response into assigns). It MUST be
  # in the controller's plug pipeline — otherwise `request/2` is hit
  # directly and falls through to the "Unknown OAuth provider" branch.
  # The `base_path` in config/config.exs must match the route prefix
  # (`/auth/oauth`) for the plug to recognize the path.
  #
  # In test mode, the plug is skipped so that tests can assign
  # :ueberauth_auth / :ueberauth_failure directly without triggering a real
  # OAuth network round-trip.
  unless Application.compile_env(:fountain, :ueberauth_test_mode, false) do
    plug Ueberauth
  end

  # Only fires if Ueberauth passes through (unknown / unconfigured provider).
  def request(conn, _params) do
    conn
    |> put_flash(:error, "Unknown OAuth provider.")
    |> redirect(to: ~p"/auth/login")
  end

  # On success Ueberauth sets `conn.assigns.ueberauth_auth`.
  # On failure it sets `conn.assigns.ueberauth_failure`.
  def callback(%{assigns: %{ueberauth_failure: failure}} = conn, _params) do
    reason =
      case failure.errors do
        [%{message: msg} | _] when is_binary(msg) -> msg
        _ -> "Authentication failed."
      end

    conn
    |> put_flash(:error, reason)
    |> redirect(to: ~p"/auth/login")
  end

  def callback(%{assigns: %{ueberauth_auth: auth}} = conn, _params) do
    provider = to_string(auth.provider)
    provider_uid = to_string(auth.uid)
    # Not `auth.info.email`: that address can be a GitHub primary that has never
    # been confirmed, and upsert_oauth_user/3 links any matching address to an
    # existing account. See FountainWeb.OauthEmail.
    case FountainWeb.OauthEmail.verified_email(auth) do
      {:error, reason} ->
        FountainWeb.Audited.from_conn(conn, "auth.oauth.rejected", "user",
          metadata: %{"provider" => provider, "reason" => to_string(reason)}
        )

        conn
        |> put_flash(:error, FountainWeb.OauthEmail.explain(reason))
        |> redirect(to: ~p"/auth/login")

      {:ok, email} ->
        do_callback(conn, provider, provider_uid, email)
    end
  end

  defp do_callback(conn, provider, provider_uid, email) do
    case Fountain.Accounts.upsert_oauth_user(provider, provider_uid, %{"email" => email}) do
      {:ok, user, :new} ->
        FountainWeb.Audited.from_conn(conn, "auth.oauth.signup", "user",
          user_id: user.id,
          metadata: %{"provider" => provider}
        )

        conn
        |> configure_session(renew: true)
        |> put_session(:user_id, user.id)
        |> put_session(:session_version, user.session_version)
        |> redirect(to: ~p"/dashboard")

      {:ok, user, :existing} ->
        if is_nil(user.email_verified_at) do
          # An unconfirmed email+password account this identity was linked
          # to: the same refusal as password login, so a session for an
          # unverified account is never issued.
          FountainWeb.Audited.from_conn(conn, "auth.login.failed", "session",
            user_id: user.id,
            metadata: %{"provider" => provider, "reason" => "unverified"}
          )

          conn
          |> put_flash(:error, FountainWeb.SessionController.unverified_message())
          |> redirect(to: ~p"/auth/login")
        else
          FountainWeb.Audited.from_conn(conn, "auth.oauth.login", "user",
            user_id: user.id,
            metadata: %{"provider" => provider}
          )

          {conn, path} = FountainWeb.ReturnTo.pop(conn, ~p"/dashboard")

          conn
          |> configure_session(renew: true)
          |> put_session(:user_id, user.id)
          |> put_session(:session_version, user.session_version)
          |> redirect(to: path)
        end

      {:error, :registration_closed} ->
        conn
        |> put_flash(:error, "Registration is not open on this instance.")
        |> redirect(to: ~p"/auth/login")

      {:error, _changeset} ->
        conn
        |> put_flash(:error, "Could not sign in with GitHub. Please try again.")
        |> redirect(to: ~p"/auth/login")
    end
  end
end
