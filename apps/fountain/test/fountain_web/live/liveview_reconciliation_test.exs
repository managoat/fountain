defmodule FountainWeb.LiveviewReconciliationTest do
  use FountainWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  # Regression tests for #401: LiveView state loaded at mount and never
  # reconciled — delete handlers that crashed on rows deleted elsewhere, and
  # an unmapped `idle` badge.
  #
  # Three of #401's six items lived on the conversation pages, which are the
  # standalone app's now (#867). What they pinned did not go with them:
  # the `conv:<id>` topic is what `GET /api/conversations/:id/stream` reads
  # (conversation_events_controller_test.exs).

  setup %{conn: conn} do
    user = insert_verified_user()
    {:ok, conn: login_user(conn, user), user: user}
  end

  describe "delete handlers on stale rows (#401 item 3)" do
    test "admin actions flash instead of crashing on a deleted user", %{conn: conn} do
      admin = insert_verified_user(role: "admin")
      victim = insert_verified_user()
      conn = login_user(conn, admin)

      {:ok, view, _html} = live(conn, ~p"/admin/users")

      {:ok, _} = Fountain.Repo.delete(victim)

      html = render_click(view, "toggle_admin", %{"id" => victim.id})
      assert html =~ "may have been deleted"
      assert Process.alive?(view.pid)
    end
  end

  describe "idle badge (#401 item 6)" do
    test "idle renders with the healthy colour, not the unknown-value grey" do
      html = render_component(&FountainWeb.CoreComponents.badge/1, status: "idle")
      assert html =~ "status-ready-bg"

      unknown = render_component(&FountainWeb.CoreComponents.badge/1, status: "wat")
      refute unknown =~ "status-ready-bg"
    end
  end
end
