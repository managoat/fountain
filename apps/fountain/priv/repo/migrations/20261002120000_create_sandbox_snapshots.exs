defmodule Fountain.Repo.Migrations.CreateSandboxSnapshots do
  use Ecto.Migration

  # ADR 0063: what a sandbox's disk looked like when it was last parked, so the
  # files API can answer while it sleeps. One row per sandbox, replaced by each
  # park and removed when the machine stops for good.
  #
  #   * `manifest_ciphertext` -- the repositories found, their diffs and
  #     statuses, and the directory listings, as a compressed term under the
  #     owner's DEK. Every listing, diff and status answer reads this alone.
  #   * `contents_ciphertext` -- the captured files' bytes, likewise. Only a
  #     file read decrypts it.
  #   * `file_count`, `content_bytes` -- what was kept, for operators; the
  #     values themselves never leave the ciphertexts.
  #
  # `user_id` cascades with the account and `sandbox_id` with the machine row,
  # so neither deletion has to know this table exists.
  def up do
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

  def down do
    execute("SET LOCAL lock_timeout = '5s'")
    drop table(:sandbox_snapshots)
  end
end
