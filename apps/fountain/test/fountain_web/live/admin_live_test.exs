defmodule FountainWeb.AdminLiveTest do
  use FountainWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Fountain.Accounts

  defp insert_admin(overrides \\ %{}) do
    user = insert_active_user(overrides)
    {:ok, admin} = Accounts.update_user_role(user, "admin")
    admin
  end

  describe "AdminLive.Index — access control" do
    test "admin user can access /admin", %{conn: conn} do
      admin = insert_admin()
      conn = login_user(conn, admin)
      {:ok, _lv, html} = live(conn, ~p"/admin")
      assert html =~ "Admin"
      assert html =~ "Users"
      # An installed extension's figure, rendered by the console from data
      # (ADR 0043).
      assert html =~ Fountain.ExtensionFixtures.Enabled.overview_label()
      # The tile's optional note and link, so the whole `{label, value, opts}`
      # shape is covered rather than just the label.
      assert html =~ "contributed by an extension"
      refute html =~ "Funnel"
    end

    test "regular user is redirected away from /admin", %{conn: conn} do
      user = insert_active_user()
      conn = login_user(conn, user)
      assert {:error, {:live_redirect, _}} = live(conn, ~p"/admin")
    end

    test "unauthenticated user is redirected to login", %{conn: conn} do
      assert {:error, {:redirect, %{to: path}}} = live(conn, ~p"/admin")
      assert path =~ "/auth/login"
    end
  end
end
