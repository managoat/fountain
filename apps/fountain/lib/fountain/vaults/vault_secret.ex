defmodule Fountain.Vaults.VaultSecret do
  use Ecto.Schema
  import Ecto.Changeset

  alias Fountain.Crypto
  alias Fountain.Vaults.Vault

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "vault_secrets" do
    field :key, :string
    field :value_ciphertext, :binary
    field :value, :string, virtual: true, redact: true
    field :expires_at, :utc_datetime
    field :expiry_notified_at, :utc_datetime
    belongs_to :vault, Vault
    timestamps(type: :utc_datetime)
  end

  @doc """
  Build a changeset that encrypts `attrs["value"]` with the supplied
  per-tenant `dek` before persisting. The plaintext is never stored.
  """
  def changeset(secret, attrs, dek) when is_binary(dek) do
    secret
    |> cast(attrs, [:key, :value, :vault_id, :expires_at])
    |> validate_required([:key, :value, :vault_id])
    |> validate_format(:key, ~r/^[A-Z][A-Z0-9_]*$/, message: "must be UPPER_SNAKE_CASE")
    |> validate_length(:key, min: 1, max: 200)
    |> Fountain.ChatGPTAccounts.Reserved.validate_changeset([:key, :value])
    |> put_ciphertext(dek)
    |> reset_expiry_notice()
    |> unique_constraint([:vault_id, :key])
  end

  @doc "Change advisory expiry without reading or replacing the encrypted value."
  def metadata_changeset(secret, attrs) do
    secret
    |> cast(attrs, [:expires_at])
    |> reset_expiry_notice()
  end

  # A rotated or extended expiry is a new expiry: the advance-notice email
  # must fire again for it, so the sweeper's already-notified stamp is cleared
  # whenever expires_at moves (including to nil).
  defp reset_expiry_notice(changeset) do
    case fetch_change(changeset, :expires_at) do
      {:ok, _} -> put_change(changeset, :expiry_notified_at, nil)
      :error -> changeset
    end
  end

  defp put_ciphertext(changeset, dek) do
    case get_change(changeset, :value) do
      nil -> changeset
      value -> put_change(changeset, :value_ciphertext, Crypto.encrypt(value, dek))
    end
  end

  @doc """
  Decrypt the value with the supplied per-tenant `dek`.
  Returns `{:ok, plaintext}` or `:error`.
  """
  def decrypt(%__MODULE__{value_ciphertext: ct}, dek) when is_binary(ct) and is_binary(dek),
    do: Crypto.decrypt(ct, dek)

  def decrypt(_, _), do: :error
end
