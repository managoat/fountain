defmodule Fountain.Repo.Migrations.DropUsageEvents do
  @moduledoc """
  Drops `usage_events` (ADR 0079).

  The previous release removed usage metering and stopped writing the table;
  it was kept for one release because the release before that writes it on
  every sandbox status change and every turn. The table had no inbound
  foreign keys.

  `down` restores the table's shape, not its rows.
  """
  use Ecto.Migration

  def up do
    drop table(:usage_events)
  end

  def down do
    create table(:usage_events) do
      add :user_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :event_type, :string, null: false
      add :resource_id, :binary_id
      add :resource_type, :string
      add :metadata, :map, null: false, default: %{}
      add :inserted_at, :utc_datetime, null: false
    end

    create index(:usage_events, [:user_id])
    create index(:usage_events, [:event_type])
    create index(:usage_events, [:inserted_at])
  end
end
