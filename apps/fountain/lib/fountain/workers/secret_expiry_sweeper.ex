defmodule Fountain.Workers.SecretExpirySweeper do
  @moduledoc """
  Emails owners about vault secrets that are about to expire.

  A vault secret with an `expires_at` is usually a token whose issuer chose
  the lifetime; without a nudge, the first sign of expiry is a conversation
  failing against a dead credential. The sweep finds secrets inside the
  notice window that have not been notified about, sends one email per owner
  listing all of theirs, and stamps `expiry_notified_at` so the notice sends
  once per expiry — a later change to `expires_at` clears the stamp (see
  `VaultSecret.changeset/3`) and re-arms it.

  The email is advisory only: an expired secret keeps being injected as-is,
  because Fountain cannot know whether the recorded date is right and a
  missing env var fails worse than a stale one.

  Config:

    * `:secret_expiry_notice_days` — how far ahead to warn, 7 unless a test
      overrides it. `0` disables the sweep. `notice_days/0` is the one
      reader.
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 1

  import Ecto.Query

  alias Fountain.{Accounts, Emails.UserEmails, Repo}
  alias Fountain.Vaults.{Vault, VaultSecret}

  require Logger

  # Bounds one run; the sweep is daily, so a larger backlog drains over a few
  # days rather than making one giant run.
  @batch 500

  @impl Oban.Worker
  def perform(_job) do
    case notice_days() do
      0 ->
        :ok

      days ->
        notified = sweep(days)

        if notified > 0 do
          Logger.info("secret-expiry sweeper: notified #{notified} account(s)")
        end

        :ok
    end
  end

  defp sweep(days) do
    cutoff = DateTime.utc_now() |> DateTime.add(days, :day)

    due()
    |> where([s], s.expires_at <= ^cutoff)
    |> order_by([s], asc: s.expires_at)
    |> limit(@batch)
    |> join(:inner, [s], v in Vault, on: s.vault_id == v.id)
    |> select([s, v], %{secret: s, vault_name: v.name, user_id: v.user_id})
    |> Repo.all()
    |> Enum.group_by(& &1.user_id)
    |> Enum.map(fn {user_id, entries} -> notify(user_id, entries) end)
    |> Enum.count(& &1)
  end

  defp due do
    from s in VaultSecret,
      where: not is_nil(s.expires_at) and is_nil(s.expiry_notified_at)
  end

  defp notify(user_id, entries) do
    with %{email_verified_at: verified_at} = user when not is_nil(verified_at) <-
           Accounts.get_user(user_id),
         {:ok, _} <-
           UserEmails.deliver_vault_secrets_expiring_email(
             user,
             Enum.map(entries, fn e ->
               %{vault_name: e.vault_name, key: e.secret.key, expires_at: e.secret.expires_at}
             end)
           ) do
      ids = Enum.map(entries, & &1.secret.id)
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      # Stamped only after a successful send, so a delivery failure retries
      # on the next daily run rather than being marked done.
      due()
      |> where([s], s.id in ^ids)
      |> Repo.update_all(set: [expiry_notified_at: now])

      true
    else
      _ -> false
    end
  end

  @doc """
  The notice window in days. `0` means the notice is off.

  The one reader of the notice window. The console's vault page, which
  badged secrets inside it, went with ADR 0076; the window now only decides
  when the email goes.
  """
  @spec notice_days() :: non_neg_integer()
  def notice_days do
    Application.get_env(:fountain, :secret_expiry_notice_days, 7)
  end
end
