defmodule Site.DocsBuildTest do
  @moduledoc """
  The manual as `mix site.build` writes it: the pages nginx serves at `/docs`,
  the search index, and the llms.txt files. These were the Fountain server's
  `DocsController` and `LlmsController` tests until 2026-10-15
  (decisions/0081).
  """
  use ExUnit.Case, async: true

  @out Path.join(System.tmp_dir!(), "managoat-docs-test-#{System.unique_integer([:positive])}")
  @base "https://managoat.com"

  setup_all do
    Site.Build.run(@out)
    on_exit(fn -> File.rm_rf!(@out) end)
    :ok
  end

  defp read(file), do: File.read!(Path.join(@out, file))
  defp page(path), do: read(Site.Build.file_for(path))

  describe "the pages" do
    test "every slug is written where nginx looks for it, titled and canonical" do
      for slug <- Site.Manual.slugs() do
        path = Site.Manual.path_for_slug(slug)
        {:ok, %{title: title}} = Site.Manual.get(slug)
        html = page(path)

        assert html =~ "<title>Docs · #{title}</title>", path
        assert html =~ ~s(<link rel="canonical" href="#{@base}#{path}">), path
        assert html =~ ~s(id="docs-search-input"), path
      end
    end

    test "the home page is at /docs, with the sidebar nav" do
      html = page("/docs")
      assert html =~ "one instance that you run for yourself"
      # One entry from each nav shape: a category's own page, a section's
      # page, and a section's page in another category.
      assert html =~ ~s(href="/docs/quickstart")
      assert html =~ "Self-host Fountain"
      assert html =~ "Sprites transport reference"
      assert html =~ ~s(href="/docs/integrations/sprites-contract")
      refute html =~ "!!!"
    end

    # The home page sits outside every category, so every category starts
    # open there; on any other page only the category holding it does.
    test "a category starts open on the home page and when it holds the page" do
      categories = fn html ->
        ~r{<details class="[^"]*" data-role="docs-nav-category"( open)?>\s*<summary[^>]*>.*?</svg>\s*([^<]+?)\s*</summary>}s
        |> Regex.scan(html)
        |> Enum.map(fn [_, open, title] -> {title, open == " open"} end)
        |> Enum.uniq()
      end

      assert categories.(page("/docs")) == [
               {"Tutorials", true},
               {"How-to guides", true},
               {"Explanation", true},
               {"Reference", true}
             ]

      assert categories.(page("/docs/configuration")) == [
               {"Tutorials", false},
               {"How-to guides", false},
               {"Explanation", false},
               {"Reference", true}
             ]
    end

    test "the current page is marked in the nav" do
      assert page("/docs/configuration") =~
               ~r{<a href="/docs/configuration" aria-current="page"}
    end

    test "nested pages, rewritten links and the inlined changelog" do
      assert page("/docs/integrations/sprites-contract") =~ "Sprites"

      architecture = page("/docs/architecture")
      assert architecture =~ ~s(href="/docs/primitives")
      refute architecture =~ ~s(.md")

      assert page("/docs/changelog") =~ "Keep a Changelog"
    end

    for {slug, name} <- [{"claude", "Claude Code"}, {"codex", "Codex"}, {"gemini", "Gemini CLI"}] do
      @slug slug
      @name name
      test "#{name} has a titled page with an executable request" do
        html = page("/docs/catalog/runtimes/#{@slug}")
        assert html =~ "<title>Docs · Run #{@name} as an API</title>"

        code =
          Regex.scan(~r{<pre\b[^>]*>(.*?)</pre>}s, html, capture: :all_but_first)
          |> List.flatten()
          |> Enum.join("\n")

        assert code =~ "FOUNTAIN_AGENT_ID"
        assert code =~ "agent_id"
        refute code =~ "--8<--"
        assert html =~ "https://fountain-conversations.demo.managoat.com/"
      end
    end

    test "a missing page has an error page for nginx to answer with" do
      html = page("/docs-404")
      assert html =~ "Page not found"
      assert html =~ ~s(href="/docs")
    end

    test "nothing the app resolved at request time leaked through" do
      html = page("/docs")
      refute html =~ "FountainWeb"
      refute html =~ "csrf-token"
      refute html =~ "phoenix_live_view"
      refute html =~ ~r/posthog/i
    end
  end

  # The server inlined the index into every page; the build writes it once
  # and the page fetches it. `</` cannot close anything in a file of its own,
  # but the index must still decode, and cover every page.
  describe "the search index" do
    test "is valid JSON with one entry per page, and the page fetches it" do
      index = Jason.decode!(read("docs/search-index.json"))
      assert Enum.map(index, & &1["slug"]) == Site.Manual.slugs()
      assert Enum.find(index, &(&1["slug"] == ""))["headings"] != []
      assert page("/docs") =~ ~s|fetch("/docs/search-index.json")|
    end
  end

  describe "/llms.txt" do
    test "is the index, with the API contract and the other two files" do
      body = read("llms.txt")
      assert body =~ "# Fountain"
      assert body =~ "## API contract"
      assert body =~ "/api/openapi.json"
      assert body =~ "#{@base}/llms-full.txt"
      assert body =~ "#{@base}/skill"
    end

    test "links pages of the manual, every one of which exists" do
      body = read("llms.txt")

      for path <- ["/docs/primitives", "/docs/api", "/docs/tour", "/docs/concepts/vault"],
          do: assert(body =~ "](#{@base}#{path})", "expected llms.txt to link #{path}")

      known = MapSet.new(Site.Manual.slugs())

      linked =
        ~r{\]\(https://managoat\.com/docs(/[^)\s]*)?\)}
        |> Regex.scan(body, capture: :all_but_first)
        |> Enum.map(fn
          [] -> ""
          [path] -> String.trim_leading(path, "/")
        end)

      assert length(linked) == length(Site.Llms.slugs())

      for slug <- linked,
          do: assert(MapSet.member?(known, slug), "llms.txt links /docs/#{slug}, not a page")
    end

    # Fountain is not offered as a hosted service; the index must not send an
    # agent to sign up somewhere.
    test "does not sell an instance" do
      refute read("llms.txt") =~ ~r/sign in with GitHub|Public instance/i
    end
  end

  describe "/llms-full.txt" do
    test "is the index, every page it links inlined, then the skill" do
      body = read("llms-full.txt")
      assert body =~ "# Fountain"

      for section <- ["# Get started", "# Concepts", "# API and SDK", "# Catalog"],
          do: assert(body =~ section, "expected llms-full.txt to have section #{section}")

      for slug <- Site.Llms.inlined_slugs(),
          do: assert(body =~ "(`#{Site.Manual.path_for_slug(slug)}`)", "#{slug} is not inlined")

      assert body =~ "SKILL.md (external)"
      assert body =~ "FOUNTAIN_API_KEY"
    end

    test "inlined links carry the host, since nothing is relative to a detached file" do
      body = read("llms-full.txt")
      refute body =~ "](/docs/"
      assert body =~ "](#{@base}/docs/concepts/"
    end
  end

  describe "/skill" do
    test "is the external SKILL.md, at both paths" do
      body = read("skill.txt")
      assert body =~ "---\nname: fountain"
      assert body =~ "FOUNTAIN_API_KEY"
      assert body =~ "fountain apply"
      assert read("skills/fountain/SKILL.md") == body
    end
  end

  test "nginx serves /skill and the llms files as UTF-8 text, and a missing page with the manual's 404" do
    conf = File.read!(Path.expand("../nginx.conf", __DIR__))
    assert conf =~ "location = /skill"
    assert conf =~ "charset utf-8;"
    assert conf =~ "error_page 404 /docs-404.html;"
  end
end
