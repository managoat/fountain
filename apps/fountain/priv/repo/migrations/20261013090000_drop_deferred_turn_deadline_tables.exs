defmodule Fountain.Repo.Migrations.DropDeferredTurnDeadlineTables do
  @moduledoc """
  The contract step for the ADR 0046 removal (#2636).

  That release stopped reading and writing `turn_executions`,
  `execution_allowances`, `turns.limit_reason` and `users.execution_limits`
  but left them in place: the release before it inserts an
  `execution_allowances` row on every launch and selects `limit_reason` with
  every turn, so dropping them during a rolling deploy would fail its
  replicas' launches. Take this only after the release that removed the
  journal is fully rolled out.

  `down` restores the shape (taken from the schema the earlier migrations
  produce), not the rows.
  """
  use Ecto.Migration

  def up do
    drop_if_exists table(:turn_executions)
    drop_if_exists table(:execution_allowances)

    execute "ALTER TABLE turns DROP COLUMN IF EXISTS limit_reason"
    execute "ALTER TABLE users DROP CONSTRAINT IF EXISTS users_execution_limits_object"
    execute "ALTER TABLE users DROP COLUMN IF EXISTS execution_limits"
  end

  def down do
    execute "ALTER TABLE users ADD COLUMN execution_limits jsonb DEFAULT '{}'::jsonb NOT NULL"

    execute """
    ALTER TABLE users ADD CONSTRAINT users_execution_limits_object
      CHECK (jsonb_typeof(execution_limits) = 'object'::text)
    """

    execute "ALTER TABLE turns ADD COLUMN limit_reason text"

    execute """
    CREATE TABLE execution_allowances (
        conversation_id uuid NOT NULL
          CONSTRAINT execution_allowances_conversation_id_fkey
          REFERENCES conversations(id) ON DELETE CASCADE,
        limits jsonb DEFAULT '{}'::jsonb NOT NULL,
        revision uuid NOT NULL,
        inserted_at timestamp without time zone NOT NULL,
        updated_at timestamp without time zone NOT NULL,
        CONSTRAINT execution_allowances_pkey PRIMARY KEY (conversation_id)
    )
    """

    execute """
    CREATE TABLE turn_executions (
        id uuid NOT NULL CONSTRAINT turn_executions_pkey PRIMARY KEY,
        turn_id uuid NOT NULL,
        conversation_id uuid NOT NULL,
        user_id uuid NOT NULL,
        sandbox_id uuid NOT NULL,
        sandbox_name text NOT NULL,
        provider text NOT NULL,
        connection_id uuid NOT NULL,
        provider_session_id text,
        deadline_at timestamp without time zone NOT NULL,
        state text NOT NULL,
        spawn_submitted_at timestamp without time zone,
        attempt_id uuid,
        submitted_at timestamp without time zone,
        confirmed_at timestamp without time zone,
        last_error text,
        inserted_at timestamp without time zone NOT NULL,
        updated_at timestamp without time zone NOT NULL,
        deadline_event_id bigint,
        execution_limits jsonb DEFAULT '{}'::jsonb NOT NULL,
        CONSTRAINT turn_executions_limits_object
          CHECK (jsonb_typeof(execution_limits) = 'object'::text),
        CONSTRAINT turn_executions_state_check
          CHECK (state = ANY (ARRAY['active'::text, 'awaiting_identity'::text, 'ready'::text,
                                   'submitted'::text, 'uncertain'::text, 'stopped'::text,
                                   'completed'::text]))
    )
    """

    execute "CREATE INDEX turn_executions_connection_id_index ON turn_executions (connection_id)"

    execute """
    CREATE UNIQUE INDEX turn_executions_open_conversation_index ON turn_executions (conversation_id)
      WHERE state <> ALL (ARRAY['completed'::text, 'stopped'::text])
    """

    execute """
    CREATE INDEX turn_executions_sandbox_id_index ON turn_executions (sandbox_id)
      WHERE state <> ALL (ARRAY['completed'::text, 'stopped'::text])
    """

    execute "CREATE INDEX turn_executions_state_deadline_at_index ON turn_executions (state, deadline_at)"
    execute "CREATE UNIQUE INDEX turn_executions_turn_id_index ON turn_executions (turn_id)"
  end
end
