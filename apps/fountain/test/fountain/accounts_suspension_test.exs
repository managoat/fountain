defmodule Fountain.AccountsSuspensionTest do
  use Fountain.DataCase, async: true

  alias Fountain.Accounts
  alias Fountain.Conversations
  alias Fountain.Conversations.Launch

  describe "suspend_user/1 and unsuspend_user/1" do
    test "sets suspended_at and invalidates existing sessions" do
      user = insert_verified_user()
      assert {:ok, suspended, 0} = Accounts.suspend_user(user)

      assert %DateTime{} = suspended.suspended_at
      assert suspended.session_version == user.session_version + 1
      assert Accounts.suspended?(suspended)
    end

    test "reaps every active sandbox; terminal ones are left alone" do
      user = insert_verified_user()
      active = insert_sandbox(user_id: user.id, status: "ready")
      pending = insert_sandbox(user_id: user.id, status: "pending")
      terminal = insert_sandbox(user_id: user.id, status: "terminated")
      other_tenant = insert_sandbox(status: "ready")

      assert {:ok, _, 2} = Accounts.suspend_user(user)

      assert Conversations._unsafe_get_sandbox!(active.id).status == "terminated"
      assert Conversations._unsafe_get_sandbox!(pending.id).status == "terminated"
      assert Conversations._unsafe_get_sandbox!(terminal.id).status == "terminated"
      # another tenant's sandbox is untouched
      assert Conversations._unsafe_get_sandbox!(other_tenant.id).status == "ready"
    end

    test "unsuspend clears the flag without touching session_version again" do
      {:ok, suspended, _} = Accounts.suspend_user(insert_verified_user())

      assert {:ok, lifted} = Accounts.unsuspend_user(suspended)
      assert lifted.suspended_at == nil
      refute Accounts.suspended?(lifted)
      assert lifted.session_version == suspended.session_version
    end
  end

  describe "login refusal" do
    test "correct password on a suspended account returns :suspended" do
      user = insert_verified_user()
      {:ok, _, _} = Accounts.suspend_user(user)

      assert {:error, :suspended} = Accounts.authenticate_user(user.email, "password123")
    end

    test "wrong password still answers :wrong_password — no state oracle" do
      user = insert_verified_user()
      {:ok, _, _} = Accounts.suspend_user(user)

      assert {:error, :wrong_password} =
               Accounts.authenticate_user(user.email, "not-the-password")
    end
  end

  describe "API key refusal" do
    test "a valid key on a suspended account returns :suspended" do
      user = insert_verified_user()
      {_record, raw_key} = insert_api_key(user)
      {:ok, _, _} = Accounts.suspend_user(user)

      assert {:error, :suspended} = Accounts.authenticate_api_key(raw_key)
    end
  end

  describe "provisioning backstop" do
    test "check_not_suspended/1" do
      user = insert_verified_user()
      assert :ok = Accounts.check_not_suspended(user.id)

      {:ok, _, _} = Accounts.suspend_user(user)
      assert {:error, :account_suspended} = Accounts.check_not_suspended(user.id)

      # unknown id fails closed
      assert {:error, :account_suspended} =
               Accounts.check_not_suspended(Ecto.UUID.generate())
    end

    test "start_conversation refuses a suspended user before any sandbox exists" do
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)
      {:ok, _, _} = Accounts.suspend_user(user)

      assert {:error, :account_suspended} =
               Launch.start_conversation(%{
                 "agent_id" => agent.id,
                 "user_id" => user.id
               })
    end
  end
end
