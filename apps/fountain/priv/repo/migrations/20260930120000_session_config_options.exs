defmodule Fountain.Repo.Migrations.SessionConfigOptions do
  use Ecto.Migration

  # ADR 0062: ACP session config options (reasoning effort, fast mode).
  #
  # - `agents.session_config` and `conversations.session_config` hold the
  #   requested options, id to value. The conversation's keys override the agent's. Both default to
  #   an empty map, so every existing row requests nothing and runs as before.
  # - `conversations.session_config_options` is the option list the adapter last
  #   advertised. It stays null until a turn reports one.
  # - `turns.config_selection` records what a turn asked for and what the
  #   adapter applied, skipped or refused.
  #
  # A constant default is metadata-only in PostgreSQL 11+, so nothing is
  # rewritten. The lock is still ACCESS EXCLUSIVE on tables every turn
  # writes, so give up after five seconds rather than queue behind a reader.
  def change do
    execute("SET LOCAL lock_timeout = '5s'", "SET LOCAL lock_timeout = '5s'")

    alter table(:agents) do
      add :session_config, :map, null: false, default: %{}
    end

    alter table(:conversations) do
      add :session_config, :map, null: false, default: %{}
      add :session_config_options, {:array, :map}
    end

    alter table(:turns) do
      add :config_selection, :map
    end
  end
end
