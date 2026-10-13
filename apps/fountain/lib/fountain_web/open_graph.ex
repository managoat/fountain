defmodule FountainWeb.OpenGraph do
  @moduledoc """
  The Open Graph / Twitter card every HTML page carries in its `<head>`.

  A link to a docs page or the sign-in page unfurls in
  Slack, iMessage, X and LinkedIn with a title, a description and the card
  image at `/images/og-card.png` (1200×630). The values come from assigns a
  controller may set — `:page_title` and `:meta_description` — with a
  deployment-wide default for each, so a page that sets nothing still gets a
  sensible card rather than a bare URL.

  Absolute URLs are built from `:public_url`, never from the request host: the
  scraper's `Host` header is whatever it sent, and a card that quotes it back
  would let anyone mint one that points at a lookalike.
  """

  @image_path "/images/og-card.png"

  @doc "The page's card title: `:page_title`, else the brand name."
  @spec title(map()) :: String.t()
  def title(assigns), do: assigns[:page_title] || Fountain.Brand.name()

  @doc "The page's card description: `:meta_description`, else what the instance is."
  @spec description(map()) :: String.t()
  def description(assigns), do: assigns[:meta_description] || default_description()

  @doc "The description used when a page sets none of its own."
  @spec default_description() :: String.t()
  def default_description do
    "#{Fountain.Brand.name()} runs agents on sandboxes and serves their " <>
      "conversations over an API."
  end

  @doc "Alt text for the card: the brand."
  @spec image_alt() :: String.t()
  def image_alt, do: Fountain.Brand.name()

  @doc "Absolute canonical URL of the request path (query string dropped)."
  @spec url(Plug.Conn.t() | nil) :: String.t()
  def url(%Plug.Conn{request_path: path}), do: public_url() <> path
  def url(_), do: public_url()

  @doc """
  Absolute URL of the card image: the brand bundle's card when
  `BRAND_ASSETS_URL` is set, else the built-in one under `:public_url`.
  """
  @spec image() :: String.t()
  def image do
    case Fountain.Brand.assets_url() do
      nil -> public_url() <> @image_path
      _ -> Fountain.Brand.asset("og-card.png")
    end
  end

  defp public_url do
    Fountain.PublicUrl.absolute(Application.get_env(:fountain, :public_url))
  end
end
