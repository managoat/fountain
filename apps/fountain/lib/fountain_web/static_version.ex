defmodule FountainWeb.StaticVersion do
  @moduledoc """
  A content hash for the static files the layout links by a fixed path.

  This site has no asset build. Tailwind is the play CDN and `tokens.css` is a
  hand-maintained file served straight out of `priv/static`, so there is no
  digest step and nothing rewrites the URL in the layout. `Plug.Static` sends
  it with a four-hour `max-age`, and the CDN in front of production caches on
  the URL.

  That combination means a deploy can ship new markup against a stale
  stylesheet, and it did: #1258 rendered on production with the ink and accent
  tokens undefined, so a section designed dark had a transparent ground and its
  code blocks were light grey text on a light grey page. Every workflow was
  green and the HTML was correct. The stylesheet the HTML asked for was four
  hours old, because it was the same URL it had always been.

  So the URL carries the file's hash. New file, new URL, guaranteed miss on
  every cache between here and the reader; unchanged file, unchanged URL, and
  the long `max-age` keeps doing its job.

  The hash is taken at compile time and `@external_resource` puts the file in
  the recompile set, so editing `tokens.css` changes this module too.
  """

  @tokens_path Path.expand("../../priv/static/assets/tokens.css", __DIR__)
  @external_resource @tokens_path

  @tokens_version :sha256
                  |> :crypto.hash(File.read!(@tokens_path))
                  |> Base.encode16(case: :lower)
                  |> binary_part(0, 8)

  @doc """
  The versioned path for `tokens.css`, for the `href` in the root layout.

  Never link the bare path. `design_tokens_test.exs` fails if the layout does.
  """
  @spec tokens_css() :: String.t()
  def tokens_css, do: "/assets/tokens.css?v=" <> @tokens_version

  @doc "The hash alone, so a test can compare it against the file on disk."
  @spec tokens_version() :: String.t()
  def tokens_version, do: @tokens_version
  @paper_path Path.expand("../../priv/static/assets/paper.css", __DIR__)
  @external_resource @paper_path
  @paper_version :sha256
                 |> :crypto.hash(File.read!(@paper_path))
                 |> Base.encode16(case: :lower)
                 |> binary_part(0, 8)

  @doc "The shared paper skin, versioned by its content."
  @spec paper_css() :: String.t()
  def paper_css, do: "/assets/paper.css?v=" <> @paper_version
end
