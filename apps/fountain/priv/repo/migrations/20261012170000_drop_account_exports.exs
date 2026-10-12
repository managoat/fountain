defmodule Fountain.Repo.Migrations.DropAccountExports do
  @moduledoc """
  Outbound webhooks and the account data export are gone (simplify 4/5).

  `account_exports` goes now. The previous release, still serving during a
  rolling deploy, reads it only from the export's own surfaces: the `/account`
  page's export card, the export routes, the export worker and the retention
  pruner's sweep. Those can fail until the old pods leave; nothing else reads
  the table.

  `webhook_endpoints` and `webhook_deliveries` stay for now. The previous
  release reads `webhook_endpoints` on every stage transition, and inside the
  deadline transaction, so dropping it mid-rollout would fail turns on the old
  pods. A later migration drops both once no release reads them.

  Pending jobs for the removed workers go with them, on their queues and by
  name, since no worker module is left to run them.

  `down` restores the empty table, not its rows.
  """
  use Ecto.Migration

  def up do
    execute """
    DELETE FROM oban_jobs
    WHERE queue IN ('webhooks', 'exports')
       OR worker IN (
         'Fountain.Workers.WebhookDelivery',
         'Fountain.Workers.WebhookEmail',
         'Fountain.Workers.AccountExport'
       )
    """

    execute "DROP TABLE IF EXISTS account_exports"
  end

  def down do
    create_if_not_exists table(:account_exports, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :status, :string, null: false, default: "pending"
      add :payload, :binary
      add :byte_size, :bigint
      add :error, :string
      add :expires_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create_if_not_exists index(:account_exports, [:user_id, :inserted_at])
    create_if_not_exists index(:account_exports, [:expires_at])
  end
end
