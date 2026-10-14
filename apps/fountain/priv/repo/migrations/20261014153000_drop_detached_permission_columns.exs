defmodule Fountain.Repo.Migrations.DropDetachedPermissionColumns do
  use Ecto.Migration

  @moduledoc """
  The contract step of removing permission requests that outlived their turn
  (#1635, removed in #2677 for #2676). That release stopped reading and
  writing these columns but left them in place, because every replica of the
  release before it selects `turns.waiting` and `turns.permission_deadline`
  with every turn row it loads. Take this only once that release is fully
  rolled out.

  `turns` loses `waiting`, `permission_deadline` and the partial index the
  expiry sweep read.

  `permission_policy` on `agents` and `conversations` loses any `ask_timeout`
  key. It was the one policy key whose value was seconds rather than a
  verdict, and the code that read it is gone, so a stored one would be read
  as a tool with an unknown verdict. Production holds none (checked
  2026-10-14); this is for an instance that set one.

  `down/0` restores the shape, not the values.
  """

  def up do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '60s'")

    drop_if_exists index(:turns, [:permission_deadline],
                     name: :turns_waiting_permission_deadline_index
                   )

    alter table(:turns) do
      remove :waiting
      remove :permission_deadline
    end

    execute("""
    UPDATE agents
       SET permission_policy = permission_policy - 'ask_timeout'
     WHERE permission_policy ? 'ask_timeout'
    """)

    execute("""
    UPDATE conversations
       SET permission_policy = permission_policy - 'ask_timeout'
     WHERE permission_policy ? 'ask_timeout'
    """)
  end

  def down do
    alter table(:turns) do
      add :waiting, :boolean, null: false, default: false
      add :permission_deadline, :utc_datetime
    end

    create index(:turns, [:permission_deadline],
             where: "waiting",
             name: :turns_waiting_permission_deadline_index
           )
  end
end
