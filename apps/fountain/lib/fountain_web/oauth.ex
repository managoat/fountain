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

  @doc """
  The origin of GitHub's authorize page (`https://github.com` unless the
  strategy's `authorize_url` is overridden), or `nil` when it has none.
  """
  @spec github_authorize_origin() :: String.t() | nil
  def github_authorize_origin do
    url =
      Application.get_env(:ueberauth, Ueberauth.Strategy.Github.OAuth, [])[:authorize_url] ||
        "https://github.com/login/oauth/authorize"

    case URI.parse(url) do
      %URI{scheme: scheme, host: host, port: port}
      when scheme in ["http", "https"] and is_binary(host) ->
        if port == URI.default_port(scheme),
          do: "#{scheme}://#{host}",
          else: "#{scheme}://#{host}:#{port}"

      _ ->
        nil
    end
  end
end
