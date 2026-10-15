defmodule Fountain.Workers.VerificationEmailTest do
  use Fountain.DataCase, async: true

  import Swoosh.TestAssertions

  alias Fountain.Workers.VerificationEmail

  describe "perform/1" do
    test "sends a verification email whose token the confirm route will accept" do
      user = insert_user()

      assert :ok = perform_job(VerificationEmail, %{"user_id" => user.id})

      assert_email_sent(fn email ->
        assert email.subject == "Verify your Managoat account"
        assert email.to == [{user.email, user.email}]

        # The worker signs the token itself (there is no conn in a job), so
        # prove the artifact it mails is one the controller's verify will take.
        [_, token] = Regex.run(~r{/users/confirm/([A-Za-z0-9_\-\.]+)}, email.text_body)

        assert {:ok, user.id} ==
                 Phoenix.Token.verify(FountainWeb.Endpoint, "email_verification", token,
                   max_age: 86_400
                 )
      end)
    end

    test "each attempt signs a fresh token rather than reusing one from enqueue time" do
      user = insert_user()

      assert {:ok, job} = VerificationEmail.enqueue(user)

      # No token in the stored args — nothing secret at rest in oban_jobs,
      # and a retry days later cannot deliver a nearly-expired link.
      assert job.args == %{user_id: user.id}
    end

    test "is a no-op for a user who verified in the meantime" do
      user = insert_verified_user()

      assert :ok = perform_job(VerificationEmail, %{"user_id" => user.id})

      assert_no_email_sent()
    end

    test "is a no-op for a deleted user" do
      assert :ok = perform_job(VerificationEmail, %{"user_id" => Ecto.UUID.generate()})

      assert_no_email_sent()
    end
  end

  describe "enqueue/1 uniqueness" do
    test "a double-submitted resend collapses into one job" do
      user = insert_user()

      assert {:ok, %Oban.Job{conflict?: false}} = VerificationEmail.enqueue(user)
      assert {:ok, %Oban.Job{conflict?: true}} = VerificationEmail.enqueue(user)

      assert [_only_one] = all_enqueued(worker: VerificationEmail)
    end
  end
end
