defmodule Fountain.Environments.Secret do
  use Ecto.Schema
  import Ecto.Changeset

  alias Fountain.Crypto
  alias Fountain.Environments.Environment

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "secrets" do
    field :key, :string
    field :value_ciphertext, :binary
    field :value, :string, virtual: true, redact: true
    belongs_to :environment, Environment
    timestamps(type: :utc_datetime)
  end

  @doc """
  Build a changeset that encrypts `attrs["value"]` with the supplied
  per-tenant `dek` before persisting. The plaintext is never stored.
  """
  def changeset(secret, attrs, dek) when is_binary(dek) do
    secret
    |> cast(attrs, [:key, :value, :environment_id])
    |> validate_required([:key, :value, :environment_id])
    |> validate_format(:key, ~r/^[A-Z][A-Z0-9_]*$/, message: "must be UPPER_SNAKE_CASE")
    |> validate_length(:key, min: 1, max: 200)
    |> Fountain.ChatGPTAccounts.Reserved.validate_changeset([:key, :value])
    |> put_ciphertext(dek)
    |> unique_constraint([:environment_id, :key])
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
