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
    # A cancelled trip still spends the access-code grant.
    {conn, _access_code} = FountainWeb.RegistrationGrant.take(conn)

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
    # Put there by RegistrationController.oauth/2 when the instance asks for
    # an access code. Taken before anything can refuse, so it is spent
    # whatever the outcome.
    {conn, access_code} = FountainWeb.RegistrationGrant.take(conn)
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
        do_callback(conn, provider, provider_uid, email, access_code)
    end
  end

  defp do_callback(conn, provider, provider_uid, email, access_code) do
    attrs = %{"email" => email, "access_code" => access_code}

    case Fountain.Accounts.upsert_oauth_user(provider, provider_uid, attrs) do
      {:ok, user, :new} ->
        FountainWeb.Audited.from_conn(conn, "auth.oauth.signup", "user",
          user_id: user.id,
          metadata: %{"provider" => provider}
        )

        # The email+password path does this after verification. OAuth skips
        # verification entirely (the provider asserts the address), so without
        # this a GitHub signup would start with no opening credit.
        Fountain.Credits.grant_opening(user)

        # Same reasoning for the welcome email (#449): an OAuth signup is
        # created verified, so this is its verification transition.
        Fountain.Workers.WelcomeEmail.enqueue(user)

        # And the same landing (ADR 0038). An OAuth signup is created verified,
        # so this *is* its first screen after verification; sending it to the
        # dashboard instead would give one of the two signup doors a different
        # first hour.
        conn
        |> configure_session(renew: true)
        |> put_session(:user_id, user.id)
        |> put_session(:session_version, user.session_version)
        |> redirect(to: ~p"/start")

      {:ok, user, :existing} ->
        if Fountain.Accounts.suspended?(user) do
          # Same neutral refusal as password login (#287): the provider
          # asserted the identity, but a suspended account gets no session.
          FountainWeb.Audited.from_conn(conn, "auth.login.failed", "session",
            user_id: user.id,
            metadata: %{"provider" => provider, "reason" => "suspended"}
          )

          conn
          |> put_flash(
            :error,
            "This account is currently unavailable. Contact support if you believe this is an error."
          )
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

      {:error, :access_code_required} ->
        conn
        |> put_flash(
          :error,
          "Signup on this instance needs an access code. Enter it here, then continue with GitHub."
        )
        |> redirect(to: ~p"/auth/register")

      {:error, reason} when reason in [:registration_closed, :email_domain_not_allowed] ->
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
