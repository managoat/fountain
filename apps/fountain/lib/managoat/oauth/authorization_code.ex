defmodule Managoat.OAuth.AuthorizationCode do
  @moduledoc """
  A one-time authorization code (OAuth 2.0 authorization code grant with
  PKCE). Stored hashed; bound to the subject who consented, the client and
  redirect URI it was issued for, and the PKCE challenge the token exchange
  must answer. Five minutes to live, single use (`used_at`).

  `subject_id` is the user who consented, stored in the `user_id` column
  (which references `users` and cascades on delete).
  """
  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "oauth_authorization_codes" do
    field :code_hash, :string
    field :subject_id, :binary_id, source: :user_id
    field :client_id, :string
    field :redirect_uri, :string
    field :code_challenge, :string
    field :expires_at, :utc_datetime
    field :used_at, :utc_datetime
    timestamps(type: :utc_datetime)
  end

  @doc false
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(code, attrs) do
    code
    |> cast(attrs, [
      :code_hash,
      :subject_id,
      :client_id,
      :redirect_uri,
      :code_challenge,
      :expires_at
    ])
    |> validate_required([
      :code_hash,
      :subject_id,
      :client_id,
      :redirect_uri,
      :code_challenge,
      :expires_at
    ])
    |> unique_constraint(:code_hash)
  end
end
