defmodule FountainWeb.Plugs.TenantSessionAuth do
  @moduledoc """
  Browser pipeline auth: reads `user_id` and `session_version` from the
  session cookie, loads the user, validates `session_version` matches (so
  password resets invalidate existing sessions), and sets
  `conn.assigns.current_user`.

  Redirects to `/auth/login` if the session is absent or stale, and to
  `/auth/verify-pending` if the account has not verified its email.

  That last check used to live only in the LiveView hook (#533), which left
  every controller route in this pipeline — theme, avatars, turn images, the
  credential POSTs — reachable by an unverified session, and made the gate
  something each new route had to remember rather than something the pipeline
  guaranteed. `/auth/verify-pending` itself is deliberately
  routed outside this pipeline; putting it back inside would loop.
  """

  import Plug.Conn
  import Phoenix.Controller, only: [redirect: 2]

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
        conn
        |> redirect(to: ~p"/auth/verify-pending")
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
