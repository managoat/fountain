defmodule Fountain.Accounts.ApiKey do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @moduledoc """
  A tenant API key.

  ## Scopes

    * `"full"`   — everything, including issuing and revoking API keys. What a
      human gets from the UI or `fountain keys create`.
    * `"sprite"` — the per-conversation token handed to a sandbox. Deliberately
      permits the normal resource surface, because spawning sub-agents from
      inside a sprite is a supported workflow, but **not** API key management:
      without that exclusion, code running in a sandbox can mint a permanent
      key that survives the conversation-scoped revoke at teardown, turning a
      one-conversation credential into standing tenant access.
  """

  @scopes ~w(full sprite)

  # Scopes permitted to issue, list, or revoke API keys.
  @key_management_scopes ~w(full)

  @type t :: %__MODULE__{}
  schema "api_keys" do
    field :name, :string
    field :key_hash, :string
    field :key_prefix, :string
    field :last_used_at, :utc_datetime
    field :revoked_at, :utc_datetime
    field :expires_at, :utc_datetime
    field :scopes, {:array, :string}, default: ["full"]

    belongs_to :user, Fountain.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def scopes, do: @scopes

  @doc "Whether `key` may issue, list, or revoke API keys."
  def may_manage_keys?(%__MODULE__{scopes: scopes}) do
    Enum.any?(scopes, &(&1 in @key_management_scopes))
  end

  @doc "Whether `key` is past its expiry. Keys without one never expire."
  def expired?(%__MODULE__{expires_at: nil}), do: false

  def expired?(%__MODULE__{expires_at: at}) do
    DateTime.compare(DateTime.utc_now(), at) == :gt
  end

  @doc """
  Changeset for creating a new API key record.
  Expects :name, :key_hash, :key_prefix, :user_id to be provided.
  The raw key is never stored — callers must compute key_hash and key_prefix before
  calling this changeset.
  """
  def changeset(api_key, attrs) do
    api_key
    |> cast(attrs, [:name, :key_hash, :key_prefix, :user_id, :scopes, :expires_at])
    |> validate_required([:name, :key_hash, :key_prefix, :user_id, :scopes])
    |> validate_length(:name, min: 1, max: 200)
    |> validate_length(:scopes, min: 1)
    |> validate_subset(:scopes, @scopes)
    |> unique_constraint(:key_hash)
    |> foreign_key_constraint(:user_id)
  end
end
