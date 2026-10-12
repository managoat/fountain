defmodule FountainWeb.DocsControllerTest do
  use FountainWeb.ConnCase, async: true

  # All requests here are unauthenticated on purpose: /docs is the public
  # manual, so it sits in the public scope. Since #1008 it is the
  # only place that manual is published, which makes the anonymous case the
  # one that matters most — nobody reading setup.md has an account yet.

  defp search_index_json(body) do
    [_, json] =
      Regex.run(
        ~r{<script type="application/json" id="docs-search-index">(.*?)</script>}s,
        body
      )

    json
  end

  describe "GET /docs" do
    test "serves the home page with the sidebar nav", %{conn: conn} do
      body = conn |> get(~p"/docs") |> html_response(200)
      assert body =~ "multi-tenant"
      # One entry from each nav shape: a top-level page and a section child.
      assert body =~ "Self-host Fountain"
      assert body =~ "Sprites transport reference"
      assert body =~ ~s(href="/docs/integrations/sprites-contract")
    end

    test "the home page has no raw admonition source in it", %{conn: conn} do
      body = conn |> get(~p"/docs") |> html_response(200)
      refute body =~ "!!!"
    end
  end

  describe "GET /docs/:page" do
    # The home page carried the admonition this used to read until #1390 made
    # its "in a hurry" box a snippet include — an admonition indents its body,
    # and an indented `--8<--` is left unexpanded. The quickstart carries one
    # now, so the rendering is still pinned to a real page.
    test "renders an admonition as a blockquote, not its raw source syntax", %{conn: conn} do
      body = conn |> get(~p"/docs/quickstart") |> html_response(200)
      assert body =~ "Whose model key"
      refute body =~ "!!!"
    end

    test "serves a top-level page", %{conn: conn} do
      body = conn |> get(~p"/docs/setup") |> html_response(200)
      assert body =~ "Setup"
    end

    test "serves a nested integrations page", %{conn: conn} do
      body = conn |> get(~p"/docs/integrations/sprites-contract") |> html_response(200)
      assert body =~ "Sprites"
    end

    test "rewrites internal links to /docs paths", %{conn: conn} do
      body = conn |> get(~p"/docs/architecture") |> html_response(200)
      assert body =~ ~s(href="/docs/primitives")
      refute body =~ ~s(.md")
    end

    test "serves the changelog with the repo-root CHANGELOG inlined", %{conn: conn} do
      body = conn |> get(~p"/docs/changelog") |> html_response(200)
      assert body =~ "Keep a Changelog"
    end

    test "404s on unknown pages", %{conn: conn} do
      assert conn |> get(~p"/docs/nope") |> html_response(404) =~ "Page not found"

      assert conn |> get("/docs/integrations/nope/deeper") |> html_response(404) =~
               "Page not found"
    end
  end

  describe "runtime landing pages" do
    for {slug, name} <- [
          {"claude", "Claude Code"},
          {"codex", "Codex"},
          {"gemini", "Gemini CLI"}
        ] do
      @slug slug
      @name name
      test "#{name} has a titled page with an executable request", %{conn: conn} do
        body = conn |> get("/docs/catalog/runtimes/#{@slug}") |> html_response(200)
        assert body =~ "<title>Docs · Run #{@name} as an API</title>"

        code =
          Regex.scan(~r{<pre\b[^>]*>(.*?)</pre>}s, body, capture: :all_but_first)
          |> List.flatten()
          |> Enum.join("\n")

        assert code =~ "FOUNTAIN_AGENT_ID"
        assert code =~ "agent_id"
        refute code =~ "--8<--"
        assert body =~ "https://fountain-conversations.demo.managoat.com/"
      end
    end
  end

  # The search index (#1009) is served as a `<script type="application/json">`
  # block the page's own JS reads with `JSON.parse`. HEEx treats a `<script>`
  # body as raw text and does not interpolate `{...}` inside one, so the
  # difference between the curly form and `<%= %>` is the difference between a
  # working index and a literal expression that throws on the first parse —
  # invisibly, since the input still renders. The unit tests in
  # `Fountain.Docs` cannot see this; only rendering the page can.
  describe "the search index in the rendered page" do
    test "is emitted as JSON the browser can parse", %{conn: conn} do
      body = conn |> get(~p"/docs") |> html_response(200)

      json = search_index_json(body)
      refute json =~ "search_index_json", "the expression rendered verbatim instead of its value"

      decoded = Jason.decode!(json)
      assert length(decoded) == length(Fountain.Docs.search_index())

      home = Enum.find(decoded, &(&1["slug"] == ""))
      assert home["title"] != ""
      assert is_list(home["headings"])
    end

    test "is served on a nested page too, with the same content", %{conn: conn} do
      home = conn |> get(~p"/docs") |> html_response(200) |> search_index_json()

      nested =
        conn
        |> get(~p"/docs/integrations/sprites-contract")
        |> html_response(200)
        |> search_index_json()

      assert Jason.decode!(nested) == Jason.decode!(home)
    end
  end
end
