defmodule Fountain.Repo.Migrations.NameChatgptGrants do
  use Ecto.Migration

  # ADR 0060 decision 1: a user may hold several ChatGPT grants, each a named
  # row. The one-row-per-user index goes; a name unique per owner and an
  # upstream account unique per owner take its place, so one subscription
  # never gets two refresh chains under two names.
  # `platform_chatgpt_account_platform_row` is untouched: the deployment
  # still has exactly one grant, and it keeps a NULL name.
  #
  # `(id, user_id)` is unique by construction. The index is for ADR 0060
  # stage 2: a credential set that names a grant references the id and its
  # owner together, so the database refuses a cross-owner reference. That
  # reference is not built, and nothing uses the index until it is.
  #
  # No backfill. `20260912020000` refused to run with an owned row and no
  # released writer has created one since. Should one exist, the check
  # constraint fails this migration, which is the right outcome: a name is
  # not invented for a row whose encryption nobody vouches for.
  def up do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '30s'")

    alter table(:platform_chatgpt_account) do
      add :name, :string
    end

    create constraint(:platform_chatgpt_account, :chatgpt_grant_name_follows_owner,
             check:
               "(user_id IS NULL AND name IS NULL) OR " <>
                 "(user_id IS NOT NULL AND name IS NOT NULL AND btrim(name) <> '')"
           )

    drop unique_index(:platform_chatgpt_account, [:user_id], where: "user_id IS NOT NULL")

    create unique_index(:platform_chatgpt_account, [:user_id, :name],
             where: "user_id IS NOT NULL"
           )

    create unique_index(:platform_chatgpt_account, [:user_id, :account_id],
             where: "user_id IS NOT NULL"
           )

    create unique_index(:platform_chatgpt_account, [:id, :user_id])
  end

  # Not lossless once a user holds two grants, and it does not pretend to be:
  # there is no "default grant" to keep, and deleting a rotating refresh
  # token cannot be undone. It refuses instead.
  def down do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '30s'")

    execute("""
    DO $$ BEGIN
      IF EXISTS (
        SELECT 1 FROM platform_chatgpt_account
        WHERE user_id IS NOT NULL GROUP BY user_id HAVING count(*) > 1
      ) THEN
        RAISE EXCEPTION 'A user holds several ChatGPT grants: disconnect all but one before restoring the one-per-user index';
      END IF;
    END $$;
    """)

    drop unique_index(:platform_chatgpt_account, [:id, :user_id])

    drop unique_index(:platform_chatgpt_account, [:user_id, :account_id],
           where: "user_id IS NOT NULL"
         )

    drop unique_index(:platform_chatgpt_account, [:user_id, :name], where: "user_id IS NOT NULL")
    drop constraint(:platform_chatgpt_account, :chatgpt_grant_name_follows_owner)

    alter table(:platform_chatgpt_account) do
      remove :name
    end

    create unique_index(:platform_chatgpt_account, [:user_id], where: "user_id IS NOT NULL")
  end
end
