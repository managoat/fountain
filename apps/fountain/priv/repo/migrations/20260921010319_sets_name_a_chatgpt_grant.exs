defmodule Fountain.Repo.Migrations.SetsNameAChatgptGrant do
  use Ecto.Migration

  # ADR 0060 decision 2: an inference credential set may name one ChatGPT
  # grant. A reference, never a token: the grant keeps its own row, lifecycle
  # and fencing, and the set says which one serves codex.
  #
  # The reference is composite, `(chatgpt_grant_id, user_id)` to the grant's
  # `(id, user_id)` (`platform_chatgpt_account_id_user_id_index`, from
  # `20260920235854`), so "a set names only a grant its owner holds" is a
  # fact of the database and not only of a changeset. It also keeps the
  # deployment's grant out of reach: that row's `user_id` is NULL, a set's
  # never is, and no pair with a user in it equals a pair with NULL in it.
  #
  # NO ACTION, on purpose, and neither of the other two:
  #
  #   * Nilifying would turn a set whose grant went away into a set with no
  #     grant, and its next codex run would resolve to the set's API key or
  #     to platform inference: the silent switch of quota and bill that
  #     decision 4 forbids. A user's disconnect keeps the row as a tombstone
  #     for exactly this reason, and `ChatGPTAccounts.remove_for_user/3`
  #     refuses a grant a set still names before this constraint has to.
  #   * RESTRICT is checked immediately. Deleting an account cascades to its
  #     sets and to its grants in one statement, in an order nobody chose,
  #     and NO ACTION is checked once that statement's cascades are done.
  #
  # No backfill and nothing to validate: the column is new and NULL in every
  # row. `revision` is not bumped when a set is repointed (the trigger looks
  # only at the four ciphertexts): a grant source's identity is the grant, so
  # a repoint already reads as a different source, and a peer bound to the
  # set's API key has lost nothing.
  def up do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '30s'")

    alter table(:inference_credentials) do
      add :chatgpt_grant_id,
          references(:platform_chatgpt_account,
            type: :binary_id,
            with: [user_id: :user_id],
            on_delete: :nothing
          )
    end

    # "Which sets name this grant", for the removal refusal and the account
    # surface. Most sets name none.
    create index(:inference_credentials, [:chatgpt_grant_id],
             where: "chatgpt_grant_id IS NOT NULL"
           )
  end

  def down do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '30s'")

    drop index(:inference_credentials, [:chatgpt_grant_id], where: "chatgpt_grant_id IS NOT NULL")

    alter table(:inference_credentials) do
      remove :chatgpt_grant_id
    end
  end
end
