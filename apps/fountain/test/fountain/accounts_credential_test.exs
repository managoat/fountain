defmodule Fountain.AccountsCredentialTest do
  @moduledoc """
  Logged-in password change (#448). The property that matters: the current
  password gates it.
  """

  use Fountain.DataCase, async: true

  alias Fountain.Accounts

  defp oauth_only_user do
    {:ok, user, :new} =
      Accounts.upsert_oauth_user("github", "uid-#{System.unique_integer([:positive])}", %{
        "email" => "oauth#{System.unique_integer([:positive])}@example.com"
      })

    user
  end

  describe "change_password/3" do
    test "changes the password and invalidates other sessions" do
      user = insert_verified_user(%{"password" => "old-password-123"})

      assert {:ok, updated} =
               Accounts.change_password(user, "old-password-123", "new-password-456")

      assert updated.session_version > user.session_version
      assert {:ok, _} = Accounts.authenticate_user(user.email, "new-password-456")

      assert {:error, :wrong_password} =
               Accounts.authenticate_user(user.email, "old-password-123")
    end

    test "refuses a wrong current password without touching anything" do
      user = insert_verified_user(%{"password" => "old-password-123"})

      assert {:error, :invalid_current_password} =
               Accounts.change_password(user, "not-the-password", "new-password-456")

      assert {:ok, _} = Accounts.authenticate_user(user.email, "old-password-123")
    end

    test "a too-short new password comes back as a changeset error" do
      user = insert_verified_user(%{"password" => "old-password-123"})

      assert {:error, %Ecto.Changeset{}} =
               Accounts.change_password(user, "old-password-123", "short")
    end

    test "an OAuth-only account has no password to change" do
      assert {:error, :no_password} =
               Accounts.change_password(oauth_only_user(), "anything", "new-password-456")
    end
  end
end
