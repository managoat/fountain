defmodule Fountain.Workers.WelcomeEmailTest do
  use Fountain.DataCase, async: true

  import Swoosh.TestAssertions

  alias Fountain.Workers.WelcomeEmail

  describe "perform/1" do
    test "welcomes a verified user and points at the landing" do
      user = insert_verified_user()
      assert is_nil(user.onboarding_completed_at)

      assert :ok = perform_job(WelcomeEmail, %{"user_id" => user.id})

      assert_email_sent(fn email ->
        assert email.subject == "Welcome to Fountain"
        assert email.to == [{user.email, user.email}]
        assert email.text_body =~ "/start"
      end)
    end

    test "says nothing about credit" do
      user = insert_verified_user()

      assert :ok = perform_job(WelcomeEmail, %{"user_id" => user.id})

      assert_email_sent(fn email ->
        not (email.text_body =~ "credit" or email.html_body =~ "credit")
      end)
    end

    test "never emails an unverified address" do
      user = insert_user()
      assert is_nil(user.email_verified_at)

      assert :ok = perform_job(WelcomeEmail, %{"user_id" => user.id})

      assert_no_email_sent()
    end

    test "is a no-op for a deleted user" do
      assert :ok = perform_job(WelcomeEmail, %{"user_id" => Ecto.UUID.generate()})

      assert_no_email_sent()
    end
  end

  describe "enqueue/1 uniqueness" do
    test "at most one welcome job per user, ever" do
      user = insert_verified_user()

      assert {:ok, %Oban.Job{conflict?: false}} = WelcomeEmail.enqueue(user)
      assert {:ok, %Oban.Job{conflict?: true}} = WelcomeEmail.enqueue(user)

      assert [_only_one] = all_enqueued(worker: WelcomeEmail)
    end
  end
end
