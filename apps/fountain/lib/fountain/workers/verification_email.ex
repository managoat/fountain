defmodule Fountain.Workers.VerificationEmail do
  @moduledoc """
  Sends the email-verification link as a durable job (#445).

  Registration used to send this with a bare `Task.async` and no `await`. The
  task was *linked* to the request process, so finishing the HTTP response
  could kill an in-flight send, and a delivery error had no retry and no log —
  the failure mode every request-path send has been extracted for since.
  This one was worse: with no resend route, a
  dropped verification email left the account permanently unusable.

  The token is signed in `perform/1`, not at enqueue time. Job args are stored
  in `oban_jobs`, so a token minted at enqueue would sit in the database in
  plaintext, and by the time a retried job finally delivered it could be well
  into its 24 h TTL. Each attempt sends a fresh, full-TTL link instead.
  """

  # fields must include :worker: other workers take the same %{user_id: ...}
  # args, and a [:args]-only uniqueness key would swallow this job as a
  # duplicate of theirs.
  use Oban.Worker,
    queue: :mailer,
    max_attempts: 5,
    unique: [period: 60, fields: [:worker, :args]]

  require Logger

  alias Fountain.{Accounts, Emails.UserEmails}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"user_id" => user_id}}) do
    case Accounts.get_user(user_id) do
      nil ->
        # Deleted between enqueue and execution. Nothing to do, and retrying
        # will not bring them back.
        Logger.info("verification_email: user #{user_id} no longer exists")
        :ok

      %{email_verified_at: %DateTime{}} ->
        # Verified in the meantime — usually a resend racing the click on the
        # original link. The email would only say "already verified".
        :ok

      user ->
        token = Phoenix.Token.sign(FountainWeb.Endpoint, "email_verification", user.id)

        case UserEmails.deliver_verification_email(user, token) do
          {:ok, _} ->
            :ok

          {:error, reason} ->
            Logger.warning(
              "verification_email: delivery failed for #{user.id}: #{inspect(reason)}"
            )

            {:error, reason}
        end
    end
  end

  @doc """
  Enqueue a verification email for `user`.

  Unique per user for 60 seconds, so a double-submitted resend form (or a
  request retry) collapses into one email without blocking a genuine resend
  a few minutes later.
  """
  def enqueue(%Accounts.User{id: id}), do: enqueue(id)

  def enqueue(user_id) when is_binary(user_id) do
    %{user_id: user_id}
    |> new()
    |> Oban.insert()
  end
end
