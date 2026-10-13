defmodule FountainWeb.InferenceCredentialSetsLiveTest do
  @moduledoc """
  The credential-sets half of `/account/inference-credentials` (ADR 0053
  decision 1).

  The property the first two tests pin is the one that matters most: an
  account that never wants a second subscription should not have to learn
  what a set is to paste a key.
  """

  use FountainWeb.ConnCase, async: true
  use Mimic

  import Phoenix.LiveViewTest

  alias Fountain.Crypto
  alias Fountain.InferenceCredentials

  @path "/account/inference-credentials"

  setup %{conn: conn} do
    # The page pings the provider before it stores anything; these tests are
    # about which set the value lands in, not about the ping.
    stub(Req, :get, fn _url, _opts -> {:ok, %Req.Response{status: 200}} end)

    user = insert_verified_user()
    %{conn: login_user(conn, user), user: user}
  end

  describe "an account with at most one set" do
    test "never sees the set controls", %{conn: conn, user: user} do
      {:ok, dek} = Crypto.load_tenant_key(user.id)
      {:ok, _} = InferenceCredentials.put_credential(user.id, dek, :anthropic_api_key, "sk-one")

      {:ok, view, _html} = live(conn, @path)

      refute has_element?(view, "button[phx-click='select_set']")
      refute has_element?(view, "button[phx-click='make_default']")
      # The way to get a second one is still offered.
      assert has_element?(view, "form[phx-submit='create_set']")
    end

    test "a first write still creates the default set", %{conn: conn, user: user} do
      assert InferenceCredentials.list_sets(user.id) == []

      {:ok, view, _html} = live(conn, @path)

      view
      |> element("#credential-anthropic_api_key")
      |> render_submit(%{"provider" => "anthropic_api_key", "value" => "sk-first"})

      assert [%{name: "Default", is_default: true}] = InferenceCredentials.list_sets(user.id)
    end
  end

  describe "with a second set" do
    setup %{user: user} do
      {:ok, dek} = Crypto.load_tenant_key(user.id)

      {:ok, _} =
        InferenceCredentials.put_credential(user.id, dek, :anthropic_api_key, "sk-default")

      {:ok, second} = InferenceCredentials.create_set(user.id, "Second subscription")
      %{dek: dek, second: second}
    end

    test "the tabs appear, the default is marked, and selecting one switches the rows", %{
      conn: conn,
      second: second
    } do
      {:ok, view, html} = live(conn, @path)

      assert html =~ "Second subscription"
      assert html =~ "default"

      # The default set holds an Anthropic key; the second holds nothing, so
      # switching has to change what the provider rows report.
      assert has_element?(
               view,
               "button[phx-click='clear'][phx-value-provider='anthropic_api_key']"
             )

      view |> element("button[phx-value-id='#{second.id}']") |> render_click()

      refute has_element?(
               view,
               "button[phx-click='clear'][phx-value-provider='anthropic_api_key']"
             )
    end

    test "a credential typed while a set is selected lands in that set", %{
      conn: conn,
      user: user,
      dek: dek,
      second: second
    } do
      {:ok, view, _html} = live(conn, @path)
      view |> element("button[phx-value-id='#{second.id}']") |> render_click()

      view
      |> element("#credential-gemini_api_key")
      |> render_submit(%{"provider" => "gemini_api_key", "value" => "AIza-second"})

      {:ok, in_second} =
        InferenceCredentials.decrypted_for_set(Fountain.Repo.reload!(second), dek)

      {:ok, in_default} = InferenceCredentials.decrypted_for_user(user.id, dek)

      assert in_second[:gemini_api_key] == "AIza-second"
      refute Map.has_key?(in_default, :gemini_api_key)
    end

    test "a stale selected set refuses writes and leaves the default alone", %{
      conn: conn,
      user: user,
      dek: dek,
      second: second
    } do
      {:ok, view, _} = live(conn, @path)
      view |> element("button[phx-value-id='#{second.id}']") |> render_click()
      {:ok, _} = InferenceCredentials.delete_set(second)

      html =
        view
        |> element("#credential-anthropic_api_key")
        |> render_submit(%{"provider" => "anthropic_api_key", "value" => "misdirected"})

      assert html =~ "no longer available"

      assert {:ok, %{anthropic_api_key: "sk-default"}} =
               InferenceCredentials.decrypted_for_user(user.id, dek)
    end

    test "a missing selection does not silently retarget a later write", %{
      conn: conn,
      user: user,
      dek: dek
    } do
      {:ok, view, _} = live(conn, @path)
      assert render_click(view, "select_set", %{"id" => "nope"}) =~ "no longer available"

      html =
        view
        |> element("#credential-anthropic_api_key")
        |> render_submit(%{"provider" => "anthropic_api_key", "value" => "misdirected"})

      assert html =~ "no longer available"

      assert {:ok, %{anthropic_api_key: "sk-default"}} =
               InferenceCredentials.decrypted_for_user(user.id, dek)
    end

    test "renaming and promoting", %{conn: conn, user: user, second: second} do
      {:ok, view, _html} = live(conn, @path)
      view |> element("button[phx-value-id='#{second.id}']") |> render_click()

      view |> element("form[phx-submit='rename_set']") |> render_submit(%{"name" => "Renamed"})
      assert Fountain.Repo.reload!(second).name == "Renamed"

      view |> element("button[phx-click='make_default']") |> render_click()
      assert InferenceCredentials.get_for_user(user.id).id == second.id
    end

    for event <- ["rename_set", "make_default", "delete_set"] do
      test "#{event} recovers a deleted selection and requires a new choice", %{
        conn: conn,
        user: user,
        dek: dek,
        second: second
      } do
        default = InferenceCredentials.get_for_user(user.id)
        {:ok, view, _} = live(conn, @path)
        view |> element("button[phx-value-id='#{second.id}']") |> render_click()
        {:ok, _} = InferenceCredentials.delete_set(second)

        html =
          if unquote(event) == "rename_set" do
            view |> element("form[phx-submit='rename_set']") |> render_submit(%{"name" => "Gone"})
          else
            view |> element("button[phx-click='#{unquote(event)}']") |> render_click()
          end

        assert html =~ "no longer available"
        refute has_element?(view, "button[phx-value-id='#{second.id}']")
        refute has_element?(view, "form[phx-submit='rename_set']")
        assert has_element?(view, "button[phx-value-id='#{default.id}']")

        reject(Req, :get, 2)

        assert view
               |> element("#credential-anthropic_api_key")
               |> render_submit(%{"value" => "must-not-retarget"}) =~ "no longer available"

        assert {:ok, %{anthropic_api_key: "sk-default"}} =
                 InferenceCredentials.decrypted_for_user(user.id, dek)

        view |> element("button[phx-value-id='#{default.id}']") |> render_click()

        view
        |> element("button[phx-click='clear'][phx-value-provider='anthropic_api_key']")
        |> render_click()

        assert {:ok, %{}} = InferenceCredentials.decrypted_for_user(user.id, dek)
      end
    end

    # The default cannot go, and the page says why rather than hiding the
    # button and leaving the reader to guess.
    test "the default offers no delete, and a non-default one does", %{
      conn: conn,
      second: second
    } do
      {:ok, view, _html} = live(conn, @path)

      # Default is selected on mount.
      refute has_element?(view, "button[phx-click='delete_set']")

      view |> element("button[phx-value-id='#{second.id}']") |> render_click()
      assert has_element?(view, "button[phx-click='delete_set']")

      view |> element("button[phx-click='delete_set']") |> render_click()
      assert is_nil(Fountain.Repo.reload(second))
    end

    test "a duplicate name is reported rather than swallowed", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)

      html =
        view
        |> element("form[phx-submit='create_set']")
        |> render_submit(%{"name" => "Second subscription"})

      assert html =~ "already names a credential set"
    end
  end
end
