defmodule Fountain.AccountsAdminListingTest do
  use Fountain.DataCase, async: true

  alias Fountain.Accounts

  describe "list_users_admin/1 — search and filters" do
    test "search matches an email substring, case-insensitively" do
      match = insert_verified_user(%{email: "alice.smith@example.com"})
      _other = insert_verified_user(%{email: "bob@example.com"})

      %{users: users, total: 1} = Accounts.list_users_admin(search: "ALICE.smi")
      assert [%{id: id}] = users
      assert id == match.id
    end

    test "search treats SQL LIKE metacharacters as literals" do
      _user = insert_verified_user(%{email: "underscore@example.com"})

      # "_" would match any character if passed through unescaped
      assert %{users: [], total: 0} = Accounts.list_users_admin(search: "_nderscore@example")
    end

    test "filters by role" do
      user = insert_verified_user()
      {:ok, admin} = Accounts.update_user_role(insert_verified_user(), "admin")

      %{users: admins} = Accounts.list_users_admin(role: "admin")
      assert Enum.map(admins, & &1.id) == [admin.id]

      %{users: users} = Accounts.list_users_admin(role: "user")
      assert Enum.map(users, & &1.id) == [user.id]
    end

    test "filters by verification state" do
      verified = insert_verified_user()
      unverified = insert_user()

      %{users: v} = Accounts.list_users_admin(verified: true)
      assert Enum.map(v, & &1.id) == [verified.id]

      %{users: u} = Accounts.list_users_admin(verified: false)
      assert Enum.map(u, & &1.id) == [unverified.id]
    end

    test "filters combine" do
      _wrong_role = insert_verified_user(%{email: "combo-a@example.com"})
      _wrong_email = insert_verified_user(%{email: "other@example.com"})

      {:ok, match} =
        Accounts.update_user_role(insert_verified_user(%{email: "combo-b@example.com"}), "admin")

      %{users: users, total: 1} = Accounts.list_users_admin(search: "combo", role: "admin")
      assert Enum.map(users, & &1.id) == [match.id]
    end
  end

  describe "list_users_admin/1 — sort and pagination" do
    test "defaults to newest-joined first; dir asc reverses" do
      older = insert_verified_user()
      newer = insert_verified_user()

      earlier = DateTime.add(DateTime.utc_now(), -5, :second) |> DateTime.truncate(:second)

      Repo.update_all(from(u in Fountain.Accounts.User, where: u.id == ^older.id),
        set: [inserted_at: earlier]
      )

      assert %{users: [%{id: a}, %{id: b}]} = Accounts.list_users_admin([])
      assert {a, b} == {newer.id, older.id}

      assert %{users: [%{id: c}, %{id: d}]} = Accounts.list_users_admin(dir: "asc")
      assert {c, d} == {older.id, newer.id}
    end

    test "sorts by email" do
      b = insert_verified_user(%{email: "bbb-sort@example.com"})
      a = insert_verified_user(%{email: "aaa-sort@example.com"})

      assert %{users: [%{id: first}, %{id: second}]} =
               Accounts.list_users_admin(sort: "email", dir: "asc")

      assert {first, second} == {a.id, b.id}
    end

    test "sorts by last activity, users without any activity always last" do
      quiet = insert_verified_user()
      active = insert_verified_user()
      {:ok, _} = Fountain.Usage.record_usage(active.id, "turn_started", nil, nil)

      active_id = active.id
      quiet_id = quiet.id

      assert %{users: [%{id: ^active_id}, %{id: ^quiet_id}]} =
               Accounts.list_users_admin(sort: "last_activity", dir: "desc")

      assert %{users: [%{id: ^active_id}, %{id: ^quiet_id}]} =
               Accounts.list_users_admin(sort: "last_activity", dir: "asc")
    end

    test "carries last_activity_at on every user" do
      active = insert_verified_user()
      {:ok, _} = Fountain.Usage.record_usage(active.id, "turn_started", nil, nil)

      %{users: [user]} = Accounts.list_users_admin(search: active.email)
      assert %DateTime{} = user.last_activity_at

      quiet = insert_verified_user()
      %{users: [user]} = Accounts.list_users_admin(search: quiet.email)
      assert user.last_activity_at == nil
    end

    test "an unknown sort key falls back to joined instead of raising" do
      insert_verified_user()
      assert %{users: [_]} = Accounts.list_users_admin(sort: "email'; drop table users;--")
    end

    test "paginates with a stable total" do
      for i <- 1..3, do: insert_verified_user(%{email: "page-#{i}@example.com"})

      %{users: page1, total: 3} =
        Accounts.list_users_admin(search: "page-", per_page: 2, page: 1)

      %{users: page2, total: 3} =
        Accounts.list_users_admin(search: "page-", per_page: 2, page: 2)

      assert length(page1) == 2
      assert length(page2) == 1
      assert Enum.uniq(Enum.map(page1 ++ page2, & &1.id)) |> length() == 3
    end

    test "a page past the end is empty, not an error" do
      insert_verified_user()
      assert %{users: []} = Accounts.list_users_admin(per_page: 10, page: 99)
    end
  end

  describe "Quotas.active_sandbox_counts/0" do
    test "counts active sandboxes per user in one map, omitting idle users" do
      busy = insert_verified_user()
      idle = insert_verified_user()

      insert_sandbox(user_id: busy.id, status: "ready")
      insert_sandbox(user_id: busy.id, status: "pending")
      insert_sandbox(user_id: busy.id, status: "terminated")

      counts = Fountain.Quotas.active_sandbox_counts()
      assert counts[busy.id] == 2
      refute Map.has_key?(counts, idle.id)
    end

    test "agrees with active_sandbox_count/1 per user" do
      user = insert_verified_user()
      insert_sandbox(user_id: user.id, status: "starting")

      assert Fountain.Quotas.active_sandbox_counts()[user.id] ==
               Fountain.Quotas.active_sandbox_count(user.id)
    end
  end
end
