defmodule Fountain.Repo.Migrations.DropVaultSecretExpiryNotices do
  @moduledoc """
  Drops `vault_secrets.expiry_notified_at` and the partial index on
  `expires_at` that served the daily expiry sweep.

  The vault-secret expiry email was removed on 2026-10-15 with
  `Fountain.Workers.SecretExpirySweeper`. The column was the sweeper's
  bookkeeping (notice sent once per expiry), and the index carried only its
  query. `expires_at` stays: it is the owner's own record of a secret's
  lifetime, set and read over the API and `fountain vault show`.

  Also deletes the Oban jobs the removed worker left behind, as
  `20261015180000_drop_team_schedules` did for its workers: the cron entry
  is gone, so nothing inserts new ones, and the module no longer exists to
  run a queued one.

  `down/0` restores the column (empty) and the index, not the jobs.
  """
  use Ecto.Migration

  def up do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '30s'")

    execute("DELETE FROM oban_jobs WHERE worker = 'Fountain.Workers.SecretExpirySweeper'")

    drop_if_exists index(:vault_secrets, [:expires_at])
    execute("ALTER TABLE vault_secrets DROP COLUMN IF EXISTS expiry_notified_at")
  end

  def down do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '30s'")

    alter table(:vault_secrets) do
      add :expiry_notified_at, :utc_datetime
    end

    create index(:vault_secrets, [:expires_at],
             where: "expires_at IS NOT NULL AND expiry_notified_at IS NULL"
           )
  end
end
