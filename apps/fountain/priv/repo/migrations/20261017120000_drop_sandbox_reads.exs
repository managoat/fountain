defmodule Fountain.Repo.Migrations.DropSandboxReads do
  use Ecto.Migration

  @moduledoc """
  The contract step for the release that moved admitted sandbox-files reads
  into memory (`Fountain.Machines.Reads`, ADR 0039's 2026-10-15 addendum).

  That release stopped reading and writing `sandbox_reads` but left the table
  in place: the release before it inserts a row on every files-API read, and
  a migration that runs while it still serves would turn each of those reads
  into a 500. Take this only after that release is fully rolled out.

  `down` restores the shape (`20260918220000`), not the rows; a row lived for
  at most one 40-second window anyway.
  """

  def up do
    execute("SET LOCAL lock_timeout = '5s'")
    drop table(:sandbox_reads)
  end

  def down do
    execute("SET LOCAL lock_timeout = '5s'")

    create table(:sandbox_reads, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :sandbox_id, references(:sandboxes, type: :binary_id, on_delete: :delete_all),
        null: false

      add :expires_at, :utc_datetime_usec, null: false
      add :inserted_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create index(:sandbox_reads, [:sandbox_id, :expires_at])
  end
end
