defmodule FountainWeb.EmailVerificationController do
  @moduledoc """
  Handles the email verification link: GET /users/confirm/:token, and its
  JSON twin POST /api/auth/verify.

  Validates a Phoenix.Token (24 h TTL), marks the user verified, sets
  the session cookie (browser route only), and redirects to onboarding or
  dashboard.

  The API route exists so account activation does not require a browser
  (#522): the emailed link keeps pointing at the browser route, and a CLI
  prompts for the token from that URL. Both routes accept the same token —
  there is one verification secret, not two.

  A successful verification posts the opening credit
  (`Accounts.verify_email/2` → `Credits.grant_opening/2`, ADR 0031) and
  enqueues the welcome email.
  """

  use FountainWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Fountain.Accounts
  alias FountainWeb.Schemas

  # 24 hours in seconds
  @token_max_age 86_400

  tags(["Auth"])

  # `GET /users/confirm/:token` — the emailed browser link, not an API route.
  operation(:confirm, false)

  def confirm(conn, %{"token" => token}) do
    case Phoenix.Token.verify(conn, "email_verification", token, max_age: @token_max_age) do
      {:ok, user_id} ->
        case Accounts.get_user(user_id) do
          nil ->
            conn
            |> put_flash(:error, "That verification link is invalid.")
            |> redirect(to: ~p"/auth/login")

          user when not is_nil(user.email_verified_at) ->
            # Already verified — log in and redirect
            conn
            |> log_in_user(user)
            |> put_flash(:info, "Your email is already verified.")
            |> redirect(to: destination(user))

          user ->
            # Explicit actor: this route runs before a session exists, so
            # derivation would report "system" for a person clicking a link in
            # their mail client (ADR 0013 — bare "system" is a defect signal).
            case Accounts.verify_email(user, FountainWeb.Audited.attribution(conn, actor: "ui")) do
              {:ok, verified_user} ->
                # Durable job rather than a linked Task: this used to be a bare
                # Task.async with no await, so it could be killed when the
                # request process finished and a Stripe error vanished silently,
                # leaving an account with no customer id.

                # Only on this branch, never the already-verified one below —
                # the welcome fires on the verification transition (#449).
                Fountain.Workers.WelcomeEmail.enqueue(verified_user)

                # The verified landing, not the dashboard (ADR 0038): the
                # first screen after verification hands over a key and one
                # request rather than a list of things to go and set up.
                conn
                |> log_in_user(verified_user)
                |> redirect(to: ~p"/start")

              {:error, _changeset} ->
                conn
                |> put_flash(:error, "Something went wrong. Please try again.")
                |> redirect(to: ~p"/auth/login")
            end
        end

      {:error, :expired} ->
        conn
        |> put_flash(:error, "This verification link has expired.")
        |> redirect(to: ~p"/auth/login")

      {:error, _reason} ->
        conn
        |> put_flash(:error, "This verification link is invalid.")
        |> redirect(to: ~p"/auth/login")
    end
  end

  @doc """
  JSON completion of the same flow. Returns 200 on success (and on an
  already-verified account, which is the idempotent case a CLI retrying a
  request needs), 422 on an expired or invalid token.

  No session is issued: an API client wants a key, which it mints at
  `POST /api/auth/token` once the account is live.
  """
  operation(:api_verify,
    summary: "Activate an account from a verification token",
    description:
      "Idempotent: an already-verified account is a 200, which is what a CLI " <>
        "retrying a request needs. No session is issued — mint a key at " <>
        "`POST /api/auth/token` once the account is live. Tokens last 24 hours.",
    security: [],
    request_body: {"The emailed token", "application/json", Schemas.TokenRequest, required: true},
    responses: [
      ok: {"Verified (or already verified)", "application/json", Schemas.VerifyEmailResponse},
      unprocessable_entity:
        {"`expired`, `invalid_token`, or a missing token", "application/json", Schemas.Error}
    ]
  )

  def api_verify(conn, %{"token" => token}) do
    case Phoenix.Token.verify(conn, "email_verification", token, max_age: @token_max_age) do
      {:ok, user_id} -> verify_user(conn, Accounts.get_user(user_id))
      {:error, :expired} -> token_error(conn, "expired", "This verification link has expired.")
      {:error, _} -> token_error(conn, "invalid_token", "This verification link is invalid.")
    end
  end

  def api_verify(conn, _params) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: "token is required"})
  end

  defp verify_user(conn, nil),
    do: token_error(conn, "invalid_token", "This verification link is invalid.")

  defp verify_user(conn, %{email_verified_at: %DateTime{}} = user) do
    json(conn, %{
      user_id: user.id,
      email_verified: true,
      message: "Your email is already verified."
    })
  end

  defp verify_user(conn, user) do
    # `:api_public` — nothing has authenticated yet, so the actor is stated
    # rather than derived. Same caveat as the browser route above.
    case Accounts.verify_email(user, FountainWeb.Audited.attribution(conn, actor: "api")) do
      {:ok, verified} ->
        # Same follow-on work the browser route does — the account must not
        # end up in a different state depending on which surface finished it.
        Fountain.Workers.WelcomeEmail.enqueue(verified)

        json(conn, %{
          user_id: verified.id,
          email_verified: true,
          message: "Email verified. You can sign in now."
        })

      {:error, _changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "verification_failed"})
    end
  end

  defp token_error(conn, error, message) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: error, message: message})
  end

  ## Helpers

  defp log_in_user(conn, user) do
    conn
    |> configure_session(renew: true)
    |> put_session(:user_id, user.id)
    |> put_session(:session_version, user.session_version)
  end

  defp destination(_user), do: ~p"/dashboard"
end
