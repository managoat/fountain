defmodule FountainWeb.AccountSecurityController do
  @moduledoc """
  Password change for a logged-in user (#448).

  The form lives on `AccountSecurityLive`, but the action is a controller
  POST, for two reasons a LiveView handler can't satisfy: `change_password/2`
  must rewrite the session cookie (the password change bumps
  `session_version`, and only a controller can re-issue the session so the
  *current* browser survives while every other session dies), and it wants
  `FountainWeb.Plugs.RateLimit`, which is a plug.

  Self-serve email change was removed on 2026-10-15 (ADR 0011 addendum).
  """

  use FountainWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Fountain.Accounts
  alias FountainWeb.Schemas

  plug FountainWeb.Plugs.RateLimit,
       [bucket: "account_security", max: 10, window_ms: 3_600_000]
       when action in [:change_password, :api_change_password]

  tags(["Auth"])

  # A browser form POST — not an API route.
  operation(:change_password, false)

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

  defp credential_error(conn, status, error, message) do
    conn
    |> put_status(status)
    |> json(%{error: error, message: message})
  end
end
