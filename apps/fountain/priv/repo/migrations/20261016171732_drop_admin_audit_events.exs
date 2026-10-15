defmodule Fountain.Repo.Migrations.DropAdminAuditEvents do
  @moduledoc """
  Drops `admin_audit_events`, one release after its rows were copied into
  `audit_events` (`20261016171731_fold_admin_audit_events_into_audit_events`,
  ADR 0013's 2026-10-15 addendum). Nothing has read or written it since.

  Before dropping, it copies any row the fold has not (by
  `metadata.admin_audit_event_id`), so a row written by an older node between
  the two migrations is not lost.

  `down/0` recreates the table empty; the rows live on in `audit_events`.
  """
  use Ecto.Migration

  def up do
    execute("SET LOCAL lock_timeout = '5s'")

    execute("""
    INSERT INTO audit_events (action, resource_type, resource_id, actor, metadata, inserted_at, user_id)
    SELECT
      a.event_type,
      CASE WHEN a.target_user_id IS NULL AND a.event_type = 'admin.sandbox.reaped'
           THEN 'sandbox' ELSE 'user' END,
      CASE WHEN a.target_user_id IS NOT NULL THEN a.target_user_id::text
           WHEN a.event_type = 'admin.sandbox.reaped' THEN a.metadata->>'sandbox_id'
           ELSE NULL END,
      CASE WHEN a.actor_user_id IS NOT NULL THEN 'admin:' || a.actor_user_id::text
           ELSE 'system:' || COALESCE(a.metadata->>'via', 'unknown') END,
      a.metadata || jsonb_build_object('admin_audit_event_id', a.id),
      a.inserted_at,
      NULL
    FROM admin_audit_events a
    WHERE NOT EXISTS (
      SELECT 1 FROM audit_events e
      WHERE e.user_id IS NULL
        AND e.action = a.event_type
        AND (e.metadata->>'admin_audit_event_id')::bigint = a.id
    )
    """)

    drop table(:admin_audit_events)
  end

  def down do
    create table(:admin_audit_events) do
      add :actor_user_id, :binary_id
      add :target_user_id, :binary_id
      add :event_type, :string, null: false
      add :metadata, :map, null: false, default: %{}
      add :inserted_at, :utc_datetime, null: false
    end

    create index(:admin_audit_events, [:target_user_id])
    create index(:admin_audit_events, [:event_type])
    create index(:admin_audit_events, [:inserted_at])
  end
end
