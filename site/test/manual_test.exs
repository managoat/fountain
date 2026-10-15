defmodule Site.ManualTest do
  @moduledoc """
  The manual (`docs/` at the repository root) against `docs/nav.yml` and
  against itself. This file is the whole structural gate on `docs/`: nothing
  else renders these pages.

  Each check exists because of an incident, most of them from when the
  Fountain server embedded the manual (`Fountain.Docs` over `managoat_docs`,
  until 2026-10-15): every page the nav names exists and every page on disk is
  named; every internal `/docs` link and `#anchor` resolves against the
  rendered heading ids (the MkDocs build that came before slugged duplicate
  headings differently, so no second slugging pass is allowed); no authoring
  syntax survives preprocessing; every fenced language highlights.
  What follows those is about this manual's content.
  """
  use ExUnit.Case, async: true

  alias Site.Manual

  @root Manual.root()

  defp assert_sound([]), do: :ok
  defp assert_sound(failures), do: flunk(Enum.join(failures, "\n\n"))

  defp rendered, do: Site.Build.rendered_manual()

  defp bodies do
    for slug <- Manual.slugs() do
      {:ok, %{body: body}} = Manual.get(slug)
      {slug, body}
    end
  end

  describe "nav" do
    test "every page the nav names exists on disk" do
      for {_title, file} <- Manual.flat_pages(Manual.nav_source()),
          not File.exists?(Path.join(Manual.docs_dir(), file)) do
        "the nav lists #{file}, which does not exist"
      end
      |> assert_sound()
    end

    # MkDocs built every page under docs/ whether the nav named it or not, so a
    # page left out of the nav still got published and four such pages had
    # accumulated. With one publisher, a page missing from the nav is published
    # nowhere at all. No allowlist: a markdown file nobody should read here
    # belongs somewhere else.
    test "every page on disk is named in the nav" do
      named = MapSet.new(Manual.flat_pages(Manual.nav_source()), fn {_t, file} -> file end)

      orphans =
        [Manual.docs_dir(), "**", "*.md"]
        |> Path.join()
        |> Path.wildcard()
        |> Enum.map(&Path.relative_to(&1, Manual.docs_dir()))
        |> Enum.reject(&MapSet.member?(named, &1))

      assert orphans == [], """
      These pages are under docs/ but not in docs/nav.yml, so they are published
      nowhere. Add them to the nav, or move them out of docs/:

      #{Enum.map_join(orphans, "\n", &("  " <> &1))}
      """
    end

    test "parses the real docs/nav.yml into the home page and the four categories" do
      nav = Manual.nav_source()

      assert Enum.map(nav, &elem(&1, 0)) ==
               ["Home", "Tutorials", "How-to guides", "Explanation", "Reference"]

      assert {"Home", "index.md"} = hd(nav)

      # A category holds pages directly (Tutorials) or sections of pages.
      assert {"Tutorials", tutorials} = List.keyfind(nav, "Tutorials", 0)
      assert {"Quickstart, first agent", "quickstart.md"} in tutorials

      assert {"How-to guides", how_to} = List.keyfind(nav, "How-to guides", 0)

      assert {"Connect services", services} = List.keyfind(how_to, "Connect services", 0)

      assert {"Sprites", "integrations/sprites.md"} in services
    end

    # A newcomer gets an executable path before the data model, and the data
    # model before the command catalog.
    test "tutorials come first, and explanation before reference" do
      assert Manual.nav_source() |> Manual.flat_pages() |> Enum.take(3) == [
               {"Home", "index.md"},
               {"Quickstart, first agent", "quickstart.md"},
               {"Guided tour, a pull request", "tour.md"}
             ]

      titles = Enum.map(Manual.nav_source(), &elem(&1, 0))
      index = fn title -> Enum.find_index(titles, &(&1 == title)) end
      assert index.("Explanation") < index.("Reference")
    end

    test "reads three levels, and a category may hold pages beside its sections" do
      yaml = """
      nav:
        - Home: index.md
        - Category:
            - Loose page: loose.md
            - Section:
                - Deep page: deep/page.md
            - Second loose page: loose2.md
        # a comment inside the block
        - Last: last.md
      """

      assert Manual.parse_nav(yaml) == [
               {"Home", "index.md"},
               {"Category",
                [
                  {"Loose page", "loose.md"},
                  {"Section", [{"Deep page", "deep/page.md"}]},
                  {"Second loose page", "loose2.md"}
                ]},
               {"Last", "last.md"}
             ]

      assert Manual.flat_pages(Manual.parse_nav(yaml)) == [
               {"Home", "index.md"},
               {"Loose page", "loose.md"},
               {"Deep page", "deep/page.md"},
               {"Second loose page", "loose2.md"},
               {"Last", "last.md"}
             ]
    end

    test "an unreadable line, a fourth level or a misplaced indent raises" do
      raises = fn message, yaml ->
        assert_raise ArgumentError, message, fn -> Manual.parse_nav("nav:\n" <> yaml) end
      end

      raises.(~r/unparsed nav.yml nav line/, "  - not a nav line\n")
      raises.(~r/unparsed nav.yml nav line/, "  - A:\n\t- B: b.md\n")
      raises.(~r/indented 4 spaces/, "  - A:\n    - B: b.md\n")
      raises.(~r/indented 8 spaces/, "  - A:\n      - B:\n        - C: c.md\n")

      # A section inside a section, and a page under it.
      raises.(~r/nav section nested in a section/, "  - A:\n      - B:\n          - C:\n")

      raises.(
        ~r/deeper than three levels/,
        "  - A:\n      - B:\n          - C:\n              - D: d.md\n"
      )

      # Children under a page, at either level.
      raises.(~r/indented past its siblings/, "  - A: a.md\n      - B: b.md\n")
      raises.(~r/indented past its siblings/, "  - A:\n      - B: b.md\n          - C: c.md\n")
      # A category's first child skipping the section level.
      raises.(~r/indented past its siblings/, "  - A:\n          - C: c.md\n")

      # A header with nothing under it would draw an empty group.
      raises.(~r/header with nothing under it/, "  - A:\n  - B: b.md\n")
      raises.(~r/header with nothing under it/, "  - A:\n      - B:\n      - C: c.md\n")

      assert_raise ArgumentError, ~r/no `nav:` block/, fn -> Manual.parse_nav("pages: []\n") end
    end
  end

  describe "pages" do
    test "every slug resolves to a titled, non-empty page, and the home page is at \"\"" do
      assert {:ok, %{title: "Home"}} = Manual.get("")

      for {slug, body} <- bodies(), String.trim(body) == "" do
        "#{inspect(slug)} has an empty body"
      end
      |> assert_sound()
    end

    test "unknown slugs miss" do
      assert :error = Manual.get("nope")
      assert :error = Manual.get("index")
      assert :error = Manual.get("../../etc/passwd")
    end

    test "no unsupported syntax survives preprocessing" do
      for {slug, body} <- bodies(),
          {bad?, what} <- [
            {Regex.match?(~r/\]\((?!https?:)[^)]*\.md/, body), "unrewritten .md link"},
            {Regex.match?(~r/^!!!/m, body), "unrewritten admonition"},
            {String.contains?(body, "--8<--"), "unexpanded snippet include"}
          ],
          bad? do
        "#{what} in #{inspect(slug)}"
      end
      |> assert_sound()
    end

    test "every internal link targets a page that exists" do
      slugs = MapSet.new(Manual.slugs())

      for {slug, body} <- bodies(),
          [_, target] <- Regex.scan(~r{\]\(/docs(/[^)#]+)?(?:#[^)]*)?\)}, body),
          target_slug = String.trim_leading(target, "/"),
          not MapSet.member?(slugs, target_slug) do
        "#{inspect(slug)} links to #{Manual.path_for_slug(target_slug)}, which is not a page"
      end
      |> assert_sound()
    end

    # `](/docs#x)` is the home page. managoat_docs checked it against the
    # linking page instead, which no page happened to exercise until one
    # linked the home page's "Which version this is".
    test "every internal anchor link targets a heading on that page" do
      rendered = rendered()

      for {slug, body} <- bodies(),
          [_, target, anchor] <- Regex.scan(~r{\]\(/docs(/[^)#]+)?#([^)]+)\)}, body),
          target_slug = String.trim_leading(target, "/"),
          not String.contains?(Map.get(rendered, target_slug, ""), ~s( id="#{anchor}")) do
        "#{inspect(slug)} links to #{Manual.path_for_slug(target_slug)}##{anchor}, " <>
          "but that page has no heading with that id"
      end
      |> assert_sound()
    end

    test "every same-page anchor link targets a heading on the page" do
      rendered = rendered()

      for {slug, body} <- bodies(),
          [_, anchor] <- Regex.scan(~r{\]\(#([^)\s]+)\)}, body),
          not String.contains?(rendered[slug], ~s( id="#{anchor}")) do
        "#{inspect(slug)} links to ##{anchor}, but has no heading with that id"
      end
      |> assert_sound()
    end

    # CI runs this suite only when something it reads changes
    # (scripts/ci/changes.py). A page that includes a file from somewhere new
    # would otherwise go untested, and unpublished, when that file changes.
    test "every snippet include is a file CI selects the site job for" do
      changes = File.read!(Path.join(@root, "scripts/ci/changes.py"))
      [_, block] = Regex.run(~r/^MANUAL_SOURCES = \((.*?)^\)/ms, changes)
      sources = Regex.scan(~r/"([^"]+)"/, block, capture: :all_but_first) |> List.flatten()
      assert "CHANGELOG.md" in sources

      for path <- Manual.snippet_paths(),
          not String.starts_with?(path, "docs/"),
          not Enum.any?(
            sources,
            &(path == &1 or (String.ends_with?(&1, "/") and String.starts_with?(path, &1)))
          ) do
        "a page includes #{path}, which is not under MANUAL_SOURCES in scripts/ci/changes.py"
      end
      |> assert_sound()
    end

    test "every snippet include names a file in the repository" do
      for path <- Manual.snippet_paths(), not File.regular?(Path.join(@root, path)) do
        "a page includes #{path}, which does not exist"
      end
      |> assert_sound()
    end
  end

  # A fence in a language Lumis does not know renders plain without a word,
  # the same silent failure as the unbaked parsers after #879. The renderer
  # raises on one, so the build
  # fails; this names every offender at once instead of the first.
  describe "fenced code" do
    test "every fence names a language Lumis highlights, or a plaintext one" do
      for {slug, body} <- bodies(),
          [_, info] <- Regex.scan(~r/^\s*```([a-zA-Z0-9_+-]+)\s*$/m, body),
          info not in Site.Markdown.plaintext_languages(),
          Lumis.Languages.get(info) == nil,
          uniq: true do
        "#{inspect(slug)} fences ```#{info}, which is not a Lumis language"
      end
      |> assert_sound()
    end

    test "every highlighted language's parser loads" do
      ids =
        for {_slug, body} <- bodies(),
            [_, info] <- Regex.scan(~r/^\s*```([a-zA-Z0-9_+-]+)\s*$/m, body),
            id = Site.Markdown.language_id(info),
            id != "plaintext",
            uniq: true,
            do: id

      assert ids != []
      assert :ok = Lumis.Languages.load(ids)
    end

    test "a labelled fence on a real page is highlighted" do
      html = rendered()["quickstart"]
      assert html =~ ~s(class="language-bash")
      assert html =~ "style=\"color:"
    end
  end

  describe "search index" do
    setup do
      %{index: Jason.decode!(Site.Build.search_index_json())}
    end

    test "has one entry per page, in nav order", %{index: index} do
      assert Enum.map(index, & &1["slug"]) == Manual.slugs()
    end

    test "every heading id resolves on its own page, and none is empty", %{index: index} do
      rendered = rendered()

      for %{"slug" => slug, "headings" => headings} <- index,
          %{"id" => id, "text" => text} <- headings,
          text == "" or not String.contains?(rendered[slug], ~s( id="#{id}")) do
        "#{inspect(slug)}'s search index has heading #{inspect(id)} (#{inspect(text)}), " <>
          "which the page does not render"
      end
      |> assert_sound()
    end

    test "skips the page's own <h1>", %{index: index} do
      config = Enum.find(index, &(&1["slug"] == "configuration"))
      refute Enum.any?(config["headings"], &(&1["text"] == "Configuration reference"))

      assert rendered()["configuration"] =~
               ~s(<h1 id="configuration-reference">Configuration reference)
    end

    test "carries a page under its nav title", %{index: index} do
      assert Enum.find(index, &(&1["slug"] == "self-hosting"))["title"] == "Self-host Managoat"
    end

    test "decodes headings' entities exactly once" do
      assert Manual.extract_headings(
               ~s(<h2 id="a">Use &amp;lt;b&amp;gt; &amp; <code>x</code></h2>)
             ) ==
               [%{id: "a", text: "Use &lt;b&gt; & x"}]
    end
  end

  describe "this manual's pages" do
    test "the home page is the product's" do
      assert {:ok, %{title: "Home", body: body}} = Manual.get("")
      assert body =~ "one instance that you run for yourself"
    end

    test "the section index page lives at the section slug" do
      assert {:ok, %{title: "Overview"}} = Manual.get("integrations")
      assert :error = Manual.get("integrations/index")
    end

    test "the changelog page carries the repo-root CHANGELOG" do
      {:ok, %{body: body}} = Manual.get("changelog")
      assert body =~ "Keep a Changelog"
    end

    test "relative links are rewritten to /docs paths" do
      {:ok, %{body: body}} = Manual.get("architecture")
      assert body =~ "](/docs/primitives"
    end

    test "an admonition renders as a blockquote, not its source" do
      html = rendered()["quickstart"]
      assert html =~ "Whose model key"
      assert html =~ "<blockquote>"
      refute html =~ "!!!"
    end

    test "the manual says it describes main" do
      {:ok, %{body: body}} = Manual.get("")
      assert body =~ "describes the `main` branch"
      {:ok, %{body: body}} = Manual.get("self-hosting")
      assert body =~ "describes the `main` branch"
    end
  end

  test "the portable alert table matches the shipped rule names" do
    rules = File.read!(Path.join(@root, "deploy/k8s/prometheusrule.yaml"))
    page = File.read!(Path.join(@root, "docs/guides/operate/observability.md"))
    [_, table] = Regex.run(~r/### Portable baseline\n(.*?)### Added by the hosted overlay/s, page)

    shipped =
      Regex.scan(~r/^\s*- alert: (\w+)/m, rules, capture: :all_but_first) |> List.flatten()

    documented =
      Regex.scan(~r/\| `(Managoat\w+)` \|/, table, capture: :all_but_first) |> List.flatten()

    assert shipped != []
    assert Enum.sort(documented) == Enum.sort(shipped)
  end

  # The primitives diagram exists twice: as a file for the README, which GitHub
  # renders on a page whose theme an <img> cannot read, and inline in
  # docs/primitives.md, where `currentColor` follows the manual's theme. These
  # pin the copies to each other and to the three differences allowed.
  describe "the primitives diagram, in both its copies" do
    @svg_file Path.join(@root, "docs/images/primitives.svg")
    @svg_page Path.join(@root, "docs/primitives.md")

    test "the inline copy is the file, minus the background and in currentColor" do
      expected =
        File.read!(@svg_file)
        |> String.replace(~r/\A<svg\b[^>]*>/, "")
        |> String.replace(~r|\n\s*<rect width="740" height="336" fill="#ffffff"/>|, "",
          global: false
        )
        |> String.replace("#1b2530", "currentColor")
        |> String.trim()

      actual = inline_svg() |> String.replace(~r/\A<svg\b[^>]*>/, "") |> String.trim()

      assert actual == expected,
             "docs/primitives.md's inline SVG has drifted from docs/images/primitives.svg"
    end

    test "the file paints its own background, and the inline copy does not" do
      assert File.read!(@svg_file) =~ ~s(<rect width="740" height="336" fill="#ffffff"/>)
      refute inline_svg() =~ ~s(fill="#ffffff")
      refute inline_svg() =~ "#1b2530"
    end

    test "one description serves the file, the inline copy and the README" do
      label = aria_label(File.read!(@svg_file))

      assert String.length(label) > 200,
             "the description is the whole picture for a screen reader"

      assert label == aria_label(inline_svg())

      readme = File.read!(Path.join(@root, "README.md"))
      assert readme =~ ~s(alt="#{label}"), "README.md's alt text has drifted from the drawing"
    end

    test "the drawing names every stage the caption and the page describe" do
      file = File.read!(@svg_file)

      for stage <- ["1 · WRITE ONCE", "2 · AT LAUNCH", "3 · THE MACHINE"],
          do: assert(file =~ stage, "the diagram lost stage #{stage}")

      for primitive <- ~w(Agent Environment Vault Conversation Sandbox),
          do: assert(file =~ ">#{primitive}<", "the diagram lost #{primitive}")

      assert file =~ "vault wins"
    end

    test "the rendered page carries the diagram as markup" do
      assert rendered()["primitives"] =~ "<svg"
      refute rendered()["primitives"] =~ "&lt;svg"
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
