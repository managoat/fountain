defmodule Fountain.EnvironmentLayers.Build do
  @moduledoc "Durable ownership and publication state for one disposable environment build."
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "environment_layer_builds" do
    belongs_to :user, Fountain.Accounts.User
    belongs_to :environment, Fountain.Environments.Environment
    belongs_to :sandbox, Fountain.Conversations.Sandbox
    field :owner_ref, Ecto.UUID
    field :environment_ref, Ecto.UUID
    field :policy_revision, Ecto.UUID
    field :generation, Ecto.UUID
    field :store_ref, :string
    field :fingerprint, :string
    field :binding, :map
    field :revisions, {:array, :string}
    field :state, :string, default: "queued"
    field :claim, Ecto.UUID, redact: true
    field :deadline_at, :utc_datetime
    field :expires_at, :utc_datetime
    field :cleanup_after, :utc_datetime
    field :cleanup_pending, :boolean, default: true
    field :ciphertext_sha256, :string
    field :ciphertext_bytes, :integer
    field :wrapped_identity, :binary, redact: true
    timestamps(type: :utc_datetime)
  end
end
