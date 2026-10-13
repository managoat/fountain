defmodule Fountain.Repo.Migrations.CreateChatgptSubscriptions do
  use Ecto.Migration

  # ChatGPT subscriptions for the codex runtime, rebuilt small (ADR 0070): one
  # per user, plus at most one for the deployment (`user_id` NULL). The tables
  # of the retired design (ADR 0060) are not reused; a later migration drops
  # them. Both tokens are ciphertext: a user's under their DEK, the
  # deployment's under the master key (`Fountain.ChatGPT`).
  def change do
    create table(:chatgpt_subscriptions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all)
      add :account_id, :string, null: false
      add :chatgpt_user_id, :string
      add :plan_type, :string
      add :access_token_ciphertext, :binary, null: false
      add :refresh_token_ciphertext, :binary, null: false
      add :expires_at, :utc_datetime
      add :last_refreshed_at, :utc_datetime, null: false
      add :status, :string, null: false, default: "active"
      add :revoked_reason, :string

      timestamps(type: :utc_datetime)
    end

    create unique_index(:chatgpt_subscriptions, [:user_id])

    # NULLs are distinct in the index above, so the deployment's one row gets
    # an index of its own.
    create unique_index(:chatgpt_subscriptions, ["(user_id IS NULL)"],
             where: "user_id IS NULL",
             name: :chatgpt_subscriptions_one_platform_row
           )

    create constraint(:chatgpt_subscriptions, :chatgpt_subscriptions_status,
             check: "status IN ('active', 'revoked')"
           )
  end
end
