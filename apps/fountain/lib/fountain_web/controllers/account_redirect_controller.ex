defmodule FountainWeb.AccountRedirectController do
  @moduledoc """
  The console pages that became sections of `/account`: `/api-keys`,
  `/account/oauth-apps` and `/account/security`. They are in bookmarks, the
  CLI's hints, sent links and agents' notes, so each redirects to `/account`
  with its section open rather than answering 404.

  The router names the section in the route's `assigns`.
  """
  use FountainWeb, :controller

  def section(%{assigns: %{account_section: section}} = conn, _params)
      when section in ~w(api-keys oauth-apps password) do
    redirect(conn, to: ~p"/account?#{[open: section]}")
  end
end
