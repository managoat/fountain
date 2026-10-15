defmodule FountainWeb.DocsRedirectControllerTest do
  # Mutates :fountain, :docs_url in two tests.
  use FountainWeb.ConnCase, async: false

  # The manual and its llms.txt files are a static build in site/
  # (decisions/0081); every path the server used to serve them on is a
  # permanent redirect to the same path at DOCS_URL. Unauthenticated on
  # purpose: the manual is public.

  test "every path the server served the manual on redirects, permanently, path kept",
       %{conn: conn} do
    for path <- ~w(/docs /docs/quickstart /docs/catalog/runtimes/claude /llms.txt
                   /llms-full.txt /skill /skills/managoat/SKILL.md
                   /skills/fountain/SKILL.md) do
      conn = get(conn, path)
      assert conn.status == 301, path
      assert redirected_to(conn, 301) == "https://managoat.com" <> path
    end
  end

  test "an anchor-free query string survives the hop", %{conn: conn} do
    assert redirected_to(get(conn, "/docs/api?x=1"), 301) == "https://managoat.com/docs/api?x=1"
  end

  test "/api/docs is still the instance's own Swagger UI", %{conn: conn} do
    assert conn |> get("/api/docs") |> html_response(200) =~ "swagger"
  end

  describe "DOCS_URL" do
    setup do
      previous = Application.get_env(:fountain, :docs_url)
      on_exit(fn -> Application.put_env(:fountain, :docs_url, previous) end)
      :ok
    end

    test "moves the target, trailing slash or not", %{conn: conn} do
      Application.put_env(:fountain, :docs_url, "https://docs.example.com/")
      assert redirected_to(get(conn, "/docs/api"), 301) == "https://docs.example.com/docs/api"
    end

    test "naming this host answers 404 rather than redirecting to itself", %{conn: conn} do
      Application.put_env(:fountain, :docs_url, "https://#{conn.host}")
      conn = get(conn, "/docs")
      assert conn.status == 404
      assert conn.resp_body =~ "DOCS_URL"
    end
  end
end
