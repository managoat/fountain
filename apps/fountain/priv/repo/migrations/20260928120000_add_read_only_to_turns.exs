defmodule Fountain.Repo.Migrations.AddReadOnlyToTurns do
  use Ecto.Migration

  def up do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '30s'")

    # Whether the prompt that opened this turn asked for it to run read-only
    # (#2533). The row is the record every later launch of the turn reads: a
    # relaunch after a crash, a restarted session and a reattach after a deploy
    # all enforce what the row says, not what a message once carried.
    #
    # NOT NULL with a constant default is a catalog change on PostgreSQL 11+,
    # not a rewrite. A replica on the previous release never writes it, and
    # `false` is what every turn it opens is.
    alter table(:turns) do
      add :read_only, :boolean, null: false, default: false
    end
  end

  def down do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '30s'")

    alter table(:turns) do
      remove :read_only
    end
  end
end
