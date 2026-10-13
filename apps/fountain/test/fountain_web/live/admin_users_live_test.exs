defmodule FountainWeb.AdminUsersLiveTest do
  use FountainWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Fountain.Accounts

  defp insert_admin(overrides \\ %{}) do
    user = insert_active_user(overrides)
    {:ok, admin} = Accounts.update_user_role(user, "admin")
    admin
  end

  describe "AdminLive.Users — user list" do
    test "displays all users", %{conn: conn} do
      admin = insert_admin()
      other = insert_active_user()
      conn = login_user(conn, admin)
      {:ok, _lv, html} = live(conn, ~p"/admin/users")

      assert html =~ admin.email
      assert html =~ other.email
    end
  end

  describe "AdminLive.Users — toggle_admin" do
    test "promotes a regular user to admin", %{conn: conn} do
      admin = insert_admin()
      target = insert_active_user()
      conn = login_user(conn, admin)
      {:ok, lv, _html} = live(conn, ~p"/admin/users")

      lv |> element("button[phx-value-id='#{target.id}']", "Make admin") |> render_click()

      updated = Accounts.get_user!(target.id)
      assert updated.role == "admin"
    end

    test "demotes an admin to regular user", %{conn: conn} do
      admin = insert_admin()
      target = insert_admin()
      conn = login_user(conn, admin)
      {:ok, lv, _html} = live(conn, ~p"/admin/users")

      lv |> element("button[phx-value-id='#{target.id}']", "Remove admin") |> render_click()

      updated = Accounts.get_user!(target.id)
      assert updated.role == "user"
    end
  end

  describe "AdminLive.Users — :refresh handle_info" do
    test "page re-renders on :refresh message without error", %{conn: conn} do
      admin = insert_admin()
      conn = login_user(conn, admin)
      {:ok, lv, _html} = live(conn, ~p"/admin/users")

      # Send the refresh message directly; the page should still render
      send(lv.pid, :refresh)
      html = render(lv)
      assert html =~ "Admin"
      assert html =~ "Users"
    end

    test ":refresh picks up newly inserted users", %{conn: conn} do
      admin = insert_admin()
      conn = login_user(conn, admin)
      {:ok, lv, html_before} = live(conn, ~p"/admin/users")

      new_user = insert_active_user()

      send(lv.pid, :refresh)
      html_after = render(lv)

      refute html_before =~ new_user.email
      assert html_after =~ new_user.email
    end
  end

  describe "AdminLive.Users — user list formatting" do
    test "shows joined date for each user", %{conn: conn} do
      admin = insert_admin()
      conn = login_user(conn, admin)
      {:ok, _lv, html} = live(conn, ~p"/admin/users")

      # inserted_at is always set so date column should have a year
      assert html =~ to_string(Date.utc_today().year)
    end
  end

  describe "AdminLive.Users — active sandboxes" do
    test "shows each user's active sandbox count", %{conn: conn} do
      admin = insert_admin()
      insert_sandbox(user_id: admin.id, status: "ready")
      insert_sandbox(user_id: admin.id, status: "pending")

      conn = login_user(conn, admin)
      {:ok, lv, html} = live(conn, ~p"/admin/users")

      assert html =~ "Sandboxes"
      refute has_element?(lv, "#sandbox-limit-#{admin.id}")
    end
  end

  describe "AdminLive.Users — suspend (#287)" do
    test "suspends and unsuspends with audit events and a badge", %{conn: conn} do
      admin = insert_admin()
      target = insert_active_user()
      insert_sandbox(user_id: target.id, status: "ready")
      conn = login_user(conn, admin)
      {:ok, lv, _html} = live(conn, ~p"/admin/users")

      html =
        lv
        |> element("button[phx-click='toggle_suspend'][phx-value-id='#{target.id}']")
        |> render_click()

      assert Fountain.Accounts.suspended?(Fountain.Repo.reload!(target))
      assert html =~ "suspended"
      assert html =~ "Unsuspend"
      assert html =~ "1 sandbox(es) reaped"

      html =
        lv
        |> element("button[phx-click='toggle_suspend'][phx-value-id='#{target.id}']")
        |> render_click()

      refute Fountain.Accounts.suspended?(Fountain.Repo.reload!(target))
      assert html =~ "Suspension lifted"

      events = Fountain.Audit._unsafe_list_recent_admin(10)
      assert Enum.any?(events, &(&1.event_type == "admin.account.suspended"))
      assert Enum.any?(events, &(&1.event_type == "admin.account.unsuspended"))
    end

    test "an admin cannot suspend themselves", %{conn: conn} do
      admin = insert_admin()
      conn = login_user(conn, admin)
      {:ok, lv, _html} = live(conn, ~p"/admin/users")

      render_click(lv, "toggle_suspend", %{"id" => admin.id})

      refute Fountain.Accounts.suspended?(Fountain.Repo.reload!(admin))
      assert render(lv) =~ "cannot suspend your own account"
    end
  end

  describe "AdminLive.Users — search, filter, sort" do
    # The layout renders the logged-in admin's email in the nav, so negative
    # assertions must target a third user, never the admin.
    test "?q= narrows the table to matching emails", %{conn: conn} do
      admin = insert_admin()
      needle = insert_active_user(%{email: "needle@example.com"})
      straw = insert_active_user(%{email: "straw@example.com"})
      conn = login_user(conn, admin)

      {:ok, _lv, html} = live(conn, ~p"/admin/users?q=needle")

      assert html =~ needle.email
      refute html =~ straw.email
    end

    test "typing in the search box patches the URL and filters", %{conn: conn} do
      admin = insert_admin()
      needle = insert_active_user(%{email: "needle@example.com"})
      straw = insert_active_user(%{email: "straw@example.com"})
      conn = login_user(conn, admin)
      {:ok, lv, _html} = live(conn, ~p"/admin/users")

      html =
        lv
        |> form("#user-filters")
        |> render_change(%{"q" => "needle", "status" => "", "role" => "", "verified" => ""})

      assert_patch(lv, ~p"/admin/users?q=needle")
      assert html =~ needle.email
      refute html =~ straw.email
    end

    test "filters by verification state and badges unverified users", %{conn: conn} do
      admin = insert_admin()
      verified = insert_active_user(%{email: "is-verified@example.com"})
      unverified = insert_user()
      conn = login_user(conn, admin)

      {:ok, _lv, html} = live(conn, ~p"/admin/users?verified=no")
      assert html =~ unverified.email
      assert html =~ "unverified"
      refute html =~ verified.email
    end

    test "sorts by email via the header link", %{conn: conn} do
      admin = insert_admin()
      insert_active_user(%{email: "zzz-sort@example.com"})
      insert_active_user(%{email: "aaa-sort@example.com"})
      conn = login_user(conn, admin)
      {:ok, lv, _html} = live(conn, ~p"/admin/users")

      html = lv |> element("thead a", "Email") |> render_click()
      assert_patch(lv, ~p"/admin/users?dir=asc&sort=email")

      # Each email appears several times per row (confirm dialogs etc.);
      # first-appearance order is what reflects row order.
      assert Regex.scan(~r/(?:aaa|zzz)-sort@example\.com/, html)
             |> List.flatten()
             |> Enum.uniq() ==
               ["aaa-sort@example.com", "zzz-sort@example.com"]
    end

    test "shows an empty state when nothing matches", %{conn: conn} do
      admin = insert_admin()
      conn = login_user(conn, admin)

      {:ok, _lv, html} = live(conn, ~p"/admin/users?q=no-such-user")
      assert html =~ "No users match."
    end
  end

  describe "AdminLive.Users — pagination" do
    # Bypasses register_user: 26 bcrypt hashes in one test is pure drag, and
    # this test needs rows, not the registration pipeline.
    defp insert_bare_users(count) do
      for i <- 1..count do
        Fountain.Repo.insert!(%Fountain.Accounts.User{
          email: "bulk-#{i}-#{System.unique_integer([:positive])}@example.com",
          password_hash: "not-a-real-hash"
        })
      end
    end

    test "shows 25 rows per page and preserves the page across refresh", %{conn: conn} do
      admin = insert_admin()

      # Back-date the admin so ascending order puts them firmly on page 1 —
      # same-second inserts would otherwise tie-break on random uuid.
      earlier = DateTime.add(DateTime.utc_now(), -60, :second) |> DateTime.truncate(:second)
      Fountain.Repo.update!(Ecto.Changeset.change(admin, inserted_at: earlier))

      insert_bare_users(26)
      conn = login_user(conn, admin)

      {:ok, lv, html} = live(conn, ~p"/admin/users?page=2&dir=asc")

      # 27 users total (admin + 26): page 2 holds exactly the last two
      assert html =~ "Page 2 of 2"
      assert html =~ "27 accounts"

      page2_emails =
        Regex.scan(~r/bulk-\d+-\d+@example\.com/, html) |> List.flatten() |> Enum.uniq()

      assert length(page2_emails) == 2

      send(lv.pid, :refresh)
      assert render(lv) =~ "Page 2 of 2"
    end

    test "prev/next links walk the pages", %{conn: conn} do
      admin = insert_admin()
      insert_bare_users(26)
      conn = login_user(conn, admin)

      {:ok, lv, _html} = live(conn, ~p"/admin/users")

      lv |> element("a", "next →") |> render_click()
      assert_patch(lv, ~p"/admin/users?page=2")

      lv |> element("a", "← prev") |> render_click()
      assert_patch(lv, ~p"/admin/users")
    end

    test "no pagination controls when everything fits on one page", %{conn: conn} do
      admin = insert_admin()
      conn = login_user(conn, admin)

      {:ok, _lv, html} = live(conn, ~p"/admin/users")
      refute html =~ "Page 1 of"
    end
  end

  describe "AdminLive.Users — usage column" do
    test "shows 30-day usage per user", %{conn: conn} do
      admin = insert_admin()
      user = insert_active_user()

      {:ok, _} =
        Fountain.Usage.record_usage(user.id, "turn_started", nil, nil, %{
          "conversation_id" => Ecto.UUID.generate()
        })

      conn = login_user(conn, admin)
      {:ok, _lv, html} = live(conn, ~p"/admin/users")

      assert html =~ "1c · 1t · 0m"
    end
  end
end

defmodule FountainWeb.AdminUsersLiveErrorTest do
  use FountainWeb.ConnCase, async: false
  use Mimic

  import Phoenix.LiveViewTest

  alias Fountain.Accounts

  defp insert_admin(overrides \\ %{}) do
    user = insert_active_user(overrides)
    {:ok, admin} = Accounts.update_user_role(user, "admin")
    admin
  end

  describe "AdminLive.Users — toggle_admin error path" do
    test "shows error flash when update_user_role fails", %{conn: conn} do
      admin = insert_admin()
      target = insert_active_user()
      conn = login_user(conn, admin)
      {:ok, lv, _html} = live(conn, ~p"/admin/users")

      # Arity 3: the admin surface passes actor: "admin" through so the
      # context can attribute the event it now records itself (#552).
      stub(Accounts, :update_user_role, fn _user, _role, _opts ->
        {:error, %Ecto.Changeset{}}
      end)

      lv |> element("button[phx-value-id='#{target.id}']", "Make admin") |> render_click()

      html = render(lv)
      assert html =~ "Failed to update role"
    end
  end
end
