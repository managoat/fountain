defmodule Fountain.Repo.Migrations.DropSecretBindings do
  @moduledoc """
  The contract step for the credential bindings removal (ADR 0019 gate 1b,
  addendum of 2026-10-13).

  That release stopped reading `secret_bindings` but left it in place: a
  rolling deploy runs a migration while replicas of the previous release still
  serve, and those read the table on every brokered provision. Take this only
  after the release that removed bindings is fully rolled out; the release
  before this one reads nothing here.

  Nothing else references the table. `down` restores its exact shape (taken
  from the schema the earlier migration produces), not its rows.
  """
  use Ecto.Migration

  def up do
    drop_if_exists table(:secret_bindings)
  end

  def down do
    execute """
    CREATE TABLE secret_bindings (
        id uuid NOT NULL,
        user_id uuid NOT NULL,
        key character varying(255) NOT NULL,
        host character varying(255) NOT NULL,
        auth_type character varying(255) NOT NULL,
        header character varying(255),
        prefix character varying(255),
        username character varying(255),
        headers jsonb DEFAULT '{}'::jsonb NOT NULL,
        enabled boolean DEFAULT true NOT NULL,
        inserted_at timestamp(0) without time zone NOT NULL,
        updated_at timestamp(0) without time zone NOT NULL
    )
    """

    execute "ALTER TABLE ONLY secret_bindings ADD CONSTRAINT secret_bindings_pkey PRIMARY KEY (id)"

    execute """
    CREATE UNIQUE INDEX secret_bindings_user_id_key_host_index
      ON secret_bindings USING btree (user_id, key, host)
    """

    execute """
    CREATE INDEX secret_bindings_user_id_key_index
      ON secret_bindings USING btree (user_id, key)
    """

    execute """
    ALTER TABLE ONLY secret_bindings
      ADD CONSTRAINT secret_bindings_user_id_fkey FOREIGN KEY (user_id)
      REFERENCES users(id) ON DELETE CASCADE
    """
  end
end
