defmodule FountainWeb.HelpRedirectControllerTest do
  use FountainWeb.ConnCase, async: true

  alias FountainWeb.HelpRedirectController

  # Unauthenticated on purpose: the target is the public manual, so an old
  # /help link should not detour through sign-in.

  test "GET /help redirects to the manual's home", %{conn: conn} do
    assert redirected_to(get(conn, ~p"/help")) == "/docs"
  end

  test "a retired topic redirects to the page that took it", %{conn: conn} do
    assert redirected_to(get(conn, ~p"/help/manifest")) ==
             "/docs/" <> HelpRedirectController.topics()["manifest"]

    assert redirected_to(get(conn, ~p"/help/vaults")) == "/docs/concepts/vault"
  end

  test "an unknown topic redirects to the manual's home", %{conn: conn} do
    assert redirected_to(get(conn, ~p"/help/no-such-topic")) == "/docs"
  end

  test "covers every retired topic, and every target is a page /docs serves" do
    assert Map.keys(HelpRedirectController.topics()) |> Enum.sort() ==
             ~w(agents api environments for-llms manifest quickstart runbook
                secrets-managers skills spawning vaults)

    known = MapSet.new(Fountain.Docs.slugs())

    for {topic, slug} <- HelpRedirectController.topics() do
      assert MapSet.member?(known, slug), "/help/#{topic} redirects to unknown /docs/#{slug}"
    end
  end
end
