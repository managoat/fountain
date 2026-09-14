defmodule FountainMicrosoft.DocsTest do
  @moduledoc """
  The extension's slice of the manual, held to the host's rules (ADR 0043).

  Deliberately NOT `Managoat.Docs.GuardrailCase`: that template checks a
  standalone manual, and a slice has no `index.md` and links back to host
  pages. So the structural checks run over this app's manual, and the link
  checks run over `Fountain.Manual`, the merged view — a link from here to a
  host page is valid in every distribution that has this app at all.
  """
  use ExUnit.Case, async: true

  alias Managoat.Docs.Checks

  defp assert_sound([]), do: :ok
  defp assert_sound(failures), do: flunk(Enum.join(failures, "\n\n"))

  describe "this app's slice" do
    test "every page the nav names exists on disk" do
      FountainMicrosoft.Docs |> Checks.nav_pages_exist() |> assert_sound()
    end

    test "every page on disk is named in the nav" do
      FountainMicrosoft.Docs |> Checks.pages_on_disk_named() |> assert_sound()
    end

    test "every page resolves with a title and a body" do
      for slug <- FountainMicrosoft.Docs.slugs() do
        assert {:ok, %{title: title, body: body}} = FountainMicrosoft.Docs.get(slug)
        assert is_binary(title) and title != ""
        assert is_binary(body) and String.trim(body) != ""
      end
    end

    test "no authoring syntax survived preprocessing" do
      FountainMicrosoft.Docs |> Checks.no_leftover_syntax() |> assert_sound()
    end

    test "the search index has one entry per page, and its headings resolve" do
      FountainMicrosoft.Docs |> Checks.search_index_complete() |> assert_sound()
      FountainMicrosoft.Docs |> Checks.search_index_headings_resolve() |> assert_sound()
      FountainMicrosoft.Docs |> Checks.search_index_json_safe() |> assert_sound()
    end

    test "every fence names a language the image bakes a parser for" do
      FountainMicrosoft.Docs
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
