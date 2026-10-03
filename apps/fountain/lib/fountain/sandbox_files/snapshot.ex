defmodule Fountain.SandboxFiles.Snapshot do
  @moduledoc """
  One sandbox's disk as it was when it was last parked (ADR 0063).

  Both payloads are compressed terms under the owner's DEK; nothing a file
  holds is stored in the clear. `manifest_ciphertext` is all a listing, a
  diff or a status needs, and `contents_ciphertext` is only decrypted for a
  file read. See `Fountain.SandboxFiles.Snapshots`.
  """
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  schema "sandbox_snapshots" do
    belongs_to :sandbox, Fountain.Conversations.Sandbox
    belongs_to :user, Fountain.Accounts.User
    field :taken_at, :utc_datetime_usec
    field :manifest_ciphertext, :binary, redact: true
    field :contents_ciphertext, :binary, redact: true
    field :file_count, :integer
    field :content_bytes, :integer

    timestamps(type: :utc_datetime_usec)
  end
end
