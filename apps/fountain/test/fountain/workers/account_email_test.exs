defmodule Fountain.Workers.AccountEmailTest do
  use Fountain.DataCase, async: true

  import Swoosh.TestAssertions

  alias Fountain.Accounts
  alias Fountain.Workers.AccountEmail

  describe "suspended" do
    test "notifies a suspended, verified user" do
      user = insert_verified_user()
      {:ok, user, _reaped} = Accounts.suspend_user(user)

      assert :ok = perform_job(AccountEmail, %{"kind" => "suspended", "user_id" => user.id})

      assert_email_sent(fn email ->
        assert email.subject == "Your Fountain account has been suspended"
        assert email.to == [{user.email, user.email}]
        assert email.text_body =~ "Nothing is deleted"
      end)
    end

    test "stays silent when the suspension was lifted before the queue drained" do
      user = insert_verified_user()

      assert :ok = perform_job(AccountEmail, %{"kind" => "suspended", "user_id" => user.id})

      assert_no_email_sent()
    end

    test "never emails an unverified address" do
      user = insert_user()
      {:ok, _user, _} = Accounts.suspend_user(user)

      assert :ok = perform_job(AccountEmail, %{"kind" => "suspended", "user_id" => user.id})

      assert_no_email_sent()
    end
  end

  describe "unsuspended" do
    test "notifies once the account is actually unsuspended" do
      user = insert_verified_user()

      assert :ok = perform_job(AccountEmail, %{"kind" => "unsuspended", "user_id" => user.id})

      assert_email_sent(fn email ->
        assert email.subject == "Your Fountain account is available again"
        assert email.text_body =~ "/auth/login"
      end)
    end

    test "stays silent while the account is still suspended" do
      user = insert_verified_user()
      {:ok, user, _} = Accounts.suspend_user(user)

      assert :ok = perform_job(AccountEmail, %{"kind" => "unsuspended", "user_id" => user.id})

      assert_no_email_sent()
    end
  end

  describe "deleted" do
    test "confirms to the raw address — the row is gone by send time" do
      assert :ok =
               perform_job(AccountEmail, %{"kind" => "deleted", "email" => "gone@example.com"})

      assert_email_sent(fn email ->
        assert email.subject == "Your Fountain account has been deleted"
        assert email.to == [{"gone@example.com", "gone@example.com"}]
        assert email.text_body =~ "permanently deleted"
      end)
    end
  end

  describe "wiring" do
    test "suspend_user and unsuspend_user enqueue their notices" do
      user = insert_verified_user()

      {:ok, user, _} = Accounts.suspend_user(user)
      assert_enqueued(worker: AccountEmail, args: %{user_id: user.id, kind: "suspended"})

      {:ok, _user} = Accounts.unsuspend_user(user)
      assert_enqueued(worker: AccountEmail, args: %{user_id: user.id, kind: "unsuspended"})
    end
  end
end
