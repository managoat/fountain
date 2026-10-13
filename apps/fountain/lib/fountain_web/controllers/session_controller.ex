defmodule FountainWeb.SessionController do
  @moduledoc """
  Browser session management.

  HTML routes (email + password):
    GET  /auth/login   — render login form
    POST /auth/login   — authenticate, set session cookie
    GET  /auth/logout  — clear session, redirect to login
  """

  use FountainWeb, :controller

  alias Fountain.Accounts

  # The JSON sibling POST /api/auth/token has been limited to 10/hour since
  # launch; this form had no limit at all, so credential stuffing simply used
  # the HTML endpoint instead. Same bucket name as the JSON path so an attacker
  # cannot get a second allowance by switching surface.
  plug FountainWeb.Plugs.RateLimit,
       [bucket: "auth_token", max: 10, window_ms: 3_600_000]
       when action in [:create]

  ## Email/password login

  def new(conn, _params) do
    render(conn, :new, error: nil, layout: false)
  end

  def create(conn, %{"email" => email, "password" => password}) do
    case Accounts.authenticate_user(email, password) do
      {:ok, user} ->
        FountainWeb.Audited.from_conn(conn, "auth.login", "session",
          user_id: user.id,
          actor: "ui",
          metadata: %{"result" => "ok"}
        )

        conn
        |> configure_session(renew: true)
        |> put_session(:user_id, user.id)
        |> put_session(:session_version, user.session_version)
        |> redirect_after_login(user)

      {:error, reason} ->
        # Failures matter more than successes here: a run of them against one
        # account is the signal you want, and there was no record of any.
        FountainWeb.Audited.from_conn(conn, "auth.login.failed", "session",
          actor: "ui",
          metadata: %{"email" => email, "reason" => to_string(reason)}
        )

        conn
        |> put_status(:unauthorized)
        |> render(:new, error: login_error(reason), layout: false)
    end
  end

  def create(conn, _params) do
    conn
    |> put_status(:unprocessable_entity)
    |> render(:new, error: "Email and password are required.", layout: false)
  end

  def delete(conn, params) do
    # Read before the drop, and off the session rather than assigns: this route
    # is on the plain `:browser` pipeline, so nothing has loaded a
    # `current_user`. A login trail with no logouts cannot reconstruct a
    # session, which is most of what the trail is for (#544).
    #
    # Skipped for the post-deletion redirect below — the account is already
    # gone, and `audit_events.user_id` is nilified with it, so the row would
    # be an orphan claiming a user who no longer exists. `account.deleted`
    # already covers that path.
    user_id = get_session(conn, :user_id)

    if user_id && params["deleted"] != "1" do
      FountainWeb.Audited.from_conn(conn, "auth.logout", "session",
        user_id: user_id,
        actor: "ui"
      )
    end

    conn = configure_session(conn, drop: true)

    # Account deletion redirects here to drop the session, since a LiveView
    # cannot clear the session cookie itself. The confirmation has to be shown
    # after the redirect: by this point there is no account left to show it on.
    if params["deleted"] == "1" do
      conn
      |> put_flash(:info, "Your account and all of its data have been deleted.")
      |> redirect(to: ~p"/auth/login")
    else
      redirect(conn, to: ~p"/auth/login")
    end
  end

  ## Private

  # Neutral on purpose (#287): says the account is unusable without labeling
  # it, and only after the password verified — a guesser never learns state.
  defp login_error(:suspended),
    do: "This account is currently unavailable. Contact support if you believe this is an error."

  defp login_error(_), do: "Invalid email or password."

  # A request that needed a session and did not have one (the OAuth consent
  # page, #818) stashed itself; go back to it. Otherwise the usual landing.
  defp redirect_after_login(conn, user) do
    {conn, path} = FountainWeb.ReturnTo.pop(conn, after_login_path(user))
    redirect(conn, to: path)
  end

  # One landing, whatever the account's state: the console's dashboard says
  # what is still missing (a credential, an agent) without the wizard's
  # taking the account hostage until it is done (#867).
  defp after_login_path(_user), do: ~p"/dashboard"
end
