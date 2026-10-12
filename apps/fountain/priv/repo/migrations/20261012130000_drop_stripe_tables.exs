defmodule Fountain.Repo.Migrations.DropStripeTables do
  use Ecto.Migration

  @moduledoc """
  Credits and Stripe are removed (ADR 0010, 0030 and 0031, Retired addenda).

  Drops `stripe_events`, `stripe_webhook_failures` and `provider_invoices`,
  and deletes the Oban jobs of the `credits` queue, whose workers
  (`CreditPricer`, `CreditExpirer`, `CreditsEmail`) no longer exist. The
  replicas still serving the previous release during a rolling deploy read
  these three tables only from the Stripe webhook and the admin finance and
  overview pages, never on a tenant's request.

  Not dropped here, for the reason `20261012120000` keeps `users.principal`:
  `credit_ledger`, which the previous release reads on a tenant's turn and
  dashboard, and `users.credit_balance_cents`, `users.stripe_customer_id` and
  `users.comped`, which it selects with every `Fountain.Accounts.User`.
  Nothing in this release reads them; a later migration drops them.
  """

  def up do
    execute "DELETE FROM oban_jobs WHERE queue = 'credits'"

    drop table(:stripe_webhook_failures)
    drop table(:stripe_events)
    drop table(:provider_invoices)
  end

  # Restores the shape, not the rows.
  def down do
    create table(:provider_invoices, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :provider, :string, null: false
      add :period_start, :date, null: false
      add :period_end, :date, null: false
      add :amount_cents, :integer, null: false
      add :note, :string
      timestamps(type: :utc_datetime)
    end

    create unique_index(:provider_invoices, [:provider, :period_start])

    create table(:stripe_events, primary_key: false) do
      add :id, :string, primary_key: true
      add :type, :string, null: false
      add :inserted_at, :utc_datetime, null: false
    end

    create table(:stripe_webhook_failures, primary_key: false) do
      add :event_id, :string, primary_key: true
      add :event_type, :string, null: false
      add :error, :text, null: false
      add :failure_count, :integer, null: false, default: 1
      add :first_failed_at, :utc_datetime, null: false
      add :last_failed_at, :utc_datetime, null: false
      add :resolved_at, :utc_datetime
    end

    create index(:stripe_webhook_failures, [:last_failed_at])
  end
end
