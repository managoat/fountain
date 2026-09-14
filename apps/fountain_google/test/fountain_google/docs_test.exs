defmodule FountainGoogle.DocsTest do
  @moduledoc """
  The extension's slice of the manual, held to the host's rules (ADR 0043,
  #2152).

  Deliberately NOT `Managoat.Docs.GuardrailCase`. That template checks a
  **standalone** manual, and a slice is not one: it has no `index.md`, so the
  home-page check fails by construction, and it links back to host pages, which
  its own slug set does not contain.

  So the structural checks run over this app's manual, and the link checks run
  over `Fountain.Manual` — the merged view. That split is the point rather than
  a workaround: a link from here to a host page is valid in every distribution
  that has this app at all, and a link from a HOST page to this one is not,
  which is why `Fountain.DocsTest` checks the core manual on its own.

  No Dockerfile check either. The host declares its compile-time reads against
  the `COPY` list because `docs/` is copied by name; this page arrives under
  `COPY apps ./apps`, which takes the whole tree.
  """
  use ExUnit.Case, async: true

  alias Managoat.Docs.Checks

  defp assert_sound([]), do: :ok
  defp assert_sound(failures), do: flunk(Enum.join(failures, "\n\n"))

  describe "this app's slice" do
    test "every page the nav names exists on disk" do
      FountainGoogle.Docs |> Checks.nav_pages_exist() |> assert_sound()
    end

    test "every page on disk is named in the nav" do
      FountainGoogle.Docs |> Checks.pages_on_disk_named() |> assert_sound()
    end

    test "every page resolves with a title and a body" do
      # `pages_resolve/1`'s home-page arm is skipped: a slice has no index.md.
      # Everything else it asserts is checked here, page by page.
      for slug <- FountainGoogle.Docs.slugs() do
        assert {:ok, %{title: title, body: body}} = FountainGoogle.Docs.get(slug)
        assert is_binary(title) and title != ""
        assert is_binary(body) and String.trim(body) != ""
      end
    end

    test "no authoring syntax survived preprocessing" do
      FountainGoogle.Docs |> Checks.no_leftover_syntax() |> assert_sound()
    end

    test "the search index has one entry per page, and its headings resolve" do
      FountainGoogle.Docs |> Checks.search_index_complete() |> assert_sound()
      FountainGoogle.Docs |> Checks.search_index_headings_resolve() |> assert_sound()
      FountainGoogle.Docs |> Checks.search_index_json_safe() |> assert_sound()
    end

    test "every fence names a language the image bakes a parser for" do
      # The host's `languages:` list is what the Dockerfile bakes, and this
      # page is rendered by the host's pipeline, so it is held to it.
      FountainGoogle.Docs
      |> Checks.fences_baked(~w(text txt plain plaintext))
      |> assert_sound()
    end
  end

  describe "the bundled manual, merged" do
    test "every internal link resolves somewhere in this distribution" do
      Fountain.Manual |> Checks.internal_links_resolve() |> assert_sound()
    end

    test "every internal anchor resolves to a heading on its target page" do
      Fountain.Manual |> Checks.anchors_resolve() |> assert_sound()
    end
  end
end
