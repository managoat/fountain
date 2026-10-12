defmodule FountainWeb.LiveviewReconciliationTest do
  use FountainWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Fountain.{Agents, Conversations, Environments, Vaults}

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
    test "agents index survives deleting an already-deleted agent", %{conn: conn, user: user} do
      agent = insert_agent(user_id: user.id)
      {:ok, view, _html} = live(conn, ~p"/agents")

      {:ok, _} = Agents.delete_agent(agent)

      html = render_click(view, "delete", %{"id" => agent.id})
      assert html =~ "may already be deleted"
      assert Process.alive?(view.pid)
    end

    test "environments index survives deleting an already-deleted environment",
         %{conn: conn, user: user} do
      env = insert_env(user_id: user.id)
      {:ok, view, _html} = live(conn, ~p"/environments")

      {:ok, _} = Environments.delete_environment(env)

      html = render_click(view, "delete", %{"id" => env.id})
      assert html =~ "may already be deleted"
      assert Process.alive?(view.pid)
    end

    test "vaults index survives deleting an already-deleted vault", %{conn: conn, user: user} do
      vault = insert_vault(user_id: user.id)
      {:ok, view, _html} = live(conn, ~p"/vaults")

      {:ok, _} = Vaults.delete_vault(vault)

      html = render_click(view, "delete", %{"id" => vault.id})
      assert html =~ "may already be deleted"
      assert Process.alive?(view.pid)
    end

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
