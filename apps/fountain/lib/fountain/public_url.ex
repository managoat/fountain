defmodule Fountain.PublicUrl do
  @moduledoc """
  Normalisation for the app's externally-visible base URL.

  Two shapes are needed and they are not interchangeable:

    * an absolute, scheme-ful URL for links that leave the app (verification
      and reset emails) and for `MANAGOAT_BASE_URL` inside sprites
    * a bare host for the endpoint `:url` and `check_origin`

  `PUBLIC_URL` supplies the absolute base URL. `PHX_HOST` overrides the
  endpoint host when it differs from the host derived from that URL.

  Called from `config/runtime.exs`, so everything in here must be pure and must
  not depend on any application having been started.
  """

  @default "http://localhost:4000"

  @doc """
  Build an absolute base URL from a configured value.

  Accepts a bare host (`"example.com"`) or an already-absolute URL, and returns
  an absolute URL with no trailing slash. `scheme` is the scheme to assume when
  the input has none.

      iex> Fountain.PublicUrl.absolute("example.com", "https")
      "https://example.com"

      iex> Fountain.PublicUrl.absolute("https://example.com/", "https")
      "https://example.com"

      iex> Fountain.PublicUrl.absolute(nil, "https")
      "http://localhost:4000"
  """
  @spec absolute(String.t() | nil, String.t()) :: String.t()
  def absolute(value, scheme \\ "https")

  def absolute(blank, _scheme) when blank in [nil, ""], do: @default

  def absolute(value, scheme) when is_binary(value) do
    trimmed = value |> String.trim() |> String.trim_trailing("/")

    cond do
      trimmed == "" -> @default
      String.starts_with?(trimmed, ["http://", "https://"]) -> trimmed
      true -> scheme <> "://" <> trimmed
    end
  end

  @doc """
  Extract the bare host from a base URL, for the endpoint and `check_origin`.

      iex> Fountain.PublicUrl.host("https://example.com")
      "example.com"

      iex> Fountain.PublicUrl.host("example.com")
      "example.com"
  """
  @spec host(String.t() | nil) :: String.t()
  def host(blank) when blank in [nil, ""], do: "localhost"

  def host(value) when is_binary(value) do
    value
    |> absolute()
    |> URI.parse()
    |> Map.get(:host)
    |> case do
      nil -> "localhost"
      "" -> "localhost"
      host -> host
    end
  end

  @doc "The configured absolute base URL. Safe to call at runtime."
  @spec base() :: String.t()
  def base do
    :fountain
    |> Application.get_env(:public_url, @default)
    |> absolute()
  end
end
