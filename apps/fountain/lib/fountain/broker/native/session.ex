defmodule Fountain.Broker.Native.Session do
  @moduledoc """
  One native proxy session row: the hash of the token a sandbox dials the
  broker with, the conversation and tenant it belongs to, and the rules
  the proxy may apply, as ciphertext under the tenant's DEK. See
  `Fountain.Broker.Native.Sessions`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "broker_sessions" do
    field :token_hash, :binary
    field :conversation_id, :binary_id
    field :user_id, :binary_id
    field :rules_ciphertext, :binary
    field :unmatched_host_policy, :string, default: "passthrough"
    field :meta, :map, default: %{}
    field :expires_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(session, attrs) do
    session
    |> cast(attrs, [
      :token_hash,
      :conversation_id,
      :user_id,
      :rules_ciphertext,
      :unmatched_host_policy,
      :meta,
      :expires_at
    ])
    |> validate_required([
      :token_hash,
      :conversation_id,
      :user_id,
      :rules_ciphertext,
      :expires_at
    ])
    |> validate_inclusion(:unmatched_host_policy, ["passthrough", "deny"])
    |> unique_constraint(:token_hash)
  end
end
