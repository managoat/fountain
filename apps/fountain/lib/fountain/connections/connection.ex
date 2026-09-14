defmodule Fountain.Connections.Connection do
  @moduledoc """
  A provider account a tenant signed in to once, whose credential Fountain
  holds (#1178). The refresh token is encrypted with the tenant's DEK the way
  a vault secret is; the access token is a short-lived cache of the same
  shape, rewritten on every refresh. Neither ever enters a sandbox.

  `provider` is the provider's slug: `google` for the platform provider,
  which has no row and leaves `provider_id` null, or a tenant provider's
  slug with `provider_id` set (#1186). `account_email` is the account
  label: an address where the provider says one, otherwise whatever the
  userinfo path found or the tenant typed.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Fountain.Crypto

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(active revoked expired)

  @type t :: %__MODULE__{}

  schema "connections" do
    field :provider, :string
    field :account_email, :string
    field :scopes, {:array, :string}, default: []
    field :env_key, :string
    field :refresh_token_ciphertext, :binary, redact: true
    field :access_token_ciphertext, :binary, redact: true
    field :refresh_token, :string, virtual: true, redact: true
    field :access_token, :string, virtual: true, redact: true
    field :expires_at, :utc_datetime
    field :status, :string, default: "active"
    field :revoked_at, :utc_datetime
    field :last_refreshed_at, :utc_datetime
    belongs_to :user, Fountain.Accounts.User
    belongs_to :provider_record, Fountain.Connections.Provider, foreign_key: :provider_id
    timestamps(type: :utc_datetime)
  end

  def statuses, do: @statuses

  @doc """
  Create or replace a connection from a fresh token grant. `attrs` carries
  the plaintext `refresh_token` / `access_token`; both are encrypted with the
  tenant `dek` before they are persisted. A grant with no refresh token is
  legitimate (some providers issue none): the connection is good until the
  access token expires, and `expired` after.
  """
  def changeset(conn, attrs, dek) when is_binary(dek) do
    conn
    |> cast(attrs, [
      :user_id,
      :provider,
      :provider_id,
      :account_email,
      :scopes,
      :env_key,
      :refresh_token,
      :access_token,
      :expires_at
    ])
    |> validate_required([:user_id, :provider, :account_email, :env_key, :access_token])
    |> validate_format(:env_key, ~r/^[A-Z][A-Z0-9_]*$/, message: "must be UPPER_SNAKE_CASE")
    |> validate_length(:account_email, min: 1, max: 320)
    |> put_change(:status, "active")
    |> put_change(:revoked_at, nil)
    |> encrypt(:refresh_token, :refresh_token_ciphertext, dek)
    |> encrypt(:access_token, :access_token_ciphertext, dek)
    |> unique_constraint([:user_id, :provider, :account_email],
      name: :connections_platform_account_index
    )
    |> unique_constraint([:user_id, :provider_id, :account_email],
      name: :connections_tenant_provider_account_index
    )
    |> unique_constraint([:user_id, :env_key])
  end

  @doc """
  A refreshed access token, encrypted with the tenant `dek`. A provider that
  rotates refresh tokens sends the new one in the same response, and it
  replaces the stored one here; `nil` keeps the old.
  """
  def refresh_changeset(conn, %{access_token: access} = fresh, dek) when is_binary(dek) do
    conn
    |> change(access_token: access, expires_at: fresh[:expires_at])
    |> put_change(:last_refreshed_at, now())
    |> maybe_rotate(fresh[:refresh_token])
    |> encrypt(:access_token, :access_token_ciphertext, dek)
    |> encrypt(:refresh_token, :refresh_token_ciphertext, dek)
  end

  defp maybe_rotate(changeset, refresh) when is_binary(refresh) and refresh != "",
    do: change(changeset, refresh_token: refresh)

  defp maybe_rotate(changeset, _), do: changeset

  @doc "The connection no longer works: the provider refused the refresh token, or the tenant revoked it."
  def revoke_changeset(conn) do
    conn
    |> change(status: "revoked", revoked_at: now())
    |> validate_inclusion(:status, @statuses)
  end

  @doc "The access token lapsed and there is no refresh token to renew it: the tenant must reconnect."
  def expire_changeset(conn) do
    conn
    |> change(status: "expired")
    |> validate_inclusion(:status, @statuses)
  end

  defp encrypt(changeset, field, target, dek) do
    case get_change(changeset, field) do
      nil -> changeset
      value -> put_change(changeset, target, Crypto.encrypt(value, dek))
    end
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
