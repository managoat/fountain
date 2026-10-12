defmodule Fountain.Repo.Migrations.DropBuzzIdentities do
  @moduledoc """
  The Buzz extension is gone (simplify 3/5), and with it the one table its own
  migrations created (20260816120000 and the three that altered it, once
  core's, then the extension's under #1507). Core drops it because nothing else
  will: an uninstalled extension contributes no migration path.

  `IF EXISTS`, because a core-only release never applied the extension's
  migrations and so never had the table. Pending jobs for the harness sweep go
  too, under its current and its pre-#1507 worker name, since no worker module
  is left to run them.

  The previous release, still serving during a rolling deploy, reads the table
  in three places: its own `/api/buzz` routes, the admin users column, and the
  per-turn MCP fan-out. The fan-out and the admin column are isolated by
  `Fountain.Extensions` and degrade to "no contribution" with a logged error;
  the routes belong to the feature being removed.

  `down` restores the empty table, not its rows.
  """
  use Ecto.Migration

  def up do
    execute """
    DELETE FROM oban_jobs
    WHERE worker IN ('FountainBuzz.Workers.HarnessSweep', 'Fountain.Workers.BuzzHarnessSweep')
    """

    execute "DROP TABLE IF EXISTS buzz_identities"
  end

  def down do
    create_if_not_exists table(:buzz_identities, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :agent_id, references(:agents, type: :binary_id, on_delete: :delete_all), null: false
      add :vault_id, references(:vaults, type: :binary_id, on_delete: :delete_all), null: false
      add :environment_id, references(:environments, type: :binary_id, on_delete: :nilify_all)
      add :name, :string, null: false
      add :relay_url, :string, null: false
      add :pubkey, :string
      add :display_name, :string
      add :enabled, :boolean, null: false, default: true
      add :respond_to, :string, null: false, default: "owner-only"
      add :respond_to_allowlist, {:array, :string}, null: false, default: []
      add :sandbox_mode, :string

      timestamps(type: :utc_datetime)
    end

    create_if_not_exists index(:buzz_identities, [:user_id])
    create_if_not_exists index(:buzz_identities, [:environment_id])

    create_if_not_exists unique_index(:buzz_identities, [:user_id, :name],
                           name: "buzz_identities_user_id_name_index"
                         )

    create_if_not_exists unique_index(:buzz_identities, [:user_id, :pubkey],
                           where: "pubkey IS NOT NULL",
                           name: "buzz_identities_user_id_pubkey_index"
                         )
  end
end
