defmodule Fountain.Repo.Migrations.DropSandboxSnapshots do
  use Ecto.Migration

  @moduledoc """
  The contract step for the release that removed park snapshots (ADR 0063,
  retired 2026-10-14, #2656).

  That release stopped writing and reading `sandbox_snapshots` but left the
  table in place: the release before it writes a row on every park and
  deletes one on every terminal status change, so dropping the table
  mid-rollout would fail those replicas. Take this only after that release is
  fully rolled out.

  `down` restores the shape (`20261002120000`), not the rows.
  """

  def up do
    execute("SET LOCAL lock_timeout = '5s'")
    drop table(:sandbox_snapshots)
  end

  def down do
    execute("SET LOCAL lock_timeout = '5s'")

    create table(:sandbox_snapshots, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :sandbox_id, references(:sandboxes, type: :binary_id, on_delete: :delete_all),
        null: false

      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :taken_at, :utc_datetime_usec, null: false
      add :manifest_ciphertext, :binary, null: false
      add :contents_ciphertext, :binary, null: false
      add :file_count, :integer, null: false
      add :content_bytes, :bigint, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:sandbox_snapshots, [:sandbox_id])
    create index(:sandbox_snapshots, [:user_id])
  end
end
