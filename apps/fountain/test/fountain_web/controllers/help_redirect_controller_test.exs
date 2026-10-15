defmodule FountainWeb.HelpRedirectControllerTest do
  use FountainWeb.ConnCase, async: true

  alias FountainWeb.HelpRedirectController

  @repo_root Path.expand("../../../../..", __DIR__)

  # Unauthenticated on purpose: the target is the public manual, so an old
  # /help link should not detour through sign-in.

  test "GET /help redirects to the manual's home", %{conn: conn} do
    assert redirected_to(get(conn, ~p"/help")) == "https://managoat.com/docs"
  end

  test "a retired topic redirects to the page that took it", %{conn: conn} do
    assert redirected_to(get(conn, ~p"/help/manifest")) ==
             "https://managoat.com/docs/" <> HelpRedirectController.topics()["manifest"]

    assert redirected_to(get(conn, ~p"/help/vaults")) ==
             "https://managoat.com/docs/concepts/vault"
  end

  test "an unknown topic redirects to the manual's home", %{conn: conn} do
    assert redirected_to(get(conn, ~p"/help/no-such-topic")) == "https://managoat.com/docs"
  end

  # The manual is built by site/, not this app (decisions/0081), so the slugs
  # come from the nav file it builds from: every `- Title: file.md` line, with
  # the manual's rule (`index.md` is `""`, `x/index.md` is `x`).
  test "covers every retired topic, and every target is a page of docs/nav.yml" do
    assert Map.keys(HelpRedirectController.topics()) |> Enum.sort() ==
             ~w(agents api environments for-llms manifest quickstart runbook
                secrets-managers skills spawning vaults)

    nav = File.read!(Path.join(@repo_root, "docs/nav.yml"))

    known =
      for [_, file] <- Regex.scan(~r/^\s*- [^:#]+: (\S+\.md)\s*$/m, nav),
          into: MapSet.new() do
        case Path.rootname(file) do
          "index" -> ""
          other -> String.replace_suffix(other, "/index", "")
        end
      end

    assert MapSet.member?(known, "concepts/vault"), "the nav parse found no pages"

    for {topic, slug} <- HelpRedirectController.topics() do
      assert MapSet.member?(known, slug), "/help/#{topic} redirects to unknown /docs/#{slug}"
    end
  end
end
