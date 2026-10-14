defmodule Fountain.ReleaseTest do
  use Fountain.DataCase, async: true

  import ExUnit.CaptureIO

  alias Fountain.Release

  describe "verify_email/1" do
    test "verifies an existing account" do
      user = insert_user()
      assert is_nil(user.email_verified_at)

      capture_io(fn ->
        assert {:ok, verified} = Release.verify_email(user.email)
        assert %DateTime{} = verified.email_verified_at
      end)
    end

    test "returns not_found for an unknown email" do
      capture_io(:stderr, fn ->
        assert {:error, :not_found} =
                 Release.verify_email("nobody-#{System.unique_integer([:positive])}@example.com")
      end)
    end
  end

  describe "promote_admin/1" do
    import Ecto.Query

    defp admin_events_for(user_id) do
      Repo.all(
        from e in Fountain.Audit.AdminEvent,
          where: e.target_user_id == ^user_id and e.event_type == "admin.role.granted"
      )
    end

    test "grants the role and records a system-actor audit event" do
      user = insert_user()
      assert user.role == "user"

      capture_io(fn ->
        assert {:ok, promoted} = Release.promote_admin(user.email)
        assert promoted.role == "admin"
      end)

      assert Repo.reload!(user).role == "admin"

      assert [event] = admin_events_for(user.id)
      assert is_nil(event.actor_user_id)
      assert event.metadata["email"] == user.email
      assert event.metadata["via"] == "release_task"
      assert event.metadata["to"] == "admin"
    end

    test "an already-admin account is a no-op and records nothing" do
      user = insert_user()

      capture_io(fn ->
        assert {:ok, _} = Release.promote_admin(user.email)
        assert {:ok, again} = Release.promote_admin(user.email)
        assert again.role == "admin"
      end)

      # Only the first call recorded an event.
      assert [_one] = admin_events_for(user.id)
    end

    test "returns not_found for an unknown email" do
      capture_io(:stderr, fn ->
        assert {:error, :not_found} =
                 Release.promote_admin("nobody-#{System.unique_integer([:positive])}@example.com")
      end)
    end
  end

  describe "create_admin_key/2 (#2660)" do
    test "mints an admin key for an admin and prints it once" do
      user = insert_user()
      {:ok, admin} = Fountain.Accounts.update_user_role(user, "admin")

      out =
        capture_io(fn ->
          assert {:ok, key} = Release.create_admin_key(admin.email, "provisioner")
          assert key.scopes == ["full", "admin"]
          send(self(), {:key, key})
        end)

      assert_received {:key, key}
      assert [_header, raw] = String.split(String.trim(out), "\n")
      assert String.starts_with?(raw, key.key_prefix)
      assert String.length(raw) == 68
    end

    test "refuses an account that is not an admin" do
      user = insert_user()

      capture_io(:stderr, fn ->
        assert {:error, :not_admin} = Release.create_admin_key(user.email, "provisioner")
      end)

      assert Fountain.Accounts.list_api_keys(user.id) == []
    end
  end
end
