defmodule Fountain.Repo.Migrations.ConversationsModel do
  use Ecto.Migration

  # ADR 0061: a conversation may run a different model from its agent. Null
  # means the agent's model, so every existing row keeps following its agent.
  #
  # Nullable with no default, so no rewrite, but the lock is ACCESS EXCLUSIVE
  # and `conversations` is written by every turn: give up after five seconds
  # rather than queue all of them behind a long reader.
  def change do
    execute("SET LOCAL lock_timeout = '5s'", "SET LOCAL lock_timeout = '5s'")

    alter table(:conversations) do
      add :model, :string
    end
  end
end
