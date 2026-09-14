defmodule FountainGoogle.ManualTest do
  @moduledoc """
  What the move promised the reader (ADR 0043, #2152): the page keeps its
  URL, and it keeps its place in the sidebar.
  """
  use ExUnit.Case, async: true

  alias Fountain.Manual

  @page "catalog/mcp-servers/fountain-gmail"

  test "the extension is one of the manual's sources here" do
    assert FountainGoogle.Extension.docs() == FountainGoogle.Docs
    assert FountainGoogle.Docs in Manual.extension_manuals()
  end

  test "the page keeps the slug it had as a core page" do
    assert {:ok, %{title: "fountain-gmail"}} = Manual.get(@page)
    assert @page in Manual.slugs()
  end

  test "the URL is unchanged by the move" do
    assert Manual.path_for_slug(@page) == "/docs/catalog/mcp-servers/fountain-gmail"
  end

  test "the core manual does not serve it, so a core distribution has no dead link to it" do
    assert Fountain.Docs.get(@page) == :error
    refute @page in Fountain.Docs.slugs()
  end

  test "the google (connection) page moved with the provider and keeps its URL (#2152 step 4b)" do
    page = "catalog/connections/google"
    assert {:ok, %{title: "google (connection)"}} = Manual.get(page)
    assert Manual.path_for_slug(page) == "/docs/catalog/connections/google"
    assert Fountain.Docs.get(page) == :error
    assert {_, catalog} = Enum.find(Manual.nav(), &match?({"Catalog", _}, &1))
    assert {"google (connection)", page} in catalog
  end

  test "the sidebar puts it back in the Catalog section a reader knows" do
    nav = Manual.nav()

    assert {_, catalog} = Enum.find(nav, &match?({"Catalog", _}, &1))
    assert {"fountain-gmail", @page} in catalog

    # Merged by title rather than appended as a second section with the same
    # name, which is the whole difference between "the page moved" and "the
    # page moved and the sidebar grew a duplicate heading".
    assert Enum.count(nav, &match?({"Catalog", _}, &1)) == 1
  end

  test "the merged search index carries this app's page" do
    Manual.reset_search_index()
    index = Jason.decode!(Manual.search_index_json())
    slugs = Enum.map(index, & &1["slug"])

    assert @page in slugs
    assert "" in slugs, "the core manual's home page should still be indexed"
  after
    Manual.reset_search_index()
  end
end
