defmodule Fountain.Repo.Migrations.TombstoneDisconnectedChatgptGrants do
  use Ecto.Migration

  # A user's grant that is disconnected stays as a row with no tokens (ADR
  # 0060 decision 3, as clarified): its id and name outlive the credential,
  # so what named it still names it and can say which subscription is gone.
  # That needs `access_token_ciphertext` to be nullable, which it was not.
  #
  # `chatgpt_grant_tokens_follow_status` then holds the rule in the
  # database, both ways: a `disconnected` row is a user's and holds no token
  # at all, and every other row holds an access token, which is what NOT
  # NULL used to say. The platform grant is deleted on disconnect, as
  # before, and is never `disconnected`.
  #
  # Dropping NOT NULL is a catalog change and the check validates a table of
  # at most one row. A node that predates this writes only the platform row,
  # with an access token, which passes.
  def up do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '30s'")

    alter table(:platform_chatgpt_account) do
      modify :access_token_ciphertext, :binary, null: true, from: {:binary, null: false}
    end

    create constraint(:platform_chatgpt_account, :chatgpt_grant_tokens_follow_status,
             check:
               "(status = 'disconnected' AND user_id IS NOT NULL AND " <>
                 "access_token_ciphertext IS NULL AND refresh_token_ciphertext IS NULL) OR " <>
                 "(status <> 'disconnected' AND access_token_ciphertext IS NOT NULL)"
           )
  end

  # A disconnected row cannot be given back a token it no longer has, and it
  # is not deleted on the way down: something may still name it.
  def down do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '30s'")

    execute("""
    DO $$ BEGIN
      IF EXISTS (SELECT 1 FROM platform_chatgpt_account WHERE status = 'disconnected') THEN
        RAISE EXCEPTION 'Disconnected ChatGPT grants hold no token: remove them before restoring NOT NULL on access_token_ciphertext';
      END IF;
    END $$;
    """)

    drop constraint(:platform_chatgpt_account, :chatgpt_grant_tokens_follow_status)

    alter table(:platform_chatgpt_account) do
      modify :access_token_ciphertext, :binary, null: false, from: {:binary, null: true}
    end
  end
end
