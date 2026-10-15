defmodule FountainWeb.OAuth do
  @moduledoc """
  Runtime checks for optional OAuth providers.
  """

  @doc """
  Whether GitHub OAuth is usable — a non-empty client id is configured.

  The login and registration templates hide the "Continue with GitHub" button
  behind this check: on an install without a GitHub OAuth app the button
  dead-ends on a GitHub-side error page, so it should not render at all (#336).

  Read at render time, not compiled in, so it reflects the runtime env
  (`GITHUB_OAUTH_CLIENT_ID` via `config/runtime.exs`).
  """
  def github_configured? do
    :ueberauth
    |> Application.get_env(Ueberauth.Strategy.Github.OAuth, [])
    |> github_configured?()
  end

  @doc """
  Same check against an explicit provider config (a keyword list or nil).
  """
  def github_configured?(config) do
    case config[:client_id] do
      id when is_binary(id) and id != "" -> true
      _ -> false
    end
  end
end
