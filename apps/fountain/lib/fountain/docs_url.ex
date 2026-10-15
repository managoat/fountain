defmodule Fountain.DocsUrl do
  @moduledoc """
  Where the manual is published (`DOCS_URL`, `config :fountain, :docs_url`).

  The server does not serve the manual; it is a static build in `site/`,
  published from `main` at `https://managoat.com` (decisions/0081).
  `FountainWeb.DocsRedirectController` and `FountainWeb.HelpRedirectController`
  send readers there.
  """

  @default "https://managoat.com"

  @doc "The base URL, without a trailing slash."
  @spec base() :: String.t()
  def base do
    :fountain |> Application.get_env(:docs_url, @default) |> String.trim_trailing("/")
  end

  @doc """
  `path` (and `query`, when there is one) on the base: `url("/docs/api")` is
  `https://managoat.com/docs/api`.
  """
  @spec url(String.t(), String.t()) :: String.t()
  def url("/" <> _ = path, query \\ "") do
    case query do
      "" -> base() <> path
      query -> base() <> path <> "?" <> query
    end
  end
end
