defmodule Fountain.Workers.PasswordResetEmail do
  @moduledoc """
  Sends the password-reset link as a durable job.

  `POST /api/auth/forgot` (which the browser's forgot-password form posts to
  as well) used to send this from an unlinked `Task` (#1040): a delivery
  error had no retry and left no trace beyond a log line. It now enqueues
  this job on the `:mailer` queue, like `Workers.VerificationEmail`.

  The token is signed in `perform/1`, not at enqueue time, for the same
  reasons as the verification email: job args sit in `oban_jobs` in
  plaintext, and a retried job should mail a full-TTL link. The token
  carries `{user.id, user.session_version}` (#325), and the session version
  is read when the job runs, so a reset completed between enqueue and send
  already makes the mailed link invalid rather than a still-live one.
  """

  # fields must include :worker: VerificationEmail takes the same
  # %{user_id: ...} args, and an [:args]-only uniqueness key would swallow
  # this job as a duplicate of that one.
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
        # Deleted between enqueue and execution; retrying will not bring
        # them back.
        Logger.info("password_reset_email: user #{user_id} no longer exists")
        :ok

      user ->
        token =
          Phoenix.Token.sign(
            FountainWeb.Endpoint,
            "password_reset",
            {user.id, user.session_version}
          )

        case UserEmails.deliver_password_reset_email(user, token) do
          {:ok, _} ->
            :ok

          {:error, reason} ->
            Logger.warning(
              "password_reset_email: delivery failed for #{user.id}: #{inspect(reason)}"
            )

            {:error, reason}
        end
    end
  end

  @doc """
  Enqueue a password-reset email for `user`.

  Unique per user for 60 seconds, so a double-submitted form collapses into
  one email; the endpoint's per-IP rate limit bounds the rest.
  """
  def enqueue(%Accounts.User{id: id}) do
    %{user_id: id}
    |> new()
    |> Oban.insert()
  end
end
