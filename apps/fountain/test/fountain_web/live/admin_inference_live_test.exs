defmodule FountainWeb.AdminInferenceLiveTest do
  @moduledoc """
  `/admin/inference`: the page reads and writes only through
  `Fountain.PlatformInference`, so what is asserted here is the door — who
  may open it, what it shows, and that a save or a clear lands as a stored
  row and a privilege-trail event. The resolution rules (stored beats the
  variable, the fallback on clear) are `platform_inference_test.exs`'s.

  No `Application.put_env` here, so the file stays async: every fixture is a
  row in the sandboxed database.
  """

  use FountainWeb.ConnCase, async: true

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest

  alias Fountain.Accounts
  alias Fountain.PlatformInference
  alias Fountain.Repo

  defp insert_admin do
    user = insert_active_user()
    {:ok, admin} = Accounts.update_user_role(user, "admin")
    admin
  end

  describe "access control" do
    test "an admin can open the page and sees one card per provider", %{conn: conn} do
      conn = login_user(conn, insert_admin())
      {:ok, _lv, html} = live(conn, ~p"/admin/inference")

      assert html =~ "Inference"
      assert html =~ "Anthropic"
      assert html =~ "OpenAI"
      assert html =~ "Google"
      refute html =~ "PLATFORM_INFERENCE_DAILY_CENTS"
    end

    test "a regular user is sent to the dashboard", %{conn: conn} do
      conn = login_user(conn, insert_active_user())
      assert {:error, {:live_redirect, _}} = live(conn, ~p"/admin/inference")
    end

    test "an anonymous visitor is sent to login", %{conn: conn} do
      assert {:error, {:redirect, %{to: path}}} = live(conn, ~p"/admin/inference")
      assert path =~ "/auth/login"
    end

    test "the tab is in the admin bar", %{conn: conn} do
      conn = login_user(conn, insert_admin())
      {:ok, _lv, html} = live(conn, ~p"/admin")
      assert html =~ ~s(href="/admin/inference")
    end
  end

  describe "saving a key" do
    test "stores it, shows its tail and who set it, and records the admin event", %{conn: conn} do
      admin = insert_admin()
      conn = login_user(conn, admin)
      {:ok, lv, _html} = live(conn, ~p"/admin/inference")

      html =
        render_submit(lv, "set_key", %{"provider" => "openai", "value" => "sk-live-key-9876"})

      assert html =~ "OpenAI key saved"
      assert html =~ "set in admin"
      assert html =~ "…9876"
      assert html =~ admin.email
      refute html =~ "sk-live-key"

      assert PlatformInference.key_for("openai") == {:ok, :openai_api_key, "sk-live-key-9876"}

      assert [event] =
               Repo.all(
                 from e in Fountain.Audit.AdminEvent,
                   where: e.event_type == "admin.platform_inference_key.set"
               )

      assert event.actor_user_id == admin.id
      assert event.metadata["provider"] == "openai"
    end

    test "a value that is not a key is refused and nothing is stored", %{conn: conn} do
      conn = login_user(conn, insert_admin())
      {:ok, lv, _html} = live(conn, ~p"/admin/inference")

      html = render_submit(lv, "set_key", %{"provider" => "anthropic", "value" => "   "})

      assert html =~ "does not look like a key"
      assert PlatformInference.key_for("anthropic") == :none
      refute html =~ "set in admin"
    end
  end

  describe "clearing a key" do
    test "removes the stored row and the Clear button with it", %{conn: conn} do
      admin = insert_admin()
      {:ok, _} = PlatformInference.put_key("google", "AIza-stored-key", actor_user_id: admin.id)

      conn = login_user(conn, admin)
      {:ok, lv, html} = live(conn, ~p"/admin/inference")
      assert has_element?(lv, "button[phx-click=clear_key][phx-value-provider=google]")
      assert html =~ "set in admin"

      html =
        lv
        |> element("button[phx-click=clear_key][phx-value-provider=google]")
        |> render_click()

      assert html =~ "Google key cleared"
      refute has_element?(lv, "button[phx-click=clear_key][phx-value-provider=google]")
      assert PlatformInference.key_for("google") == :none

      assert Repo.exists?(
               from e in Fountain.Audit.AdminEvent,
                 where: e.event_type == "admin.platform_inference_key.cleared"
             )
    end

    test "there is no Clear button for a provider with nothing stored", %{conn: conn} do
      conn = login_user(conn, insert_admin())
      {:ok, lv, _html} = live(conn, ~p"/admin/inference")
      refute has_element?(lv, "button[phx-click=clear_key]")
    end
  end
end
