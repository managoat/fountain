defmodule Fountain.Brand do
  @moduledoc """
  The name this deployment goes by.

  Fountain is the engine: the CLI, the API, the SDK, the env vars and the
  manual all carry its name, and none of that changes per deployment. What an
  operator may change is what the *chrome* says: the sidebar header, the
  `<title>`, the sign-in page, the OAuth consent screen and the subject line of
  every email (`PRODUCT_NAME`), and the icons and card those pages show
  (`BRAND_ASSETS_URL`).
  """

  @engine "Fountain"

  @doc """
  The deployment's brand: `PRODUCT_NAME`, or `"Fountain"` when unset or blank.
  """
  @spec name() :: String.t()
  def name do
    case Application.get_env(:fountain, :product_name) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> @engine
          trimmed -> trimmed
        end

      _ ->
        @engine
    end
  end

  # The files a brand supplies, and nothing else: the console header and the
  # public chrome use the app icon, the root layout links the favicons and
  # the touch icon, and every Open Graph card carries the 1200×630 card. The
  # names are fixed so that a bundle is a directory with these six files in
  # it, whatever brand it is for.
  @assets ~w(app-icon.png apple-touch-icon.png favicon-32x32.png favicon-16x16.png favicon.ico og-card.png)

  @doc "The six files a brand asset bundle holds."
  @spec assets() :: [String.t()]
  def assets, do: @assets

  @doc """
  The base URL of this deployment's brand assets (`BRAND_ASSETS_URL`, no
  trailing slash), or `nil` when the deployment uses the built-in files.

  The icon and the card are pixels, and pixels do not belong in an env var
  the way a name does — but they do not belong in the release image either,
  where swapping them means a rebuild of the engine for a change to the
  chrome. A deployment points this at a directory it serves (any static host
  will do) holding `assets/0`; the engine's own files stay the default.
  """
  @spec assets_url() :: String.t() | nil
  def assets_url do
    case Application.get_env(:fountain, :brand_assets_url) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> String.trim_trailing(trimmed, "/")
        end

      _ ->
        nil
    end
  end

  @doc """
  Where one of `assets/0` is served from: an absolute URL under
  `assets_url/0` when a bundle is configured, else the built-in path the
  release serves from `priv/static`.
  """
  @spec asset(String.t()) :: String.t()
  def asset(name) when name in @assets do
    case assets_url() do
      nil -> builtin(name)
      base -> base <> "/" <> name
    end
  end

  @doc """
  The origin a brand bundle is served from, for the CSP's `img-src`, or `nil`
  when the built-in files (same origin) are in use.
  """
  @spec assets_origin() :: String.t() | nil
  def assets_origin do
    case assets_url() do
      nil ->
        nil

      base ->
        case URI.parse(base) do
          %URI{scheme: scheme, host: host, port: port} when is_binary(host) ->
            origin = "#{scheme}://#{host}"
            if port in [nil, URI.default_port(scheme)], do: origin, else: "#{origin}:#{port}"

          _ ->
            nil
        end
    end
  end

  defp builtin("favicon.ico"), do: "/favicon.ico"
  defp builtin(name), do: "/images/" <> name
end
