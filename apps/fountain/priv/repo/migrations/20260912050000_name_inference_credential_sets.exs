defmodule Fountain.Repo.Migrations.NameInferenceCredentialSets do
  @moduledoc """
  One `inference_credentials` row per user becomes one row per named set
  (ADR 0053 decision 1).

  Every existing row is backfilled as that account's default set, so an
  account that never opens the feature behaves exactly as it does today: the
  context reads the default set wherever it used to read "the row".
  """

  use Ecto.Migration

  def up do
    alter table(:inference_credentials) do
      add :name, :string
      add :is_default, :boolean, null: false, default: false
    end

    # Before the NOT NULL below, and before the partial index: the rows that
    # exist are each their account's only credentials, which is what a default
    # set is.
    execute("UPDATE inference_credentials SET name = 'Default', is_default = TRUE")

    alter table(:inference_credentials) do
      modify :name, :string, null: false
    end

    drop unique_index(:inference_credentials, [:user_id])
    create unique_index(:inference_credentials, [:user_id, :name])

    # One default per account, enforced by the database rather than by a
    # context that has to remember. `Fountain.InferenceCredentials.set_default/3`
    # clears the old flag and sets the new one in one transaction, so the
    # window this index would reject never opens in normal operation.
    create unique_index(:inference_credentials, [:user_id],
             where: "is_default",
             name: :inference_credentials_one_default_index
           )
  end

  def down do
    drop unique_index(:inference_credentials, [:user_id],
           name: :inference_credentials_one_default_index
         )

    drop unique_index(:inference_credentials, [:user_id, :name])

    # An account may hold several sets by now; the unique index on user_id
    # cannot come back while it does. Keep the default and drop the rest,
    # which is the only reading of "one row per user" that preserves the
    # credential the account was actually running on.
    execute("DELETE FROM inference_credentials WHERE is_default = FALSE")

    alter table(:inference_credentials) do
      remove :name
      remove :is_default
    end

    create unique_index(:inference_credentials, [:user_id])
  end
end
