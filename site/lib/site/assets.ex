defmodule Site.Assets do
  @moduledoc """
  The two stylesheets and the images the pages link, under `/site/`.

  The prefix keeps them off paths the app serves on the same host (`/assets/`
  and `/images/` are the app's). The stylesheets carry a content hash in the
  file name for the same reason the app versioned them (`FountainWeb.StaticVersion`):
  a CDN caches on the URL, and a deploy that ships new markup against a stale
  sheet renders wrong with every check green.
  """

  @priv Path.expand("../../priv/site", __DIR__)
  @tokens Path.join(@priv, "tokens.css")
  @paper Path.join(@priv, "paper.css")
  @external_resource @tokens
  @external_resource @paper

  @tokens_hash :sha256
               |> :crypto.hash(File.read!(@tokens))
               |> Base.encode16(case: :lower)
               |> binary_part(0, 8)
  @paper_hash :sha256
              |> :crypto.hash(File.read!(@paper))
              |> Base.encode16(case: :lower)
              |> binary_part(0, 8)

  @doc "The source directory copied into the build."
  def priv, do: @priv

  @doc "Published path of the design tokens."
  def tokens_css, do: "/site/tokens.#{@tokens_hash}.css"

  @doc "Published path of the paper skin."
  def paper_css, do: "/site/paper.#{@paper_hash}.css"

  @doc "Source file and published path for each hashed stylesheet."
  def stylesheets do
    [{@tokens, tokens_css()}, {@paper, paper_css()}]
  end
end
