defmodule Fountain.Repo.Migrations.AddChatgptSubscriptionRefreshLease do
  use Ecto.Migration

  # A refresh leases the row while it exchanges the refresh token with
  # auth.openai.com, instead of holding an advisory lock inside a
  # transaction across the HTTP call (#2661, ADR 0070 addendum 2026-10-15).
  # NULL or a past time means no refresh holds it.
  def change do
    alter table(:chatgpt_subscriptions) do
      add :refresh_lease_until, :utc_datetime_usec
    end
  end
end
