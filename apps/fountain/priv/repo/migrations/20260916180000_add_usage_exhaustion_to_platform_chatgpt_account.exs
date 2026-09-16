defmodule Fountain.Repo.Migrations.AddUsageExhaustionToPlatformChatgptAccount do
  use Ecto.Migration

  def up do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '30s'")

    # When OpenAI confirmed the grant's ChatGPT account ran out of Codex
    # usage, and when it said the usage resets (#2362, ADR 0047 decision 6).
    # Selection skips the grant while `usage_exhausted_until` is in the
    # future. `usage_checked_at` throttles the server's check. Nullable
    # with no default: a catalog change on a table of at most one row, and an
    # old writer that never sets them leaves them nil, which reads as "not
    # exhausted".
    alter table(:platform_chatgpt_account) do
      add :usage_exhausted_at, :utc_datetime
      add :usage_exhausted_until, :utc_datetime
      add :usage_checked_at, :utc_datetime
    end
  end

  def down do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '30s'")

    alter table(:platform_chatgpt_account) do
      remove :usage_checked_at
      remove :usage_exhausted_until
      remove :usage_exhausted_at
    end
  end
end
