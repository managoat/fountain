defmodule Fountain.Workers.WelcomeEmail do
  @moduledoc """
  Sends the welcome email once a user's address is verified (#449).

  Enqueued only on the verification *transition* — the unverified branch of
  `EmailVerificationController.confirm/2` and the brand-new-user branch of the
  OAuth callback. Both fire at most once in an account's life, so once-per-user
  is structural; the `unique` window is the belt for a retried request. The
  "already verified" confirm branch deliberately does not enqueue, which is
  also what keeps accounts that predate this worker from being welcomed months
  after they signed up.
  """

  # fields must include :worker — other workers are enqueued in the same
  # request with byte-identical args (%{user_id: ...}), and a [:args]-only
  # uniqueness key silently swallows this job as their duplicate.
  use Oban.Worker,
    queue: :mailer,
    max_attempts: 5,
    unique: [period: :infinity, fields: [:worker, :args]]

  require Logger

  alias Fountain.{Accounts, Emails.UserEmails}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"user_id" => user_id}}) do
    case Accounts.get_user(user_id) do
      nil ->
        # Deleted between enqueue and execution. Nothing to do, and retrying
        # will not bring them back.
        Logger.info("welcome_email: user #{user_id} no longer exists")
        :ok

      %{email_verified_at: nil} = user ->
        # Both enqueue sites run after verification, so this shouldn't happen —
        # but a welcome email must never be the thing that confirms an
        # unverified address exists.
        Logger.warning("welcome_email: user #{user.id} is not verified, skipping")
        :ok

      user ->
        case UserEmails.deliver_welcome_email(user) do
          {:ok, _} ->
            :ok

          {:error, reason} ->
            Logger.warning("welcome_email: delivery failed for #{user.id}: #{inspect(reason)}")

            {:error, reason}
        end
    end
  end

  @doc "Enqueue the welcome email for `user`. At most one per user, ever."
  def enqueue(%Accounts.User{id: id}), do: enqueue(id)

  def enqueue(user_id) when is_binary(user_id) do
    %{user_id: user_id}
    |> new()
    |> Oban.insert()
  end
end
