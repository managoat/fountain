defmodule Fountain.Repo.Migrations.DropEnvironmentLayers do
  @moduledoc """
  Drops what the portable environment layer cache (ADR 0090, retired) left in
  the database, undoing `20261018130000_add_environment_layer_builds`,
  `20261018140000_add_build_broker_sessions` and
  `20261018150000_add_environment_probe_sessions`:

  - the `environment_layer_builds` table;
  - the `environment_build_generation` trigger on `environments` and the
    `environment_secret_generation` trigger on `secrets`, with their
    functions;
  - `environments.cache_enabled`, `build_script`, `build_policy_revision` and
    `build_generation`;
  - `broker_sessions.environment_layer_build_id`, `probe_environment_id`,
    `probe_generation` and `probe_policy_revision`, the
    `broker_session_one_owner` and `broker_probe_complete` constraints, and
    `conversation_id` becomes `NOT NULL` again.

  The previous release removed the code and stopped reading or writing any of
  it; the columns stayed for one release because the release before that
  selects them. A broker session without a conversation could only belong to
  a build or a probe, so any left are deleted first.

  `down/0` restores the structure, empty.
  """
  use Ecto.Migration

  def up do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '60s'")

    execute("DELETE FROM broker_sessions WHERE conversation_id IS NULL")
    drop constraint(:broker_sessions, :broker_probe_complete)
    drop constraint(:broker_sessions, :broker_session_one_owner)
    drop index(:broker_sessions, [:probe_environment_id])
    drop index(:broker_sessions, [:environment_layer_build_id])

    alter table(:broker_sessions) do
      remove :probe_environment_id
      remove :probe_generation
      remove :probe_policy_revision
      remove :environment_layer_build_id
      modify :conversation_id, :binary_id, null: false
    end

    execute("DROP TRIGGER IF EXISTS environment_secret_generation ON secrets")
    execute("DROP FUNCTION IF EXISTS fountain_environment_secret_generation()")
    execute("DROP TRIGGER IF EXISTS environment_build_generation ON environments")
    execute("DROP FUNCTION IF EXISTS fountain_environment_build_generation()")

    drop table(:environment_layer_builds)

    alter table(:environments) do
      remove :cache_enabled
      remove :build_script
      remove :build_policy_revision
      remove :build_generation
    end
  end

  def down do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '60s'")

    alter table(:environments) do
      add :cache_enabled, :boolean, default: false, null: false
      add :build_script, :text, default: "", null: false
      add :build_policy_revision, :uuid, default: fragment("gen_random_uuid()"), null: false
      add :build_generation, :uuid, default: fragment("gen_random_uuid()"), null: false
    end

    create table(:environment_layer_builds, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :user_id, references(:users, type: :uuid, on_delete: :nilify_all)
      add :environment_id, references(:environments, type: :uuid, on_delete: :nilify_all)
      add :sandbox_id, references(:sandboxes, type: :uuid, on_delete: :nilify_all)
      add :owner_ref, :uuid, null: false
      add :environment_ref, :uuid, null: false
      add :policy_revision, :uuid, null: false
      add :generation, :uuid, null: false
      add :store_ref, :string, null: false
      add :fingerprint, :string, null: false
      add :binding, :map, null: false
      add :revisions, {:array, :string}, null: false
      add :state, :string, default: "queued", null: false
      add :claim, :uuid
      add :deadline_at, :utc_datetime, null: false
      add :expires_at, :utc_datetime, null: false
      add :cleanup_after, :utc_datetime, null: false
      add :cleanup_pending, :boolean, default: true, null: false
      add :ciphertext_sha256, :string
      add :ciphertext_bytes, :bigint
      add :wrapped_identity, :binary
      timestamps(type: :utc_datetime)
    end

    create unique_index(:environment_layer_builds, [:sandbox_id])

    create unique_index(
             :environment_layer_builds,
             [:environment_id, :generation, :fingerprint, :store_ref],
             where: "state IN ('queued', 'building', 'ready')",
             name: :environment_layer_live_generation
           )

    create index(:environment_layer_builds, [:cleanup_pending, :state])

    create constraint(:environment_layer_builds, :environment_layer_state,
             check: "state IN ('queued', 'building', 'ready', 'failed', 'canceled', 'expired')"
           )

    execute """
    CREATE FUNCTION fountain_environment_build_generation() RETURNS trigger AS $$
    BEGIN
      IF ROW(NEW.cache_enabled, NEW.build_script, NEW.packages, NEW.env_vars,
             NEW.repositories, NEW.setup_timeout_seconds)
         IS DISTINCT FROM
         ROW(OLD.cache_enabled, OLD.build_script, OLD.packages, OLD.env_vars,
             OLD.repositories, OLD.setup_timeout_seconds) THEN
        NEW.build_generation := gen_random_uuid();
      END IF;
      IF ROW(NEW.networking_type, NEW.networking_config)
         IS DISTINCT FROM ROW(OLD.networking_type, OLD.networking_config) THEN
        NEW.build_policy_revision := gen_random_uuid();
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """

    execute """
    CREATE TRIGGER environment_build_generation BEFORE UPDATE ON environments
      FOR EACH ROW EXECUTE FUNCTION fountain_environment_build_generation();
    """

    execute """
    CREATE FUNCTION fountain_environment_secret_generation() RETURNS trigger AS $$
    BEGIN
      IF TG_OP = 'UPDATE' AND ROW(NEW.key, NEW.value_ciphertext, NEW.environment_id)
         IS NOT DISTINCT FROM ROW(OLD.key, OLD.value_ciphertext, OLD.environment_id) THEN
        RETURN NEW;
      END IF;
      IF TG_OP <> 'INSERT' THEN
        UPDATE environments SET build_generation = gen_random_uuid() WHERE id = OLD.environment_id;
      END IF;
      IF TG_OP <> 'DELETE' THEN
        UPDATE environments SET build_generation = gen_random_uuid() WHERE id = NEW.environment_id;
        RETURN NEW;
      END IF;
      RETURN OLD;
    END;
    $$ LANGUAGE plpgsql;
    """

    execute """
    CREATE TRIGGER environment_secret_generation AFTER INSERT OR UPDATE OR DELETE ON secrets
      FOR EACH ROW EXECUTE FUNCTION fountain_environment_secret_generation();
    """

    alter table(:broker_sessions) do
      modify :conversation_id, :binary_id, null: true

      add :environment_layer_build_id,
          references(:environment_layer_builds, type: :binary_id, on_delete: :delete_all)

      add :probe_environment_id,
          references(:environments, type: :binary_id, on_delete: :delete_all)

      add :probe_generation, :binary_id
      add :probe_policy_revision, :binary_id
    end

    create index(:broker_sessions, [:environment_layer_build_id])
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
end
