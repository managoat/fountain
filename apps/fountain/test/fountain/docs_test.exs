defmodule Fountain.DocsTest do
  @moduledoc """
  The embedded docs manual against `docs/nav.yml` and against itself.

  Since #1008 retired the GitHub Pages build, this file is the *whole*
  structural gate on `docs/`. `mkdocs build --strict` used to run on main and
  catch a relative link that did not resolve; nothing else renders these pages
  now, so the checks that replaced it run here: every page the nav names
  exists, every page on disk is in the nav, every internal `/docs` link and
  anchor resolves, every file `Fountain.Docs` reads at compile time is
  `COPY`d into the image (#884), and every fenced language is baked (#879).
  The anchor check is the one MkDocs never had.

  Those checks are `Managoat.Docs.GuardrailCase` (ADR 0037): the `use` line
  below generates them as tests against `Fountain.Docs` and the repo-root
  Dockerfile, with the failure messages that name each incident. The
  library runs the same template against a fixture manual, so the checks
  are exercised before they run here. What follows the `use` is about this
  manual's content: its nav order, the pages a test can name, the primitives
  diagram in both its copies, and the fences in `priv/help`.
  """

  # `promql` asks for highlighting and cannot have it: Lumis ships no PromQL
  # parser (116 languages, none of them PromQL, and none aliasing to it), so
  # there is nothing to bake, and adding it to the language list would fail
  # the sibling "every language name is one Lumis knows" test and break the
  # Dockerfile's cache step. The fence still says `promql`, because the fence
  # names the language rather than requesting a renderer, and renaming it to
  # hide the gap would be a lie a future parser never undoes. (Until #1008
  # there was a second reason: the MkDocs build highlighted it, Pygments
  # having a lexer.) Adding to this list means checking that Lumis really
  # has no parser, not that baking one is inconvenient.
  @unhighlightable ~w(text txt plain plaintext promql)

  use Managoat.Docs.GuardrailCase,
    docs: Fountain.Docs,
    dockerfile: "Dockerfile",
    unhighlightable: @unhighlightable

  alias Fountain.Docs
  alias Managoat.Docs.Checks

  @repo_root Path.expand("../../../..", __DIR__)

  test "the portable alert table matches the shipped rule names" do
    rules = File.read!(Path.join(@repo_root, "deploy/k8s/prometheusrule.yaml"))
    page = File.read!(Path.join(@repo_root, "docs/guides/operate/observability.md"))
    [_, table] = Regex.run(~r/### Portable baseline\n(.*?)### Added by the hosted overlay/s, page)

    shipped =
      Regex.scan(~r/^\s*- alert: (\w+)/m, rules, capture: :all_but_first) |> List.flatten()

    documented =
      Regex.scan(~r/\| `(Fountain\w+)` \|/, table, capture: :all_but_first) |> List.flatten()

    assert shipped != []
    assert Enum.sort(documented) == Enum.sort(shipped)
  end

  describe "nav ← docs/nav.yml" do
    test "parses the real docs/nav.yml into pages and one-level sections" do
      nav = Docs.nav_source()

      assert {"Home", "index.md"} in nav
      assert {"Configuration reference", "configuration.md"} in nav

      assert {"Sandbox providers", children} =
               Enum.find(nav, &match?({"Sandbox providers", _}, &1))

      assert {"Sprites", "integrations/sprites.md"} in children
    end

    test "keeps docs/nav.yml's order" do
      titles = Enum.map(Docs.nav_source(), &elem(&1, 0))

      assert Enum.take(titles, 4) == [
               "Home",
               "Quickstart, first agent",
               "Guided tour, a pull request",
               "Concepts"
             ]

      assert List.last(titles) == "Changelog"
    end

    # The quickstart and tutorial sit before the concepts tree, and all three
    # sit ahead of every reference page. A newcomer gets an executable path
    # before the data model and the command catalog.
    test "the quickstart, tutorial, and concepts tree come before reference" do
      titles = Enum.map(Docs.nav_source(), &elem(&1, 0))

      quickstart = Enum.find_index(titles, &(&1 == "Quickstart, first agent"))
      tour = Enum.find_index(titles, &(&1 == "Guided tour, a pull request"))
      concepts = Enum.find_index(titles, &(&1 == "Concepts"))
      reference = Enum.find_index(titles, &(&1 == "Reference"))

      assert quickstart < tour
      assert tour < concepts
      assert concepts < reference
    end
  end

  describe "this manual's pages" do
    test "the home page is the product's" do
      assert {:ok, %{title: "Home", body: body}} = Docs.get("")
      assert body =~ "multi-tenant"
    end

    test "the section index page lives at the section slug" do
      assert {:ok, %{title: "Overview"}} = Docs.get("integrations")
      assert :error = Docs.get("integrations/index")
    end

    test "the changelog page carries the repo-root CHANGELOG" do
      {:ok, %{body: body}} = Docs.get("changelog")
      assert body =~ "Keep a Changelog"
    end

    test "the search index skips the page's own <h1>" do
      {:ok, %{body: body}} = Docs.get("configuration")

      headings =
        Docs.search_index()
        |> Enum.find(&(&1.slug == "configuration"))
        |> Map.fetch!(:headings)

      refute Enum.any?(headings, &(&1.text == "Configuration reference")),
             "the page title (h1) should not also appear as a heading"

      assert body =~ "# Configuration reference"
    end

    test "search_index_json/0 carries a page under its nav title" do
      decoded = Jason.decode!(Docs.search_index_json())
      assert Enum.find(decoded, &(&1["slug"] == "self-hosting"))["title"] == "Self-host Fountain"
    end

    test "the compile-time reads are the nav, every page and the changelog" do
      resources = Docs.external_resources()
      assert "docs/nav.yml" in resources
      assert "CHANGELOG.md" in resources
      assert "docs/index.md" in resources
      assert Enum.all?(resources, &(String.starts_with?(&1, "docs/") or &1 == "CHANGELOG.md"))
    end
  end

  # The in-app help under priv/help renders through the same trusted path as
  # the manual, so its fences need the same baked parsers. The manual's own
  # fences are covered by the guardrail above; this is the second corpus.
  describe "priv/help" do
    test "fences only languages the image bakes" do
      fences =
        [@repo_root, "apps/fountain/priv/help/**/*.md"]
        |> Path.join()
        |> Path.wildcard()
        |> Checks.fenced_languages()

      assert fences != [], "priv/help has no fenced code; is the glob right?"

      assert Checks.unbaked_fences(Docs.languages(), fences, @unhighlightable) == []
    end
  end

  # The primitives diagram exists twice: as a file for the README, which GitHub
  # renders on a page whose theme an <img> cannot read, and inline in
  # docs/primitives.md, where `currentColor` follows the manual's theme. Two
  # copies of one drawing drift, and the drift is invisible until somebody
  # opens the other one. These pin the copies to each other and to the exact
  # three differences that are allowed.
  describe "the primitives diagram, in both its copies" do
    @svg_file Path.join(@repo_root, "docs/images/primitives.svg")
    @svg_page Path.join(@repo_root, "docs/primitives.md")

    test "the inline copy is the file, minus the background and in currentColor" do
      file = File.read!(@svg_file)
      inline = inline_svg()

      expected =
        file
        |> String.replace(~r/\A<svg\b[^>]*>/, "")
        |> String.replace(~r|\n\s*<rect width="740" height="336" fill="#ffffff"/>|, "",
          global: false
        )
        |> String.replace("#1b2530", "currentColor")
        |> String.trim()

      actual = inline |> String.replace(~r/\A<svg\b[^>]*>/, "") |> String.trim()

      assert actual == expected,
             "docs/primitives.md's inline SVG has drifted from docs/images/primitives.svg"
    end

    test "the file paints its own background, and the inline copy does not" do
      # An <img> on github.com cannot inherit a theme, so the file carries a
      # white ground rather than turning into invisible dark-on-dark.
      assert File.read!(@svg_file) =~ ~s(<rect width="740" height="336" fill="#ffffff"/>)
      refute inline_svg() =~ ~s(fill="#ffffff")
      refute inline_svg() =~ "#1b2530"
    end

    test "one description serves the file, the inline copy and the README" do
      label = aria_label(File.read!(@svg_file))

      assert String.length(label) > 200,
             "the description is the whole picture for a screen reader"

      assert label == aria_label(inline_svg())

      readme = File.read!(Path.join(@repo_root, "README.md"))
      assert readme =~ ~s(alt="#{label}"), "README.md's alt text has drifted from the drawing"
    end

    test "the drawing names every stage the caption and the page describe" do
      file = File.read!(@svg_file)

      for stage <- ["1 · WRITE ONCE", "2 · AT LAUNCH", "3 · THE MACHINE"] do
        assert file =~ stage, "the diagram lost stage #{stage}"
      end

      # The four primitives this page exists to explain, plus the one rule the
      # prose below the figure calls the reason the division works.
      for primitive <- ~w(Agent Environment Vault Conversation Sandbox) do
        assert file =~ ">#{primitive}<", "the diagram lost #{primitive}"
      end

      assert file =~ "vault wins"
    end

    defp inline_svg do
      page = File.read!(@svg_page)
      start = :binary.match(page, "<svg") |> elem(0)
      {stop, len} = :binary.match(page, "</svg>")
      binary_part(page, start, stop + len - start)
    end

    defp aria_label(svg) do
      [_, label] = Regex.run(~r/aria-label="([^"]*)"/, svg)
      label
    end
  end
end
