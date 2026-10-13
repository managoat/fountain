defmodule Fountain.ChatGPT.Subscription do
  @moduledoc """
  A linked ChatGPT subscription (ADR 0070): one per user, and at most one for
  the deployment, whose row has no `user_id`.

  Both tokens are ciphertext, written only by `Fountain.ChatGPT`: a user's
  under their DEK with an AAD naming the row and the field, the deployment's
  under the master key. `account_id`, `chatgpt_user_id` and `plan_type` are
  the non-secret claims codex reads from an `id_token`; the sandbox gets them
  in a synthesised one, never the real token.

  `status` is `"active"` or `"revoked"`, the second when the auth server
  refused the refresh token for good (`revoked_reason` says which code).
  Disconnecting deletes the row.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  schema "chatgpt_subscriptions" do
    field :user_id, :binary_id
    field :account_id, :string
    field :chatgpt_user_id, :string
    field :plan_type, :string
    field :access_token_ciphertext, :binary, redact: true
    field :refresh_token_ciphertext, :binary, redact: true
    field :expires_at, :utc_datetime
    field :last_refreshed_at, :utc_datetime
    field :status, :string, default: "active"
    field :revoked_reason, :string

    timestamps(type: :utc_datetime)
  end
end
