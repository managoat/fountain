defmodule Fountain.Repo.Migrations.DropRunners do
  use Ecto.Migration

  @moduledoc """
  The contract step for the release that removed the self-hosted runner
  provider (ADR 0071, #2676).

  That release stopped reading and writing `runners` but left the table in
  place: the release before it upserts a row on every daemon connect and
  reads the table for placement, presence and the console, so dropping it
  mid-rollout would fail those replicas. Take this only after that release is
  fully rolled out.

  The table held no foreign keys from other tables: a runner sandbox carried
  its runner id inside `sandboxes.sprite_name`, so nothing else changes.
  `down` restores the shape (`20260819120000`), not the rows.
  """

  def up do
    execute("SET LOCAL lock_timeout = '5s'")
    drop table(:runners)
  end

  def down do
    execute("SET LOCAL lock_timeout = '5s'")

    create table(:runners, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :hostname, :string
      add :os, :string
      add :arch, :string
      add :version, :string
      add :root, :string
      add :connected_at, :utc_datetime
      add :last_seen_at, :utc_datetime
      timestamps(type: :utc_datetime)
    end

    create unique_index(:runners, [:user_id, :name])
  end
end
