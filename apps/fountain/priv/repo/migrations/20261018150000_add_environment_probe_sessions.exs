defmodule Fountain.Repo.Migrations.AddEnvironmentProbeSessions do
  use Ecto.Migration

  def up do
    drop constraint(:broker_sessions, :broker_session_one_owner)

    alter table(:broker_sessions) do
      add :probe_environment_id,
          references(:environments, type: :binary_id, on_delete: :delete_all)

      add :probe_generation, :binary_id
      add :probe_policy_revision, :binary_id
    end

    create index(:broker_sessions, [:probe_environment_id])

    create constraint(:broker_sessions, :broker_session_one_owner,
             check:
               "num_nonnulls(conversation_id, environment_layer_build_id, probe_environment_id) = 1"
           )

    create constraint(:broker_sessions, :broker_probe_complete,
             check:
               "(probe_environment_id IS NULL) = (probe_generation IS NULL) AND (probe_environment_id IS NULL) = (probe_policy_revision IS NULL)"
           )
  end

  def down do
    execute("DELETE FROM broker_sessions WHERE probe_environment_id IS NOT NULL")
    drop constraint(:broker_sessions, :broker_probe_complete)
    drop constraint(:broker_sessions, :broker_session_one_owner)

    drop index(:broker_sessions, [:probe_environment_id])

    alter table(:broker_sessions) do
      remove :probe_environment_id
      remove :probe_generation
      remove :probe_policy_revision
    end

    create constraint(:broker_sessions, :broker_session_one_owner,
             check: "(conversation_id IS NULL) <> (environment_layer_build_id IS NULL)"
           )
  end
end
