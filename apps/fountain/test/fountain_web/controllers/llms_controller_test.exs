defmodule FountainWeb.LlmsControllerTest do
  use FountainWeb.ConnCase, async: true

  describe "GET /llms.txt" do
    test "serves the llms.txt index as plain text", %{conn: conn} do
      conn = get(conn, ~p"/llms.txt")

      assert conn.status == 200

      assert ["text/plain; charset=utf-8"] =
               Plug.Conn.get_resp_header(conn, "content-type")

      body = conn.resp_body
      assert body =~ "# Fountain"
      assert body =~ "## API contract"
      assert body =~ "/api/openapi.json"
      assert body =~ "/llms-full.txt"
      assert body =~ "/skill"
    end

    test "links public /docs pages", %{conn: conn} do
      body = get(conn, ~p"/llms.txt").resp_body

      for slug <- ["/docs/primitives", "/docs/api", "/docs/tour", "/docs/concepts/vault"] do
        assert body =~ slug, "expected llms.txt to link #{slug}"
      end
    end

    test "every /docs page it links is a page Fountain.Docs can serve", %{conn: conn} do
      known = MapSet.new(Fountain.Docs.slugs())

      ~r{\]\(https?://[^/)]+/docs(/[^)\s]*)?\)}
      |> Regex.scan(get(conn, ~p"/llms.txt").resp_body, capture: :all_but_first)
      |> Enum.map(fn
        [] -> ""
        [path] -> String.trim_leading(path, "/")
      end)
      |> Enum.each(fn slug ->
        assert MapSet.member?(known, slug),
               "llms.txt links /docs/#{slug}, which Fountain.Docs does not have"
      end)
    end
  end

  describe "GET /llms-full.txt" do
    test "concatenates the index + the docs corpus + external SKILL.md", %{conn: conn} do
      conn = get(conn, ~p"/llms-full.txt")

      assert conn.status == 200

      assert ["text/plain; charset=utf-8"] =
               Plug.Conn.get_resp_header(conn, "content-type")

      body = conn.resp_body

      # Index is included up top
      assert body =~ "# Fountain"

      # Section headers, then the pages under them, keyed by the /docs path so
      # a reader can go back to the live page.
      for section <- ["# Get started", "# Concepts", "# API and SDK", "# Catalog"] do
        assert body =~ section, "expected llms-full.txt to have section #{section}"
      end

      for path <- ["(`/docs/primitives`)", "(`/docs/api`)", "(`/docs/concepts/vault`)"] do
        assert body =~ path, "expected llms-full.txt to inline #{path}"
      end

      # External SKILL.md tail
      assert body =~ "SKILL.md (external)"
      assert body =~ "FOUNTAIN_API_KEY"
    end

    test "inlines the body of every page the index links", %{conn: conn} do
      body = get(conn, ~p"/llms-full.txt").resp_body

      # A phrase from a page body, not from its blurb in the index.
      assert body =~ "vault"
      assert body =~ "sandbox"

      # The bundle is read detached from any page, so a root-relative link in
      # an inlined body has nothing to be relative to.
      refute body =~ "](/docs/"
      assert body =~ "/docs/concepts/"
    end
  end

  describe "GET /skill" do
    test "serves the external SKILL.md verbatim", %{conn: conn} do
      conn = get(conn, ~p"/skill")

      assert conn.status == 200

      assert ["text/plain; charset=utf-8"] =
               Plug.Conn.get_resp_header(conn, "content-type")

      body = conn.resp_body
      assert body =~ "---\nname: fountain"
      assert body =~ "FOUNTAIN_API_KEY"
      assert body =~ "fountain apply"
    end

    test "is also reachable at /skills/fountain/SKILL.md", %{conn: conn} do
      conn = get(conn, ~p"/skills/fountain/SKILL.md")

      assert conn.status == 200
      assert conn.resp_body =~ "---\nname: fountain"
    end
  end
end
