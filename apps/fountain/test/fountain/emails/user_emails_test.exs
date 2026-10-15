defmodule Fountain.Emails.UserEmailsTest do
  use Fountain.DataCase, async: true

  import Swoosh.TestAssertions

  alias Fountain.Emails.UserEmails

  describe "deliver_verification_email/2" do
    test "delivers an email with the correct subject to the user" do
      user = insert_verified_user()

      assert {:ok, _email} = UserEmails.deliver_verification_email(user, "test_token_abc123")

      assert_email_sent(subject: "Verify your Managoat account", to: [{user.email, user.email}])
    end

    test "email body contains the verification token" do
      user = insert_verified_user()
      token = "unique_verification_token"

      assert {:ok, _email} = UserEmails.deliver_verification_email(user, token)

      assert_email_sent(fn email ->
        assert email.subject == "Verify your Managoat account"
        assert email.html_body =~ token
        assert email.text_body =~ token
      end)
    end

    test "email body contains confirmation URL path" do
      user = insert_verified_user()
      token = "path_token_xyz"

      assert {:ok, _email} = UserEmails.deliver_verification_email(user, token)

      assert_email_sent(fn email ->
        assert email.html_body =~ "/users/confirm/#{token}"
        assert email.text_body =~ "/users/confirm/#{token}"
      end)
    end
  end

  # "link absoluteness" lives in `user_emails_public_url_test.exs`, which is
  # `async: false`. It has to be: those tests write the global `:public_url`,
  # which the rest of the suite reads.

  describe "deliver_password_reset_email/2" do
    test "delivers an email with the correct subject to the user" do
      user = insert_verified_user()

      assert {:ok, _email} = UserEmails.deliver_password_reset_email(user, "reset_token_abc")

      assert_email_sent(subject: "Reset your Managoat password", to: [{user.email, user.email}])
    end

    test "email body contains the reset token" do
      user = insert_verified_user()
      token = "unique_reset_token"

      assert {:ok, _email} = UserEmails.deliver_password_reset_email(user, token)

      assert_email_sent(fn email ->
        assert email.subject == "Reset your Managoat password"
        assert email.html_body =~ token
        assert email.text_body =~ token
      end)
    end

    test "email body contains password reset URL path" do
      user = insert_verified_user()
      token = "reset_path_token"

      assert {:ok, _email} = UserEmails.deliver_password_reset_email(user, token)

      assert_email_sent(fn email ->
        assert email.html_body =~ "/auth/reset/#{token}"
        assert email.text_body =~ "/auth/reset/#{token}"
      end)
    end
  end
end
