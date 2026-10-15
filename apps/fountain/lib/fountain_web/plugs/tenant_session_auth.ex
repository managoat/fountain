defmodule FountainWeb.Plugs.TenantSessionAuth do
  @moduledoc """
  Browser pipeline auth: reads `user_id` and `session_version` from the
  session cookie, loads the user, validates `session_version` matches (so
  password resets invalidate existing sessions), and sets
  `conn.assigns.current_user`.

  Redirects to `/auth/login` if the session is absent or stale, or if the
  account has not verified its email.

  Login already refuses an unverified account, so that last check is the
  backstop for a session that predates the refusal. It used to live only in
  the LiveView hook (#533), which left every controller route in this
  pipeline reachable by an unverified session. Such a session is cleared, not
  kept: the login page says what to do next.
  """

  import Plug.Conn
  import Phoenix.Controller, only: [redirect: 2, put_flash: 3]

  use FountainWeb, :verified_routes

  alias Fountain.Accounts

  def init(opts), do: opts

  def call(conn, _opts) do
    user_id = get_session(conn, :user_id)
    session_version = get_session(conn, :session_version)

    with true <- is_binary(user_id),
         true <- is_integer(session_version),
         %Accounts.User{} = user <- Accounts.get_user(user_id),
         true <- user.session_version == session_version do
      if is_nil(user.email_verified_at) do
        # Cleared and renewed rather than dropped: a dropped session takes
        # the flash with it, and the flash is the whole explanation.
        conn
        |> clear_session()
        |> configure_session(renew: true)
        |> put_flash(:error, FountainWeb.SessionController.unverified_message())
        |> redirect(to: ~p"/auth/login")
        |> halt()
      else
        assign(conn, :current_user, user)
      end
    else
      _ ->
        conn
        |> maybe_stash_return_to()
        |> redirect(to: ~p"/auth/login")
        |> halt()
    end
  end

  # A GET that needed a session comes back to the same path + query after
  # login — the pattern ReturnTo established for the OAuth consent page
  # (#818), needed here for /device?code=… (#1305): the CLI keeps polling
  # while the human signs in, so losing the destination strands both. POSTs
  # are not stashed: the post-login redirect is a GET, and replaying a POST
  # path as one lands nowhere.
  defp maybe_stash_return_to(%Plug.Conn{method: "GET"} = conn),
    do: FountainWeb.ReturnTo.stash(conn)

  defp maybe_stash_return_to(conn), do: conn
end
