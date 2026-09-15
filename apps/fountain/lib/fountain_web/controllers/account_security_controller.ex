defmodule FountainWeb.AccountSecurityController do
  @moduledoc """
  Credential management for a logged-in user (#448).

  The forms live on `AccountSecurityLive`, but the actions are controller
  POSTs, for two reasons a LiveView handler can't satisfy: `change_password/2`
  must rewrite the session cookie (the password change bumps
  `session_version`, and only a controller can re-issue the session so the
  *current* browser survives while every other session dies), and both
  actions want `FountainWeb.Plugs.RateLimit`, which is a plug.

  `confirm_email_change/2` is public (no session): the link lands from an
  inbox, possibly in a browser that has never seen this app.
  """

  use FountainWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Fountain.Accounts
  alias FountainWeb.Schemas

  plug FountainWeb.Plugs.RateLimit,
       [bucket: "account_security", max: 10, window_ms: 3_600_000]
       when action in [
              :change_password,
              :request_email_change,
              :api_change_password,
              :api_request_email_change
            ]

  tags(["Auth"])

  # Browser form POSTs and the emailed confirmation link — not API routes.
  operation(:change_password, false)
  operation(:request_email_change, false)
  operation(:confirm_email_change, false)

  def change_password(conn, %{"current_password" => current, "new_password" => new}) do
    user = conn.assigns.current_user

    case Accounts.change_password(user, current, new, FountainWeb.Audited.attribution(conn)) do
      {:ok, updated} ->
        conn
        # Re-issue this session against the bumped session_version: the
        # change kills every OTHER session, not the one that made it.
        |> configure_session(renew: true)
        |> put_session(:user_id, updated.id)
        |> put_session(:session_version, updated.session_version)
        |> put_flash(:info, "Password updated. Other sessions have been signed out.")
        |> redirect(to: ~p"/account/security")

      {:error, :invalid_current_password} ->
        conn
        |> put_flash(:error, "Current password is incorrect.")
        |> redirect(to: ~p"/account/security")

      {:error, :no_password} ->
        conn
        |> put_flash(:error, "This account signs in with GitHub and has no password.")
        |> redirect(to: ~p"/account/security")

      {:error, %Ecto.Changeset{} = changeset} ->
        msg =
          changeset
          |> Ecto.Changeset.traverse_errors(fn {m, _} -> m end)
          |> Map.get(:password, ["Could not update password."])
          |> List.first()

        conn
        |> put_flash(:error, "New password: #{msg}")
        |> redirect(to: ~p"/account/security")
    end
  end

  def change_password(conn, _params) do
    conn
    |> put_flash(:error, "Current and new password are required.")
    |> redirect(to: ~p"/account/security")
  end

  def request_email_change(conn, %{"new_email" => new_email, "current_password" => current}) do
    user = conn.assigns.current_user

    case Accounts.request_email_change(user, new_email, current) do
      :ok ->
        FountainWeb.Audited.from_conn(conn, "auth.email.change_requested", "user",
          user_id: user.id,
          resource_id: user.id,
          metadata: %{"new_email" => String.downcase(String.trim(new_email))}
        )

        conn
        # Same phrasing whether or not the address was free — this endpoint
        # must not be an availability oracle.
        |> put_flash(
          :info,
          "If that address is available, a confirmation link is on its way to it. " <>
            "Your email only changes when the link is clicked."
        )
        |> redirect(to: ~p"/account/security")

      {:error, :invalid_current_password} ->
        conn
        |> put_flash(:error, "Current password is incorrect.")
        |> redirect(to: ~p"/account/security")

      {:error, :no_password} ->
        conn
        |> put_flash(:error, "This account signs in with GitHub and has no password.")
        |> redirect(to: ~p"/account/security")

      {:error, :invalid_email} ->
        conn
        |> put_flash(:error, "That doesn't look like an email address.")
        |> redirect(to: ~p"/account/security")

      {:error, :same_email} ->
        conn
        |> put_flash(:error, "That is already your email address.")
        |> redirect(to: ~p"/account/security")
    end
  end

  def request_email_change(conn, _params) do
    conn
    |> put_flash(:error, "New email and current password are required.")
    |> redirect(to: ~p"/account/security")
  end

  @doc """
  Change the password over JSON (#521).

  Requires the current password, exactly like the browser path: a stolen
  bearer token must not be enough to set a new one.

  ## What this does and does not invalidate

  `change_password/3` bumps `session_version`, which kills every browser
  session. It does **not** revoke API keys — those are separate credentials
  with their own hashes and expiries, and always have been. This endpoint
  keeps that behaviour rather than quietly diverging from the browser path,
  and says so in the response: a caller rotating a password because
  something leaked has to revoke keys explicitly at
  `DELETE /api/auth/api-keys/:id`.

  Behind the `full`-scope gate: the per-conversation token a sandbox holds
  must not be able to rotate the account password.
  """
  operation(:api_change_password,
    summary: "Change the account password",
    description:
      "Needs the current password on top of the bearer token, and `full` " <>
        "scope — a sandbox's per-conversation token must not be able to " <>
        "rotate the account password. Browser sessions are signed out; API " <>
        "keys are **not** revoked, which the response states outright " <>
        "(`api_keys_revoked: false`). If you are rotating because something " <>
        "leaked, revoke keys yourself at `DELETE /api/auth/api-keys/{id}`.",
    request_body:
      {"Current and new password", "application/json", Schemas.PasswordChangeRequest,
       required: true},
    responses: [
      ok: {"Password changed", "application/json", Schemas.PasswordChangeResponse},
      unauthorized: {"Missing or invalid key", "application/json", Schemas.Error},
      forbidden:
        {"`invalid_current_password`, or a key without full scope", "application/json",
         Schemas.Error},
      unprocessable_entity:
        {"`no_password` (OAuth-only account), missing fields, or a password that fails validation",
         "application/json", Schemas.Error}
    ]
  )

  def api_change_password(conn, %{"current_password" => current, "new_password" => new}) do
    user = conn.assigns.current_user

    case Accounts.change_password(user, current, new, FountainWeb.Audited.attribution(conn)) do
      {:ok, _updated} ->
        json(conn, %{
          message: "Password updated. Browser sessions have been signed out.",
          sessions_invalidated: true,
          api_keys_revoked: false
        })

      {:error, :invalid_current_password} ->
        credential_error(
          conn,
          :forbidden,
          "invalid_current_password",
          "Current password is incorrect."
        )

      {:error, :no_password} ->
        credential_error(
          conn,
          :unprocessable_entity,
          "no_password",
          "This account signs in with GitHub and has no password. Use the reset flow to set one."
        )

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> put_view(FountainWeb.ChangesetJSON)
        |> render(:error, changeset: changeset)
    end
  end

  def api_change_password(conn, _params) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: "current_password and new_password are required"})
  end

  @doc """
  Start an email change over JSON (#521). Sends the confirmation link; the
  address only changes when the token comes back to
  `POST /api/auth/email/confirm`.
  """
  operation(:api_request_email_change,
    summary: "Start an email change",
    description:
      "Sends a confirmation link to the new address; the address only changes " <>
        "when that token comes back to `POST /api/auth/email/confirm`. The " <>
        "response is identical whether or not the address was free — this is " <>
        "not an availability oracle. Requires the current password and `full` scope.",
    request_body:
      {"New address and current password", "application/json", Schemas.EmailChangeRequest,
       required: true},
    responses: [
      ok:
        {"Confirmation link sent (if the address was available)", "application/json",
         Schemas.MessageResponse},
      unauthorized: {"Missing or invalid key", "application/json", Schemas.Error},
      forbidden:
        {"`invalid_current_password`, or a key without full scope", "application/json",
         Schemas.Error},
      unprocessable_entity:
        {"`no_password`, `invalid_email`, `same_email`, or missing fields", "application/json",
         Schemas.Error}
    ]
  )

  def api_request_email_change(conn, %{"new_email" => new_email, "current_password" => current}) do
    user = conn.assigns.current_user

    case Accounts.request_email_change(user, new_email, current) do
      :ok ->
        FountainWeb.Audited.from_conn(conn, "auth.email.change_requested", "user",
          user_id: user.id,
          resource_id: user.id,
          metadata: %{"new_email" => String.downcase(String.trim(new_email))}
        )

        # Same response whether or not the address was free — this endpoint
        # must not be an availability oracle, the same rule the browser path
        # follows.
        json(conn, %{
          message:
            "If that address is available, a confirmation link is on its way to it. " <>
              "Your email only changes when that link is used."
        })

      {:error, :invalid_current_password} ->
        credential_error(
          conn,
          :forbidden,
          "invalid_current_password",
          "Current password is incorrect."
        )

      {:error, :no_password} ->
        credential_error(
          conn,
          :unprocessable_entity,
          "no_password",
          "This account signs in with GitHub and has no password."
        )

      {:error, :invalid_email} ->
        credential_error(
          conn,
          :unprocessable_entity,
          "invalid_email",
          "That doesn't look like an email address."
        )

      {:error, :same_email} ->
        credential_error(
          conn,
          :unprocessable_entity,
          "same_email",
          "That is already your email address."
        )
    end
  end

  def api_request_email_change(conn, _params) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: "new_email and current_password are required"})
  end

  defp credential_error(conn, status, error, message) do
    conn
    |> put_status(status)
    |> json(%{error: error, message: message})
  end

  @doc """
  JSON completion of the email change (#522). Same token as the emailed
  browser link; no session is touched, because an API client has none.
  """
  operation(:api_confirm_email_change,
    summary: "Complete a pending email change",
    description:
      "Public: the token arrives in an inbox, and the caller may hold no " <>
        "credential for the account at all. Applying it bumps " <>
        "`session_version`, so every session and every API key session for " <>
        "the account is dead afterwards — the response says so rather than " <>
        "letting the caller discover it as a mystery 401.",
    security: [],
    request_body: {"The emailed token", "application/json", Schemas.TokenRequest, required: true},
    responses: [
      ok: {"Email changed", "application/json", Schemas.EmailChangedResponse},
      unprocessable_entity:
        {"`email_taken`, `expired`, `invalid_token`, or a missing token", "application/json",
         Schemas.Error}
    ]
  )

  def api_confirm_email_change(conn, %{"token" => token}) do
    case Accounts.apply_email_change(token) do
      {:ok, updated, old_email} ->
        FountainWeb.Audited.from_conn(conn, "auth.email.changed", "user",
          user_id: updated.id,
          resource_id: updated.id,
          metadata: %{"from" => old_email, "to" => updated.email}
        )

        # apply_email_change bumps session_version, so every session and API
        # key session for this account is dead — say so rather than let the
        # caller discover it as a mystery 401.
        json(conn, %{
          email: updated.email,
          message: "Email updated. Existing sessions have been signed out."
        })

      {:error, :email_taken} ->
        email_change_error(conn, "email_taken", "That address is already in use.")

      {:error, :expired} ->
        email_change_error(conn, "expired", "This confirmation link has expired.")

      {:error, _} ->
        email_change_error(conn, "invalid_token", "This confirmation link is invalid.")
    end
  end

  def api_confirm_email_change(conn, _params) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: "token is required"})
  end

  defp email_change_error(conn, error, message) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: error, message: message})
  end

  def confirm_email_change(conn, %{"token" => token}) do
    case Accounts.apply_email_change(token) do
      {:ok, updated, old_email} ->
        FountainWeb.Audited.from_conn(conn, "auth.email.changed", "user",
          user_id: updated.id,
          resource_id: updated.id,
          metadata: %{"from" => old_email, "to" => updated.email}
        )

        conn
        # apply_email_change bumped session_version — every session is dead,
        # including any in this browser. A clean sign-in is the honest next
        # step.
        |> configure_session(drop: true)
        |> put_flash(:info, "Email updated to #{updated.email}. Please sign in.")
        |> redirect(to: ~p"/auth/login")

      {:error, :email_taken} ->
        conn
        |> put_flash(:error, "That address is no longer available.")
        |> redirect(to: ~p"/auth/login")

      {:error, :expired} ->
        conn
        |> put_flash(:error, "This confirmation link has expired. Request the change again.")
        |> redirect(to: ~p"/auth/login")

      {:error, :invalid} ->
        conn
        |> put_flash(:error, "This confirmation link is invalid.")
        |> redirect(to: ~p"/auth/login")
    end
  end
end
