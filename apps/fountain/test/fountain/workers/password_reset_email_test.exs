defmodule Fountain.Workers.PasswordResetEmailTest do
  use Fountain.DataCase, async: true
  use Mimic

  import Swoosh.TestAssertions

  alias Fountain.Workers.{PasswordResetEmail, VerificationEmail}

  defp mailed_token(email) do
    [_, token] = Regex.run(~r{/auth/reset/([A-Za-z0-9_\-\.]+)}, email.text_body)
    token
  end

  describe "perform/1" do
    test "mails a reset link whose token carries the user's current session_version" do
      user = insert_verified_user()

      assert :ok = perform_job(PasswordResetEmail, %{"user_id" => user.id})

      assert_email_sent(fn email ->
        assert email.to == [{user.email, user.email}]
        assert email.subject =~ "Reset your"

        assert {:ok, {user.id, user.session_version}} ==
                 Phoenix.Token.verify(FountainWeb.Endpoint, "password_reset", mailed_token(email),
                   max_age: 3_600
                 )
      end)
    end

    test "signs at send time: a reset completed after enqueue is reflected in the token" do
      user = insert_verified_user()
      assert {:ok, job} = PasswordResetEmail.enqueue(user)

      # Nothing secret at rest in oban_jobs.
      assert job.args == %{user_id: user.id}

      {:ok, user} = Fountain.Accounts.reset_password(user, "a-brand-new-password-123", [])

      assert :ok = perform_job(PasswordResetEmail, %{"user_id" => user.id})

      assert_email_sent(fn email ->
        assert {:ok, {_, version}} =
                 Phoenix.Token.verify(FountainWeb.Endpoint, "password_reset", mailed_token(email),
                   max_age: 3_600
                 )

        assert version == user.session_version
      end)
    end

    test "is a no-op for a deleted user" do
      assert :ok = perform_job(PasswordResetEmail, %{"user_id" => Ecto.UUID.generate()})

      assert_no_email_sent()
    end

    test "a delivery error returns an error so Oban retries" do
      user = insert_verified_user()
      stub(Fountain.Mailer, :deliver, fn _email -> {:error, :smtp_down} end)

      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, :smtp_down} = perform_job(PasswordResetEmail, %{"user_id" => user.id})
      end)
    end
  end

  describe "enqueue/1 uniqueness" do
    test "a double-submitted form collapses into one job" do
      user = insert_verified_user()

      assert {:ok, %Oban.Job{conflict?: false}} = PasswordResetEmail.enqueue(user)
      assert {:ok, %Oban.Job{conflict?: true}} = PasswordResetEmail.enqueue(user)

      assert [_only_one] = all_enqueued(worker: PasswordResetEmail)
    end

    test "is not swallowed by a verification email for the same user" do
      user = insert_user()

      assert {:ok, %Oban.Job{conflict?: false}} = VerificationEmail.enqueue(user)
      assert {:ok, %Oban.Job{conflict?: false}} = PasswordResetEmail.enqueue(user)
    end
  end
end
