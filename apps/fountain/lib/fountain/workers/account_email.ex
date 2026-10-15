defmodule Fountain.Workers.AccountEmail do
  @moduledoc """
  The account-deletion confirmation (#450).

  A deletion has no user row left to read, so the job carries the address
  itself (captured before the row delete) and sends unconditionally. The
  deletion path only enqueues for a verified account, so the mail never
  confirms that an unverified address existed.

  The suspension notices this worker also sent were removed with account
  suspension on 2026-10-15.
  """

  use Oban.Worker,
    queue: :mailer,
    max_attempts: 5,
    unique: [period: 300, fields: [:worker, :args]]

  require Logger

  alias Fountain.Emails.UserEmails

  @doc """
  Enqueue the deletion confirmation for a raw address — call BEFORE the row
  delete commits is fine (the job only carries the string), but the caller
  must have already established the address was verified.
  """
  def enqueue_deleted(email) when is_binary(email) do
    %{email: email, kind: "deleted"} |> new() |> Oban.insert()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"kind" => "deleted", "email" => email}}) do
    case UserEmails.deliver_account_deleted_email(email) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("account_email: deleted delivery failed for #{email}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # A suspension notice enqueued before the upgrade that removed suspension:
  # there is nothing left to say, so the job completes rather than retrying.
  def perform(%Oban.Job{args: %{"kind" => kind}}) do
    Logger.info("account_email: dropping retired #{kind} notice")
    :ok
  end
end
