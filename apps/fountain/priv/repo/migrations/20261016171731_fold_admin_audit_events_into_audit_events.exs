defmodule Fountain.Repo.Migrations.FoldAdminAuditEventsIntoAuditEvents do
  @moduledoc """
  Copies every `admin_audit_events` row into `audit_events`, the one audit
  trail since 2026-10-15 (ADR 0013 addendum).

  Each row keeps its actor and its target:

    * `action` is the old `event_type`.
    * `actor` is `admin:<actor_user_id>`, or `system:<metadata.via>` for a
      system action (the first-admin bootstrap, the retired release task).
    * The target is the resource: `user` / `<target_user_id>`, or for
      `admin.sandbox.reaped`, which had no target account, `sandbox` /
      `<metadata.sandbox_id>`.
    * `user_id` is null, as for every admin row, so it is in no tenant's own
      trail and no account deletion can nilify it.
    * `metadata` gains `admin_audit_event_id`, the source row's id, which is
      what makes this copy idempotent and `down/0` exact.

  `admin.role.granted` therefore survives in `audit_events`, which is what
  `Fountain.Accounts.admin_bootstrapped?/0` now reads, and the retention
  pruner skips `admin.*` rows. Also indexes `audit_events.action` for that
  read.

  The table stays for one release, unread, and is dropped by the migration
  after this one in the next release.
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

    create_if_not_exists index(:audit_events, [:action])
  end

  def down do
    drop_if_exists index(:audit_events, [:action])

    execute("""
    DELETE FROM audit_events
    WHERE user_id IS NULL AND action LIKE 'admin.%' AND metadata ? 'admin_audit_event_id'
    """)
  end
end
