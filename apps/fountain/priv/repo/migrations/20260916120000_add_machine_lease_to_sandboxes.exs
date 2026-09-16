defmodule Fountain.Repo.Migrations.AddMachineLeaseToSandboxes do
  use Ecto.Migration

  def up do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '30s'")

    # The machine owner's lease and in-flight state (ADR 0058). Additive and
    # unread: nothing writes these until the owner does, and every existing
    # fence stays in force until the gate flips. `lease_epoch` carries a
    # default so old and new writers agree on an un-leased row throughout the
    # rolling upgrade — a NOT NULL column with a constant default does not
    # rewrite the table on PostgreSQL 11 and later, so this stays a catalog
    # change under the ACCESS EXCLUSIVE lock the timeout bounds.
    #
    # No index: the owner reaches a lease by primary key, under the
    # per-sandbox advisory lock, and never scans for one.
    alter table(:sandboxes) do
      add :lease_epoch, :bigint, null: false, default: 0
      add :lease_node, :string
      add :lease_until, :utc_datetime_usec
      add :transition, :string
      add :transition_reason, :text
    end
  end

  def down do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '30s'")

    # Nothing outside `Fountain.Machines.Lease` reads these, so dropping them
    # costs no reader. A row mid-transition loses its intent; at this stage
    # none exists, and after the gate flips this migration is not the way back.
    alter table(:sandboxes) do
      remove :transition_reason
      remove :transition
      remove :lease_until
      remove :lease_node
      remove :lease_epoch
    end
  end
end
