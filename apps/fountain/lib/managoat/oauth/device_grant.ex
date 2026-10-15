defmodule Managoat.OAuth.DeviceGrant do
  @moduledoc """
  A device-authorization grant (RFC 8628 shape).

  Two codes, two audiences: the high-entropy `device_code` (stored hashed)
  stays on the machine that started the flow and is what the poller asks
  with; the short `user_code` is what a human types into the host's approval
  page. `subject_id` is null until a signed-in user approves or denies, and
  is stored in the `user_id` column. Single use (`used_at`), fifteen minutes
  to live. `client_name` is what the starting client called itself: unverified,
  shown on the approval page as a claim, and the name of the minted key.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "oauth_device_grants" do
    field :device_code_hash, :string
    field :user_code, :string
    field :client_name, :string
    field :subject_id, :binary_id, source: :user_id
    field :approved_at, :utc_datetime
    field :denied_at, :utc_datetime
    field :used_at, :utc_datetime
    field :last_polled_at, :utc_datetime
    field :expires_at, :utc_datetime
    timestamps(type: :utc_datetime)
  end

  @doc false
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(grant, attrs) do
    grant
    |> cast(attrs, [:device_code_hash, :user_code, :client_name, :expires_at])
    |> validate_required([:device_code_hash, :user_code, :expires_at])
    |> validate_length(:client_name, max: 64, count: :codepoints)
    |> unique_constraint(:device_code_hash)
    |> unique_constraint(:user_code)
  end
end
