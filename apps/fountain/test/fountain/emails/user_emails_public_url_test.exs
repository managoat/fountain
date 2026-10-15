# async: false — these tests write the global `:public_url`, which the rest
# of the suite reads (email links, redirects).
#
# They used to sit in `user_emails_test.exs`, which is `async: true`. While
# one of them held `:public_url` at `fountain.example.com`, a controller test
# rendering a page beside it saw that host in its (since removed) `og:url` and failed an
# assertion about `http://localhost:4000`. Same shape as the fleet ceiling in
# `quotas_fleet_ceiling_test.exs`: an async module writing global config that
# production code reads on a hot path.
defmodule Fountain.Emails.UserEmailsPublicUrlTest do
  use Fountain.DataCase, async: false

  import Swoosh.TestAssertions

  alias Fountain.Emails.UserEmails

  describe "link absoluteness" do
    # These assert on the scheme, not just the path. The original tests only
    # checked "/users/confirm/<token>", which passed happily while production
    # was emitting "fountain.inevitable.fyi/users/confirm/<token>" — a string
    # no mail client will render as a link.
    setup do
      original = Application.get_env(:fountain, :public_url)
      on_exit(fn -> Application.put_env(:fountain, :public_url, original) end)
      :ok
    end

    test "verification link is absolute even if :public_url is set to a bare host" do
      Application.put_env(:fountain, :public_url, "fountain.example.com")
      user = insert_verified_user()

      assert {:ok, _} = UserEmails.deliver_verification_email(user, "tok")

      assert_email_sent(fn email ->
        assert email.html_body =~ "https://fountain.example.com/users/confirm/tok"
        assert email.text_body =~ "https://fountain.example.com/users/confirm/tok"
      end)
    end

    test "reset link is absolute even if :public_url is set to a bare host" do
      Application.put_env(:fountain, :public_url, "fountain.example.com")
      user = insert_verified_user()

      assert {:ok, _} = UserEmails.deliver_password_reset_email(user, "tok")

      assert_email_sent(fn email ->
        assert email.html_body =~ "https://fountain.example.com/auth/reset/tok"
        assert email.text_body =~ "https://fountain.example.com/auth/reset/tok"
      end)
    end

    test "an absolute :public_url is preserved verbatim" do
      Application.put_env(:fountain, :public_url, "https://custom.example.org")
      user = insert_verified_user()

      assert {:ok, _} = UserEmails.deliver_verification_email(user, "tok")

      assert_email_sent(fn email ->
        assert email.html_body =~ "https://custom.example.org/users/confirm/tok"
      end)
    end
  end
end
