defmodule Fountain.Workers.AccountEmailTest do
  use Fountain.DataCase, async: true

  import Swoosh.TestAssertions

  alias Fountain.Workers.AccountEmail

  describe "deleted" do
    test "confirms to the raw address — the row is gone by send time" do
      assert :ok =
               perform_job(AccountEmail, %{"kind" => "deleted", "email" => "gone@example.com"})

      assert_email_sent(fn email ->
        assert email.subject == "Your Managoat account has been deleted"
        assert email.to == [{"gone@example.com", "gone@example.com"}]
        assert email.text_body =~ "permanently deleted"
      end)
    end
  end

  # Account suspension was removed on 2026-10-15. A notice enqueued before
  # the upgrade completes quietly instead of retrying against a worker that
  # no longer knows the kind.
  describe "a retired kind" do
    test "a queued suspension notice completes and sends nothing" do
      user = insert_verified_user()

      for kind <- ["suspended", "unsuspended"] do
        assert :ok = perform_job(AccountEmail, %{"kind" => kind, "user_id" => user.id})
      end

      assert_no_email_sent()
    end
  end
end
