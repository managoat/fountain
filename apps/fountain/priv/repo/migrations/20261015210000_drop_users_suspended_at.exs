defmodule Fountain.Repo.Migrations.DropUsersSuspendedAt do
  @moduledoc """
  The contract step for removing account suspension (ADR 0011, 2026-10-15
  addendum).

  The release that removed suspension stopped reading `users.suspended_at`
  but left the column in place: the release before it selects the column
  with every user and checks it on every launch and turn, so dropping it
  during a rolling deploy would fail those replicas. Take this only after the
  release that removed suspension is fully rolled out.

  Self-serve email change kept its state in a signed token, not in the
  database, so it leaves nothing to drop here.

  `down` restores the column, not its values.
  """
  use Ecto.Migration

  def up do
    execute "ALTER TABLE users DROP COLUMN IF EXISTS suspended_at"
  end

  def down do
    execute "ALTER TABLE users ADD COLUMN IF NOT EXISTS suspended_at timestamp(0) without time zone"
  end
end
