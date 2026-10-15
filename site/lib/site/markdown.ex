defmodule Site.Markdown do
  @moduledoc """
  The manual's markdown → HTML, through [MDEx](https://hexdocs.pm/mdex)
  (comrak), with fenced code highlighted by Lumis at build time.

  The pages are authored and reviewed in this repository, but the renderer
  still treats them as markdown rather than as HTML (Fountain #323, where the
  same pipeline also rendered agent output):

  1. Raw HTML is neutralised to text, so `<img src=x onerror=...>` in a page
     displays rather than runs. The one exception is a `<figure>`/`<svg>`
     block, kept so hand-drawn diagrams render, after its script-bearing
     subset (`<script>`, `<style>`, `<foreignObject>`, `on*` handlers,
     `javascript:`/`data:`/`vbscript:` URLs) is scrubbed.
  2. A link survives only with an http, https or mailto scheme (or none); an
     image only with http or https (or none). Anything else is unwrapped to its
     text. The check runs on a normalised copy of the URL (character
     references decoded, the whitespace browsers ignore removed), so
     `java&#115;cript:` cannot smuggle a scheme past it.

  Headings get GFM-style ids so `#anchor` links resolve; the site's tests
  check every one against these ids.

  ## Highlighting is strict

  The build runs where it can download parsers, and the output is static, so
  the failure the server had after #879 added highlighting cannot happen:
  on a read-only root filesystem the parser could not be fetched at runtime,
  and code rendered plain in production only. What can still happen is a fence naming a language Lumis does not
  know, which it renders plain without complaint. So a fence's language must be
  a Lumis language (by id or alias) whose parser loads, or one of
  `plaintext_languages/0`; anything else raises and fails `mix site.build`.
  """

  alias MDEx.{CodeBlock, Document, HtmlBlock, HtmlInline, Image, Link, Paragraph, Text}

  @extension [table: true, strikethrough: true, tasklist: true, header_id_prefix: ""]

  # A near-black ground (#0a0c10) that reads as a code block in both themes.
  # The colours are written inline, so no stylesheet follows the theme.
  @theme "github_dark_high_contrast"

  # Fences that render without highlighting. `text` and friends ask for none.
  # `promql` asks and cannot have it: Lumis ships no PromQL parser (and none
  # aliasing to it). The fence keeps saying `promql` because it names the
  # language rather than requesting a renderer. Adding to this list means
  # checking that Lumis really has no parser, not that loading one failed.
  @plaintext ~w(text txt plain plaintext promql)

  @doc "Fence languages rendered without highlighting."
  def plaintext_languages, do: @plaintext

  @doc """
  The Lumis language id a fence's info string highlights as, or
  `"plaintext"`. Raises for a language Lumis does not know.
  """
  def language_id(info) do
    lang =
      case String.split(info || "", ~r/\s+/, parts: 2) do
        ["" | _] -> "plaintext"
        [lang | _] -> lang
      end

    cond do
      lang in @plaintext ->
        "plaintext"

      language = Lumis.Languages.get(lang) ->
        language.id

      true ->
        raise ArgumentError, """
        a fence names ```#{lang}, which is not a Lumis language. Use the \
        language's Lumis name or alias, or, if Lumis really has no parser for \
        it, add it to Site.Markdown's plaintext list.\
        """
    end
  end

  @doc "Renders a page's markdown to HTML. Raises on a fence it cannot highlight."
  @spec to_html(String.t()) :: String.t()
  def to_html(text) when is_binary(text) do
    {:ok, %Document{nodes: nodes} = doc} = MDEx.parse_document(text, extension: @extension)

    # `unsafe: true` lets the kept figure/svg and the highlighter's own markup
    # through; every other raw-HTML node is already text by then.
    MDEx.to_html!(%{doc | nodes: nodes |> sanitize() |> highlight()},
      extension: @extension,
      render: [unsafe: true]
    )
  end

  # --- raw HTML and URLs ---

  defp sanitize(nodes) when is_list(nodes), do: Enum.flat_map(nodes, &sanitize/1)

  defp sanitize(%HtmlBlock{literal: literal} = block) do
    if String.match?(literal, ~r/\A\s*<(figure|svg)\b/i),
      do: [%{block | literal: scrub_svg(literal)}],
      else: neutralize_block(literal)
  end

  defp sanitize(%HtmlInline{literal: literal}), do: neutralize_inline(literal)

  defp sanitize(%Link{url: url, nodes: children} = link),
    do: keep_or_unwrap(link, url, ~w(http https mailto), sanitize(children))

  defp sanitize(%Image{url: url, nodes: children} = image),
    do: keep_or_unwrap(image, url, ~w(http https), sanitize(children))

  defp sanitize(%{nodes: children} = node), do: [%{node | nodes: sanitize(children)}]
  defp sanitize(other), do: [other]

  # A raw-HTML block becomes a paragraph of text, which the renderer escapes.
  # A block that is nothing but comments is dropped: an authored note such as
  # the one at the top of a snippet-only page is not content. Anything after a
  # comment on the same line fails the whole-literal match and is escaped.
  defp neutralize_block(literal) do
    if comment_only?(literal),
      do: [],
      else: [%Paragraph{nodes: [%Text{literal: String.trim_trailing(literal, "\n")}]}]
  end

  defp neutralize_inline(literal),
    do: if(comment_only?(literal), do: [], else: [%Text{literal: literal}])

  defp comment_only?(literal), do: String.match?(literal, ~r/\A(\s*<!--.*?-->)+\s*\z/s)

  defp keep_or_unwrap(node, url, allowed, children),
    do: if(safe_url?(url, allowed), do: [%{node | nodes: children}], else: children)

  # Element removals run before the handler and URL passes so their contents
  # cannot reintroduce a handler.
  defp scrub_svg(str) do
    str
    |> drop_elements(~w(script style foreignObject))
    |> String.replace(~r/\son[a-z]+\s*=\s*("[^"]*"|'[^']*'|[^\s>]+)/i, "")
    |> String.replace(
      ~r/(href|xlink:href|src)\s*=\s*("(?:javascript|data|vbscript):[^"]*"|'(?:javascript|data|vbscript):[^']*')/i,
      ""
    )
  end

  defp drop_elements(str, tags) do
    Enum.reduce(tags, str, fn tag, acc ->
      acc
      |> String.replace(~r/<#{tag}\b[^>]*>.*?<\/#{tag}\s*>/is, "")
      |> String.replace(~r/<#{tag}\b[^>]*\/?>/is, "")
    end)
  end

  defp safe_url?(url, allowed) do
    case String.split(normalize(url), ":", parts: 2) do
      [_no_scheme] -> true
      # A ":" after a path, query or fragment delimiter is not a scheme.
      [scheme, _rest] -> String.contains?(scheme, ["/", "?", "#"]) or scheme in allowed
    end
  end

  # Browsers strip tab/CR/LF anywhere in a URL and ignore leading controls and
  # spaces, so the check does too. Over-decoding only makes it stricter.
  defp normalize(url) do
    url
    |> decode_pass()
    |> decode_pass()
    |> String.replace(~r/[\x00-\x20]/, "")
    |> String.downcase()
  end

  @named_refs %{
    "colon" => ":",
    "sol" => "/",
    "amp" => "&",
    "tab" => "\t",
    "newline" => "\n",
    "num" => "#",
    "quest" => "?"
  }

  defp decode_pass(url) do
    Regex.replace(~r/&(?:#x([0-9a-f]+)|#([0-9]+)|([a-z]+));?/i, url, fn whole, hex, dec, named ->
      cond do
        hex != "" -> codepoint(String.to_integer(hex, 16))
        dec != "" -> codepoint(String.to_integer(dec))
        true -> Map.get(@named_refs, String.downcase(named), whole)
      end
    end)
  end

  defp codepoint(n) when n > 0 and n < 0x110000 and not (n >= 0xD800 and n <= 0xDFFF),
    do: <<n::utf8>>

  defp codepoint(_), do: ""

  # --- fenced code ---

  defp highlight(nodes) when is_list(nodes), do: Enum.map(nodes, &highlight/1)

  defp highlight(%CodeBlock{literal: source, info: info}) do
    language = language_id(info)

    if language != "plaintext" do
      case Lumis.Languages.load(language) do
        :ok -> :ok
        {:error, reason} -> raise "could not load the #{language} parser: #{inspect(reason)}"
      end
    end

    # Comrak keeps the fence's closing newline; Lumis would render it as a
    # trailing blank line.
    opts = [formatter: {:html_inline, theme: @theme, language: language}]

    case Lumis.highlight(String.trim_trailing(source, "\n"), opts) do
      {:ok, html} -> %HtmlBlock{literal: html}
      {:error, reason} -> raise "could not highlight a #{language} fence: #{reason}"
    end
  end

  defp highlight(%{nodes: children} = node), do: %{node | nodes: highlight(children)}
  defp highlight(other), do: other
end
