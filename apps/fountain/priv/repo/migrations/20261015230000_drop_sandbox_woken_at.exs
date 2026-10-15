defmodule Fountain.Repo.Migrations.DropSandboxWokenAt do
  use Ecto.Migration

  @moduledoc """
  Drops `sandboxes.woken_at`, the last sandbox column no schema maps.

  It was the wake-registration marker of ADR 0058 stage 6a
  (`20260916190000_add_sandbox_woken_at`), which a local registry made
  unnecessary (ADR 0072). The schema stopped mapping it in an earlier
  release, so a node still running that release does not select it. No
  index, trigger, view or function reads it.

  The other columns once unmapped here are gone already: `mode`, `runtime`,
  `codex_inference_source` and `codex_peer_homes` in
  `20261014191000_drop_home_columns`, and `applied_skills` in
  `20261013200000_drop_vestigial_columns`.

  `down/0` restores the column empty.
  """

  def up do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '30s'")
    execute("ALTER TABLE sandboxes DROP COLUMN IF EXISTS woken_at")
  end

  def down do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '30s'")

    alter table(:sandboxes) do
      add :woken_at, :utc_datetime_usec
    end
  end
end
