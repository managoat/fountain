defmodule FountainSlack.ManualTest do
  @moduledoc """
  What the move promised the reader (ADR 0043, ADR 0054): the page keeps its
  URL, and it keeps its place in the sidebar.
  """
  use ExUnit.Case, async: true

  alias Fountain.Manual

  @page "catalog/connections/slack"

  test "the extension's manual is one of the merged sources" do
    assert FountainSlack.Extension.docs() == FountainSlack.Docs
    assert FountainSlack.Docs in Manual.extension_manuals()
  end

  test "the page keeps the slug and the URL it had as a core page" do
    assert {:ok, %{title: "slack (connection)"}} = Manual.get(@page)
    assert @page in Manual.slugs()
    assert Manual.path_for_slug(@page) == "/docs/catalog/connections/slack"
  end

  test "the core manual does not serve it, so a core distribution has no dead link to it" do
    assert Fountain.Docs.get(@page) == :error
    refute @page in Fountain.Docs.slugs()

    # and no core page links to it: the core manual is checked on its own by
    # Fountain.DocsTest, which would fail on such a link. (The redirect URI
    # `/connections/slack/callback` is prose about the provider, not a
    # link to its page.)
    for slug <- Fountain.Docs.slugs(), {:ok, %{body: body}} = Fountain.Docs.get(slug) do
      refute body =~ "/docs/catalog/connections/slack",
             "#{slug} links to the extension's page"
    end
  end

  test "the sidebar puts it back in the Catalog section" do
    nav = Manual.nav()

    assert {_, catalog} = Enum.find(nav, &match?({"Catalog", _}, &1))
    assert {"slack (connection)", @page} in catalog
    assert Enum.count(nav, &match?({"Catalog", _}, &1)) == 1
  end

  test "the merged search index carries the page" do
    Manual.reset_search_index()
    index = Jason.decode!(Manual.search_index_json())
    assert @page in Enum.map(index, & &1["slug"])
  after
    Manual.reset_search_index()
  end
end
