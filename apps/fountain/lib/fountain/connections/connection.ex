defmodule Fountain.Connections.Connection do
  @moduledoc """
  One user's OAuth grant to one remote MCP server (ADR 0085), named by the
  server's resource URL. At most one per user and resource.

  `status`:

    * `pending`: created, consent not finished.
    * `active`: holds a token.
    * `revoked`: the provider refused a refresh for good (`revoked_reason`
      says which code).
    * `expired`: the access token lapsed and there is no refresh token to
      renew it.

  The endpoints and the client are what discovery and registration found
  (`Fountain.Connections.OAuth`). Every `*_ciphertext` field is written only
  by `Fountain.Connections`, under the user's DEK. `login_nonce` and
  `login_verifier_ciphertext` are set while a login is in progress and
  cleared when it completes. `refresh_lease_until` is set while a refresh is
  spending the refresh token, as on a ChatGPT subscription.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  @statuses ~w(pending active revoked expired)

  @registrations ~w(client_id_metadata_document dynamic pasted)

  @doc "The statuses a connection can be in."
  def statuses, do: @statuses

  @doc "How a connection's client was registered (`Fountain.Connections.OAuth.register/3`)."
  def registrations, do: @registrations

  schema "connections" do
    field :user_id, :binary_id
    field :url, :string
    field :resource, :string
    field :issuer, :string
    field :authorization_endpoint, :string
    field :token_endpoint, :string
    field :revocation_endpoint, :string
    field :iss_parameter_supported, :boolean, default: false
    field :scopes, {:array, :string}, default: []

    field :registration, :string
    field :client_id, :string
    field :client_secret_ciphertext, :binary, redact: true
    field :token_endpoint_auth_method, :string
    field :authorize_params, :map, default: %{}

    field :status, :string, default: "pending"
    field :revoked_reason, :string
    field :access_token_ciphertext, :binary, redact: true
    field :refresh_token_ciphertext, :binary, redact: true
    field :expires_at, :utc_datetime
    field :last_refreshed_at, :utc_datetime
    field :refresh_lease_until, :utc_datetime_usec

    field :login_nonce, :string, redact: true
    field :login_verifier_ciphertext, :binary, redact: true

    timestamps(type: :utc_datetime)
  end
end
