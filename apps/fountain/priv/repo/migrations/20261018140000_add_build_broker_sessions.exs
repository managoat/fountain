defmodule Fountain.Repo.Migrations.AddBuildBrokerSessions do
  use Ecto.Migration

  def up do
    alter table(:broker_sessions) do
      modify :conversation_id, :binary_id, null: true

      add :environment_layer_build_id,
          references(:environment_layer_builds, type: :binary_id, on_delete: :delete_all)
    end

    create index(:broker_sessions, [:environment_layer_build_id])

    create constraint(:broker_sessions, :broker_session_one_owner,
             check: "(conversation_id IS NULL) <> (environment_layer_build_id IS NULL)"
           )
  end

  def down do
    execute("DELETE FROM broker_sessions WHERE environment_layer_build_id IS NOT NULL")
    drop constraint(:broker_sessions, :broker_session_one_owner)
    drop index(:broker_sessions, [:environment_layer_build_id])

    alter table(:broker_sessions) do
      remove :environment_layer_build_id
      modify :conversation_id, :binary_id, null: false
    end
  end
end
