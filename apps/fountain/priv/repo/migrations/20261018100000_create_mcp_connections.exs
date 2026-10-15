defmodule Fountain.Repo.Migrations.CreateMcpConnections do
  use Ecto.Migration

  # A user's OAuth grant to one remote MCP server (ADR 0085). The table of
  # the same name ADR 0033 used was dropped on 2026-10-12
  # (20261012200000); this one shares only the name.
  #
  # Tokens, a pasted client secret and the PKCE verifier of a login in
  # progress are ciphertext under the user's DEK, with an AAD naming the
  # user, the row and the field (`Fountain.Connections`).
  def change do
    create table(:connections, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      add :url, :text, null: false
      add :resource, :text, null: false
      add :issuer, :text, null: false
      add :authorization_endpoint, :text, null: false
      add :token_endpoint, :text, null: false
      add :revocation_endpoint, :text
      add :iss_parameter_supported, :boolean, null: false, default: false
      add :scopes, {:array, :string}, null: false, default: []

      add :registration, :string, null: false
      add :client_id, :text, null: false
      add :client_secret_ciphertext, :binary
      add :token_endpoint_auth_method, :string, null: false
      add :authorize_params, :map, null: false, default: %{}

      add :status, :string, null: false, default: "pending"
      add :revoked_reason, :string
      add :access_token_ciphertext, :binary
      add :refresh_token_ciphertext, :binary
      add :expires_at, :utc_datetime
      add :last_refreshed_at, :utc_datetime
      add :refresh_lease_until, :utc_datetime_usec

      add :login_nonce, :string
      add :login_verifier_ciphertext, :binary

      timestamps(type: :utc_datetime)
    end

    create index(:connections, [:user_id])
    create unique_index(:connections, [:user_id, :resource])
  end
end
