defmodule Fountain.Repo.Migrations.CreateSandboxReads do
  use Ecto.Migration

  # One row per admitted sandbox-files read (#2394): the window in which the
  # read may be at the provider. `Fountain.Machines.Reads` inserts it under the
  # per-sandbox advisory lock, deletes it when the read returns, and a park or
  # a destroy waits for the unexpired ones before its provider call.
  def change do
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
