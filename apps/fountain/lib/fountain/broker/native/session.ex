defmodule Fountain.Broker.Native.Session do
  @moduledoc """
  One native proxy session row: the hash of the token a sandbox dials the
  broker with, the conversation and tenant it belongs to, and the rules
  the proxy may apply, as ciphertext under the tenant's DEK. See
  `Fountain.Broker.Native.Sessions`.

  The `managed_*` columns are the session's authority to use one managed
  ChatGPT grant (ADR 0052 decision 5): which grant, at which generation,
  whose, and for which ChatGPT account. They are set once, at issuance, from
  a read of the grant row under its lock, and `changeset/2` is the only
  thing that casts them; `managed_revoked_at` is written afterwards by the
  grant's own lifecycle transaction and by nothing else. No bearer is ever
  stored here.
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
    field :managed_grant_id, :binary_id
    field :managed_grant_generation, :binary_id
    field :managed_grant_owner_id, :binary_id
    field :managed_identity, :string
    field :managed_revoked_at, :utc_datetime_usec

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
      :expires_at,
      :managed_grant_id,
      :managed_grant_generation,
      :managed_grant_owner_id,
      :managed_identity
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
    |> check_constraint(:managed_grant_id, name: :managed_grant_complete)
    |> check_constraint(:managed_grant_owner_id, name: :managed_grant_owner_is_session_owner)
  end
end
