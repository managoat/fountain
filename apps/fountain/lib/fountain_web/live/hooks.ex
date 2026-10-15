defmodule FountainWeb.Live.Hooks do
  @moduledoc """
  LiveView `on_mount` hooks for authentication and the admin gate.

  ## Usage in router live_session

      live_session :authenticated,
        on_mount: [{FountainWeb.Live.Hooks, :require_authenticated_user}] do
        live "/dashboard", DashboardLive, :index
      end

  ## Hooks

  - `:require_authenticated_user` — halts and redirects to login if no
    current_user is set or the user's email is unverified. Login refuses an
    unverified account, so a session for one should not exist; this is the
    backstop.
  - `:require_admin` — halts if current_user is absent or not an admin.
    Unauthenticated users are redirected to login (HTTP redirect). Authenticated
    non-admin users are redirected to /dashboard (live redirect).
  """

  import Phoenix.LiveView
  import Phoenix.Component, only: [assign: 3, assign_new: 3]

  use FountainWeb, :verified_routes

  alias Fountain.Accounts

  def on_mount(:require_authenticated_user, _params, session, socket) do
    socket = mount_current_user(session, socket)
    user = socket.assigns[:current_user]

    cond do
      is_nil(user) ->
        {:halt, redirect(socket, to: ~p"/auth/login")}

      # Login refuses an unverified account (it says why on the login page),
      # so this only catches a session that predates that refusal.
      is_nil(user.email_verified_at) ->
        {:halt, redirect(socket, to: ~p"/auth/login")}

      true ->
        {:cont,
         socket
         |> FountainWeb.Audited.put_client_ip()
         |> track_current_path()}
    end
  end

  def on_mount(:require_admin, _params, session, socket) do
    socket = mount_current_user(session, socket)
    user = socket.assigns[:current_user]

    cond do
      is_nil(user) ->
        {:halt, redirect(socket, to: ~p"/auth/login")}

      # Not reachable today — the router always pairs this hook after
      # :require_authenticated_user, which already refused. Checked anyway
      # because this hook mounts current_user itself, so it is a complete
      # gate on paper, and a future live_session using it alone would
      # otherwise admit an unverified admin (#533).
      is_nil(user.email_verified_at) ->
        {:halt, redirect(socket, to: ~p"/auth/login")}

      user.role != "admin" ->
        {:halt, push_navigate(socket, to: ~p"/dashboard")}

      true ->
        {:cont, socket}
    end
  end

  # Mount current_user from session into socket assigns without hitting the
  # DB a second time if it was already assigned (e.g. from a previous hook).
  defp mount_current_user(session, socket) do
    assign_new(socket, :current_user, fn ->
      user_id = Map.get(session, "user_id")
      session_version = Map.get(session, "session_version")

      with true <- is_binary(user_id),
           true <- is_integer(session_version),
           %Accounts.User{} = user <- Accounts.get_user(user_id),
           true <- user.session_version == session_version do
        user
      else
        _ -> nil
      end
    end)
  end

  # The shared layout reads @current_path to highlight the active nav item.
  # Seed it with "/" for the initial render and update it from the URI on
  # every handle_params (LiveView navigation).
  defp track_current_path(socket) do
    socket
    |> assign_new(:current_path, fn -> "/" end)
    |> Phoenix.LiveView.attach_hook(:current_path, :handle_params, fn _params, uri, socket ->
      {:cont, assign(socket, :current_path, URI.parse(uri).path)}
    end)
  end
end
