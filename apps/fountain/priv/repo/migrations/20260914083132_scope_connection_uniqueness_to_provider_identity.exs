defmodule Fountain.Repo.Migrations.ScopeConnectionUniquenessToProviderIdentity do
  use Ecto.Migration

  def change do
    # Match Connections.existing_connection/4: an installed platform provider
    # and a tenant provider can share a slug without sharing an account.
    create unique_index(:connections, [:user_id, :provider, :account_email],
             name: :connections_platform_account_index,
             where: "provider_id IS NULL"
           )

    create unique_index(:connections, [:user_id, :provider_id, :account_email],
             name: :connections_tenant_provider_account_index,
             where: "provider_id IS NOT NULL"
           )

    # Build both replacements before releasing the old constraint. On rollback,
    # restoring it first refuses any now-ambiguous rows without deleting them.
    drop unique_index(:connections, [:user_id, :provider, :account_email])
  end
end
