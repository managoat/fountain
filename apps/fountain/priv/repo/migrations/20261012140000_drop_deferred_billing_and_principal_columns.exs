defmodule Fountain.Repo.Migrations.DropDeferredBillingAndPrincipalColumns do
  use Ecto.Migration

  @moduledoc """
  The contract step for `20261012120000` (claimable principals) and
  `20261012130000` (credits and Stripe).

  Those releases stopped reading `credit_ledger` and the `users` columns
  `credit_balance_cents`, `stripe_customer_id`, `comped` and `principal`, but
  left them in place: a rolling deploy runs a migration while replicas of the
  previous release are still serving, and those read `credit_ledger` on a
  tenant's turn and select every `users` column on each request. Take this
  only after the release that removed credits is fully rolled out; the
  release before this one reads none of them.
  """

  def up do
    drop table(:credit_ledger)

    drop_if_exists index(:users, [:principal], name: :users_principal_index)
    drop_if_exists index(:users, [:stripe_customer_id])

    alter table(:users) do
      remove :credit_balance_cents
      remove :stripe_customer_id
      remove :comped
      remove :principal
    end
  end

  # Restores the shape, not the rows.
  def down do
    alter table(:users) do
      add :credit_balance_cents, :integer, null: false, default: 0
      add :stripe_customer_id, :string
      add :comped, :boolean, null: false, default: false
      add :principal, :boolean, null: false, default: false
    end

    create unique_index(:users, [:stripe_customer_id])
    create index(:users, [:principal], where: "principal = true", name: :users_principal_index)

    create table(:credit_ledger, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :amount_cents, :integer, null: false
      add :reason, :string, null: false
      add :resource_type, :string
      add :resource_id, :string
      add :idempotency_key, :string, null: false
      add :expires_at, :utc_datetime
      add :metadata, :map, null: false, default: %{}
      add :inserted_at, :utc_datetime, null: false
      add :remaining_cents, :integer
      add :seq, :bigserial
    end

    create unique_index(:credit_ledger, [:idempotency_key])
    create index(:credit_ledger, [:user_id, :inserted_at])
    create index(:credit_ledger, [:expires_at], where: "expires_at IS NOT NULL")

    create index(:credit_ledger, [:inserted_at],
             where: "reason = 'burn_inference'",
             name: :credit_ledger_inference_inserted_at_index
           )

    create index(:credit_ledger, [:user_id, :expires_at, :seq],
             where: "remaining_cents > 0",
             name: :credit_ledger_open_lots_index
           )
  end
end
