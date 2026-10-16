defmodule FountainWeb.DesignTokensTest do
  @moduledoc """
  `priv/static/assets/tokens.css` is the console's one token file, served as
  written, comments and all: there is no bundler (Tailwind is the play CDN),
  and the stripped second copy it used to have drifted from its source.
  """
  use ExUnit.Case, async: true

  @served Path.expand("../../priv/static/assets/tokens.css", __DIR__)

  @external_resource @served

  defp declarations(css) do
    css
    |> String.replace(~r|/\*.*?\*/|s, "")
    |> then(&Regex.scan(~r/(--[\w-]+)\s*:\s*([^;]+);/, &1))
    |> Enum.map(fn [_, name, value] -> {name, value |> String.split() |> Enum.join(" ")} end)
  end

  test "the file parses to declarations" do
    assert File.exists?(@served), "root.html.heex links /assets/tokens.css and it is not there"
    assert declarations(File.read!(@served)) != [], "tokens.css parsed to no declarations at all"
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

  test "the console loads the shared paper skin with a content hash" do
    paper = Path.expand("../../priv/static/assets/paper.css", __DIR__)
    hash = :crypto.hash(:sha256, File.read!(paper)) |> Base.encode16(case: :lower)

    assert FountainWeb.StaticVersion.paper_css() ==
             "/assets/paper.css?v=" <> binary_part(hash, 0, 8)

    layout =
      File.read!(Path.expand("../../lib/fountain_web/components/layouts/root.html.heex", __DIR__))

    assert layout =~ ~s(data-skin="paper")
    assert layout =~ "FountainWeb.StaticVersion.paper_css()"
  end

  describe "the theme values" do
    setup do
      %{tokens: Map.new(declarations(File.read!(@served)))}
    end

    test "the dark code background clears the panel it sits on", %{tokens: tokens} do
      # It was #000000 against a #18181b card, which is a code block you cannot
      # see in dark mode on any page that renders one.
      css = File.read!(@served)
      [_, dark] = String.split(css, ~s([data-theme="dark"] {), parts: 2)
      dark_tokens = Map.new(declarations("x {" <> dark))

      refute dark_tokens["--color-code-bg"] == dark_tokens["--color-bg-1"]
      refute dark_tokens["--color-code-bg"] == "#000000"
      assert tokens["--color-code-bg"], "the light value is gone"
    end
  end
end
