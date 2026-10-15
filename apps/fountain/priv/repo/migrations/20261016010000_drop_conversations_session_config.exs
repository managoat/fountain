defmodule Fountain.Repo.Migrations.DropConversationsSessionConfig do
  use Ecto.Migration

  @moduledoc """
  Drops `conversations.session_config`, a conversation's own ACP session
  config options (ADR 0062, addendum of 2026-10-15, agent only).

  The release before this one stopped mapping the column, refused a
  conversation's and a prompt's `session_config`, and folded every
  conversation's value into `agent_session_config`
  (`20261016000000_fold_conversation_session_config`), which is what each
  turn requests. A node still running that release does not select the
  column. No index, trigger, view or function reads it.

  `down/0` restores the column with its default, empty: what it held is in
  `agent_session_config` already.
  """

  def up do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '30s'")
    execute("ALTER TABLE conversations DROP COLUMN IF EXISTS session_config")
  end

  def down do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '30s'")

    alter table(:conversations) do
      add :session_config, :map, null: false, default: %{}
    end
  end
end
