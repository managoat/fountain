defmodule Fountain.Repo.Migrations.DropSupportReports do
  @moduledoc """
  The `fountain_support` extension is gone, and with it the table its own
  migration (20260819130000, once core's, then the extension's under #1528)
  created. Core drops it because nothing else will: an uninstalled extension
  contributes no migration path.

  `IF EXISTS`, because a core-only release never applied the extension's
  migration and so never had the table. Pending forwarding jobs go too, since
  no worker module is left to run them.

  `down` restores the empty table, not its rows.
  """
  use Ecto.Migration

  def up do
    execute "DELETE FROM oban_jobs WHERE worker = 'FountainSupport.Workers.Forward'"
    execute "DROP TABLE IF EXISTS support_reports"
  end

  def down do
    create_if_not_exists table(:support_reports, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :category, :string, null: false
      add :message, :text, null: false
      add :context, :map, null: false, default: %{}
      add :client, :string
      add :screenshot, :binary
      add :screenshot_media_type, :string
      add :status, :string, null: false, default: "new"
      add :forwarded_at, :utc_datetime
      add :external_url, :string
      add :forward_error, :text

      timestamps(type: :utc_datetime)
    end

    create_if_not_exists index(:support_reports, [:user_id])
    create_if_not_exists index(:support_reports, [:status, :inserted_at])
  end
end
