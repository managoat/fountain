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
