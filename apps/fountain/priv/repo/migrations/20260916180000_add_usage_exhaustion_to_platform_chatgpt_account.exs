defmodule Fountain.Repo.Migrations.AddUsageExhaustionToPlatformChatgptAccount do
  use Ecto.Migration

  def up do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '30s'")

    # When the grant's ChatGPT account last ran out of Codex usage, and when
    # the provider said it resets (#2362, ADR 0047 decision 6). Selection
    # skips the grant while `usage_exhausted_until` is in the future. Nullable
    # with no default: a catalog change on a table of at most one row, and an
    # old writer that never sets them leaves them nil, which reads as "not
    # exhausted".
    alter table(:platform_chatgpt_account) do
      add :usage_exhausted_at, :utc_datetime
      add :usage_exhausted_until, :utc_datetime
    end
  end

  def down do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '30s'")

    alter table(:platform_chatgpt_account) do
      remove :usage_exhausted_until
      remove :usage_exhausted_at
    end
  end
end
