defmodule Fountain.Repo.Migrations.DropSandboxLeaseUntil do
  use Ecto.Migration

  @moduledoc """
  The contract step of reducing the machine lease to a holder of this boot
  (ADR 0058's second 2026-10-14 addendum, ADR 0072, #2685). That release
  stopped writing `sandboxes.lease_until` and left it mapped, because the
  release before it selects the column with every sandbox it loads. Take this
  only once that release is fully deployed.

  `down/0` restores the column, not its values: a lease is live by its
  holder now, and nothing reads a deadline.
  """

  def up do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("ALTER TABLE sandboxes DROP COLUMN lease_until")
  end

  def down do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("ALTER TABLE sandboxes ADD COLUMN lease_until timestamp(6) without time zone")
  end
end
