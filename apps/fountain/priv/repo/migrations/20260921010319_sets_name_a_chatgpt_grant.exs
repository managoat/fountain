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
  #   * RESTRICT is checked immediately and can never be deferred, and
  #     deleting an account cascades to its sets and to its grants from one
  #     statement.
  #
  # DEFERRABLE INITIALLY DEFERRED, for that same account deletion. `DELETE
  # FROM users` reaches the sets and the grants through two RI cascade
  # triggers, and PostgreSQL fires them in trigger-name order, which is
  # `RI_ConstraintTrigger_a_<oid>` compared as text: an order nobody chose,
  # and one a dump and restore, or dropping and recreating either key, can
  # flip. A NO ACTION key that is not deferred is checked at the end of the
  # statement that deleted the referenced row, and that statement is the
  # grants' cascade, not the user's delete: if it runs first the sets are
  # still there and the whole deletion fails on this key, a failure of an
  # irreversible request the user can do nothing about. Deferred, the check
  # runs at COMMIT, when both cascades are done, whatever their order.
  #
  # What deferral costs: a violation raises at COMMIT instead of becoming a
  # changeset error at the statement, so nothing here is a user-facing guard.
  # The guards are `InferenceCredentials.set_grant/3`'s owner-scoped read and
  # `remove_for_user/3`'s `{:named_by_sets, _}`, both under the owner's source
  # lock; this key is the backstop that holds whatever the code does.
  #
  # No backfill and nothing to validate: the column is new and NULL in every
  # row. `revision` is not bumped when a set is repointed (the trigger looks
  # only at the four ciphertexts): a grant source's identity is the grant, so
  # a repoint already reads as a different source. A codex conversation bound
  # to the set's API key reads as changed too, through resolution rather than
  # through `revision`; any other runtime's keeps validating.
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

    # `references/2` has no option for it. `down` needs no counterpart:
    # removing the column drops the constraint.
    execute("""
    ALTER TABLE inference_credentials
      ALTER CONSTRAINT inference_credentials_chatgpt_grant_id_fkey
      DEFERRABLE INITIALLY DEFERRED
    """)

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
