defmodule Fountain.Repo.Migrations.RenameSandboxesSpriteNameToMachineName do
  use Ecto.Migration

  @moduledoc """
  The column takes the name the application has used since #2120
  (`Sandbox.machine_name`), because it names machines on every provider, not
  only Sprites (#2108).

  One step is safe because Managoat runs as one node and deploys with
  Recreate (ADR 0072): no release that reads `sprite_name` is running when
  this does. Postgres renames in the catalog alone, so the rows and the
  live-name unique index `sandboxes_live_machine_name_index` on
  `(provider, machine_name)` carry over unchanged. The rename still takes an
  ACCESS EXCLUSIVE lock on `sandboxes`, so it waits behind any open
  transaction that touched the table; the lock timeout makes a stuck wait
  fail the boot rather than hang it.

  The API keeps answering `sprite_name` beside `machine_name` until the
  Fountain-name aliases are removed (#2776); that is serialization, not
  this column.
  """

  def up do
    execute("SET LOCAL lock_timeout = '5s'")
    rename table(:sandboxes), :sprite_name, to: :machine_name
  end

  def down do
    execute("SET LOCAL lock_timeout = '5s'")
    rename table(:sandboxes), :machine_name, to: :sprite_name
  end
end
