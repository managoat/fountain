defmodule FountainWeb.DesignTokensTest do
  @moduledoc """
  The design tokens exist twice and nothing built the second copy.

  `assets/css/tokens.css` is the source, with the reasoning in comments.
  `apps/fountain/priv/static/assets/tokens.css` is the file a browser actually
  loads, and it is the same declarations with the comments taken out. There is
  no bundler on this site (Tailwind is the play CDN and there is no asset
  build), so nothing generates the second file and nothing checked it.

  It had already drifted before these tests existed, and editing it by hand
  broke it in the way that is hardest to notice: half a comment survived, the
  parser swallowed the declarations after it, and the page rendered with three
  tokens silently empty. Every test stayed green, because a token that
  resolves to nothing is a background that does not paint, not an error.

  So: same properties, same values, same order, and no comment left half
  standing.
  """
  use ExUnit.Case, async: true

  @source Path.expand("../../../../assets/css/tokens.css", __DIR__)
  @served Path.expand("../../priv/static/assets/tokens.css", __DIR__)

  @external_resource @source
  @external_resource @served

  defp declarations(css) do
    css
    |> String.replace(~r|/\*.*?\*/|s, "")
    |> then(&Regex.scan(~r/(--[\w-]+)\s*:\s*([^;]+);/, &1))
    |> Enum.map(fn [_, name, value] -> {name, value |> String.split() |> Enum.join(" ")} end)
  end

  test "both files exist where the layout and the config expect them" do
    assert File.exists?(@source), "the token source is gone"
    assert File.exists?(@served), "root.html.heex links /assets/tokens.css and it is not there"
  end

  test "the served copy declares exactly what the source declares" do
    source = declarations(File.read!(@source))
    served = declarations(File.read!(@served))

    assert source != [], "the token source parsed to no declarations at all"

    assert source == served, """
    apps/fountain/priv/static/assets/tokens.css has drifted from assets/css/tokens.css.

    The served copy is the source with the comments removed. Regenerate it:

        python3 - <<'PY'
        import re, pathlib
        src = pathlib.Path("assets/css/tokens.css").read_text()
        out = re.sub(r"/\\*.*?\\*/", "", src, flags=re.S)
        out = re.sub(r"[ \\t]+\\n", "\\n", out)
        out = re.sub(r"\\n{3,}", "\\n\\n", out)
        out = re.sub(r"\\{\\n\\n+", "{\\n", out)
        out = re.sub(r"\\n\\n+\\}", "\\n}", out)
        pathlib.Path("apps/fountain/priv/static/assets/tokens.css").write_text(out.lstrip("\\n"))
        PY
    """
  end

  test "the served copy carries no comment, whole or half" do
    served = File.read!(@served)

    refute served =~ "/*", "a comment opener reached the served copy"
    refute served =~ "*/", "a comment closer reached the served copy, which swallows what follows"
  end

  test "every declaration in the served copy is one a CSS parser would keep" do
    # A line the parser cannot read is not an error; it is a token that
    # resolves to nothing, which is how the last break got as far as a
    # screenshot. Anything between the braces is a declaration or blank.
    for {line, n} <- @served |> File.read!() |> String.split("\n") |> Enum.with_index(1),
        trimmed = String.trim(line),
        trimmed != "",
        not String.ends_with?(trimmed, "{"),
        trimmed != "}" do
      assert Regex.match?(~r/^--[\w-]+\s*:\s*[^;]+;$/, trimmed) or
               Regex.match?(~r/^[\w-]+\s*:\s*[^;]+;$/, trimmed),
             "tokens.css line #{n} is neither a declaration nor a block edge: #{inspect(line)}"
    end
  end

  describe "the URL the layout links" do
    @layout Path.expand(
              "../../lib/fountain_web/components/layouts/root.html.heex",
              __DIR__
            )

    test "carries the file's hash, so a deploy cannot land on a cached stylesheet" do
      # #1258 shipped correct markup to production against a four-hour-old
      # tokens.css, because the layout asked for the same URL it always had and
      # the CDN answered from cache. The ink and accent tokens were undefined
      # for every reader: a section designed dark had a transparent ground.
      layout = File.read!(@layout)

      refute layout =~ ~s(href="/assets/tokens.css"),
             "the layout links the bare path, so a token change cannot reach a cached reader"

      assert layout =~ "FountainWeb.StaticVersion.tokens_css()",
             "the layout should link the versioned path"
    end

    test "the version is the hash of the file actually served" do
      expected =
        :sha256
        |> :crypto.hash(File.read!(@served))
        |> Base.encode16(case: :lower)
        |> binary_part(0, 8)

      assert FountainWeb.StaticVersion.tokens_version() == expected,
             "the compiled hash is stale against priv/static/assets/tokens.css"

      assert FountainWeb.StaticVersion.tokens_css() == "/assets/tokens.css?v=" <> expected
    end

    test "the served file is reachable at the path the layout asks for" do
      "/" <> path = FountainWeb.StaticVersion.tokens_css() |> String.split("?") |> hd()
      assert Path.basename(path) == Path.basename(@served)
      assert "assets/tokens.css" == path
    end
  end

  describe "the theme values" do
    setup do
      %{tokens: Map.new(declarations(File.read!(@source)))}
    end

    test "the dark code background clears the panel it sits on", %{tokens: tokens} do
      # It was #000000 against a #18181b card, which is a code block you cannot
      # see in dark mode on any page that renders one.
      css = File.read!(@source)
      [_, dark] = String.split(css, ~s([data-theme="dark"] {), parts: 2)
      dark_tokens = Map.new(declarations("x {" <> dark))

      refute dark_tokens["--color-code-bg"] == dark_tokens["--color-bg-1"]
      refute dark_tokens["--color-code-bg"] == "#000000"
      assert tokens["--color-code-bg"], "the light value is gone"
    end
  end
end
