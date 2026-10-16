defmodule Fountain.Repo.Migrations.AddEnvironmentLayerBuilds do
  use Ecto.Migration

  def up do
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
      # Immutable object-address components survive deletion for private-store cleanup.
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
  end

  def down do
    execute "DROP TRIGGER environment_secret_generation ON secrets"
    execute "DROP FUNCTION fountain_environment_secret_generation()"
    execute "DROP TRIGGER environment_build_generation ON environments"
    execute "DROP FUNCTION fountain_environment_build_generation()"
    drop table(:environment_layer_builds)

    alter table(:environments) do
      remove :cache_enabled
      remove :build_script
      remove :build_policy_revision
      remove :build_generation
    end
  end
end
