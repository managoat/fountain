defmodule Fountain.Emails.UserEmailsWelcomeTest do
  use Fountain.DataCase, async: true

  import Swoosh.TestAssertions

  alias Fountain.Emails.UserEmails

  describe "deliver_welcome_email/1" do
    # ADR 0038: the welcome points at the verified landing, and carries the
    # same request that page shows. The key is never in an email.
    test "welcomes the user and points at the landing" do
      user = insert_verified_user()

      assert {:ok, _email} = UserEmails.deliver_welcome_email(user)

      assert_email_sent(fn email ->
        assert email.subject == "Welcome to Fountain"
        assert email.to == [{user.email, user.email}]
        assert email.html_body =~ "/start"
        assert email.text_body =~ "/start"
      end)
    end

    test "carries the first request, with the key still a placeholder" do
      user = insert_verified_user()

      assert {:ok, _email} = UserEmails.deliver_welcome_email(user)

      assert_email_sent(fn email ->
        assert email.text_body =~ "/api/conversations"
        assert email.text_body =~ Fountain.Onboarding.prompt()
        assert email.text_body =~ "$FOUNTAIN_API_KEY"
        assert email.text_body =~ "on your start page"
      end)
    end

    test "names no dead onboarding route" do
      user = insert_verified_user()
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      {:ok, user} =
        user |> Ecto.Changeset.change(onboarding_completed_at: now) |> Repo.update()

      assert {:ok, _email} = UserEmails.deliver_welcome_email(user)

      assert_email_sent(fn email ->
        refute email.text_body =~ "/onboarding"
        assert email.subject == "Welcome to Fountain"
      end)
    end
  end
end
