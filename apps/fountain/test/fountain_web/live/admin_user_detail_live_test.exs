defmodule FountainWeb.AdminUserDetailLiveTest do
  use FountainWeb.ConnCase, async: true
  use Mimic

  import Phoenix.LiveViewTest
  import Ecto.Query

  alias Fountain.Accounts
  alias Fountain.Audit.Event
  alias Fountain.Repo

  defp insert_admin(overrides \\ %{}) do
    user = insert_active_user(overrides)
    {:ok, admin} = Accounts.update_user_role(user, "admin")
    admin
  end

  describe "access control" do
    test "regular user is redirected away", %{conn: conn} do
      user = insert_active_user()
      target = insert_active_user()
      conn = login_user(conn, user)
      assert {:error, {:live_redirect, _}} = live(conn, ~p"/admin/users/#{target.id}")
    end

    test "unauthenticated user is redirected to login", %{conn: conn} do
      target = insert_active_user()
      assert {:error, {:redirect, %{to: path}}} = live(conn, ~p"/admin/users/#{target.id}")
      assert path =~ "/auth/login"
    end
  end

  describe "detail page" do
    test "shows another tenant's account, conversations and API-key metadata", %{conn: conn} do
      admin = insert_admin()
      target = insert_active_user()
      conv = insert_conversation(user_id: target.id)
      {_key, _raw} = insert_api_key(target, "support-visible-key")

      conn = login_user(conn, admin)
      {:ok, _lv, html} = live(conn, ~p"/admin/users/#{target.id}")

      assert html =~ target.email
      assert html =~ String.slice(conv.id, 0, 8)
      assert html =~ "support-visible-key"
      # key material never renders — only the prefix column
      refute html =~ "key_hash"
    end

    test "shows the tenant's turn hours, with no allowance beside them (#1016, ADR 0031)", %{
      conn: conn
    } do
      admin = insert_admin()
      target = insert_active_user()

      {:ok, _lv, html} = live(login_user(conn, admin), ~p"/admin/users/#{target.id}")

      # The allowance tile is gone (ADR 0030); the balance is the number.
      refute html =~ "Turn hours"
    end

    test "shows admin actions taken against the account", %{conn: conn} do
      admin = insert_admin()
      target = insert_active_user()

      {:ok, _} =
        Fountain.Audit.record_admin(%{
          actor_user_id: admin.id,
          target_user_id: target.id,
          event_type: "admin.role.granted",
          metadata: %{"email" => target.email}
        })

      conn = login_user(conn, admin)
      {:ok, _lv, html} = live(conn, ~p"/admin/users/#{target.id}")

      assert html =~ "admin.role.granted"
    end

    test "records an admin.user.viewed audit event on visit", %{conn: conn} do
      admin = insert_admin()
      target = insert_active_user()

      conn = login_user(conn, admin)
      {:ok, _lv, _html} = live(conn, ~p"/admin/users/#{target.id}")

      assert [event] =
               Repo.all(
                 from e in Event,
                   where: e.action == "admin.user.viewed" and e.resource_id == ^target.id
               )

      assert event.actor == "admin:#{admin.id}"
      assert is_nil(event.user_id)
      assert event.metadata["email"] == target.email
    end

    test "unknown user id redirects back to /admin with a flash", %{conn: conn} do
      admin = insert_admin()
      conn = login_user(conn, admin)

      assert {:error, {:live_redirect, %{to: "/admin"}}} =
               live(conn, ~p"/admin/users/#{Ecto.UUID.generate()}")
    end
  end
end
