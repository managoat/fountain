defmodule Fountain.Repo.Migrations.DropClaimablePrincipals do
  use Ecto.Migration

  @moduledoc """
  Claimable principals are retired (ADR 0044, Retired addendum).

  Drops `claimable_users`, `principal_owners`, the `principal` API-key expiry
  CHECK and the sweep's leftover Oban jobs, and deletes any principal `users`
  rows, which nothing can reach any more: they have no email, no password, and
  the `principal`-scoped keys that operated them stop authenticating with this
  release. Their rows cascade with them.

  `users.principal` itself stays one release, as the subscription columns did
  (`20260825060000`): a rolling deploy runs this before the replicas still
  serving the previous release are gone, and those select every field of
  `Fountain.Accounts.User` on each request. Nothing in this release reads it;
  a later migration drops it.

  A principal's live sandboxes are not torn down here — a migration cannot call
  a provider. Release or let expire every principal before taking this release;
  `SELECT count(*) FROM users WHERE principal` should be 0.
  """

  def up do
    execute "DELETE FROM oban_jobs WHERE worker = 'Fountain.Workers.ClaimablePrincipalSweep'"

    drop table(:principal_owners)
    drop table(:claimable_users)

    execute "DELETE FROM users WHERE principal = true"

    execute "ALTER TABLE api_keys DROP CONSTRAINT IF EXISTS api_keys_active_principal_expiry_required"

    # Only a principal ever lacked an email (`20260904090000`).
    alter table(:users) do
      modify :email, :string, null: false, from: {:string, null: true}
    end
  end

  # Restores the shape, not the rows: the principals deleted above are gone.
  def down do
    alter table(:users) do
      modify :email, :string, null: true, from: {:string, null: false}
    end

    execute """
    ALTER TABLE api_keys
    ADD CONSTRAINT api_keys_active_principal_expiry_required
    CHECK (revoked_at IS NOT NULL OR NOT ('principal' = ANY(scopes)) OR expires_at IS NOT NULL)
    """

    create table(:claimable_users, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :application_user_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :application_id, :string, null: false
      add :status, :string, null: false, default: "unclaimed"
      add :claim_token_hash, :string
      add :expires_at, :utc_datetime, null: false
      add :claimed_at, :utc_datetime
      add :claimed_by_user_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :expired_at, :utc_datetime
      add :released_at, :utc_datetime
      add :budget_exhausted_at, :utc_datetime
      add :grant_cents, :integer, null: false, default: 0
      add :max_live_sandboxes, :integer
      add :create_idempotency_key, :string
      add :claim_idempotency_key, :string
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime)
    end

    create unique_index(:claimable_users, [:user_id])

    create unique_index(:claimable_users, [:application_user_id, :create_idempotency_key],
             where: "create_idempotency_key IS NOT NULL",
             name: :claimable_users_application_idempotency_index
           )

    create index(:claimable_users, [:status, :expires_at])
    create index(:claimable_users, [:application_user_id])
    create index(:claimable_users, [:claimed_by_user_id])

    create table(:principal_owners, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :owner_user_id, references(:users, type: :binary_id, on_delete: :delete_all),
        null: false

      add :principal_user_id, references(:users, type: :binary_id, on_delete: :delete_all),
        null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:principal_owners, [:principal_user_id])
    create index(:principal_owners, [:owner_user_id])
  end
end
