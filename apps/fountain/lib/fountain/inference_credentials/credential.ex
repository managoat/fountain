defmodule Fountain.InferenceCredentials.Credential do
  @moduledoc """
  A user's inference provider credentials: one record per user (ADR 0008).

  The record holds up to four encrypted credentials, one per supported
  provider:

  - `anthropic_api_key` — for the `claude` runtime (when no OAuth token is set).
  - `claude_code_oauth_token` — preferred for the `claude` runtime; bills
    against a Claude.ai Pro/Team subscription instead of metered API usage.
  - `openai_api_key` — for the `codex` runtime.
  - `gemini_api_key` — for the `gemini` runtime.

  Each ciphertext is encrypted with the user's per-tenant DEK
  (see `Fountain.Crypto`). The schema does not store plaintext.

  `revision` moves (by trigger) whenever a ciphertext changes, so a
  conversation bound to the record notices a replaced key.

  The table still has the `name` and `is_default` columns of the retired
  named sets (ADR 0053's 2026-10-14 addendum). They are unmapped and filled
  by column defaults; a later migration drops them.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @providers ~w(anthropic_api_key claude_code_oauth_token openai_api_key gemini_api_key)a

  @type t :: %__MODULE__{}
  schema "inference_credentials" do
    field :revision, Ecto.UUID, read_after_writes: true

    field :anthropic_api_key_ciphertext, :binary
    field :claude_code_oauth_token_ciphertext, :binary
    field :openai_api_key_ciphertext, :binary
    field :gemini_api_key_ciphertext, :binary

    belongs_to :user, Fountain.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @doc "List of supported provider keys (atoms)."
  @spec providers() :: [atom()]
  def providers, do: @providers

  @doc false
  def changeset(credential, attrs) do
    credential
    |> cast(attrs, [
      :user_id,
      :anthropic_api_key_ciphertext,
      :claude_code_oauth_token_ciphertext,
      :openai_api_key_ciphertext,
      :gemini_api_key_ciphertext
    ])
    |> validate_required([:user_id])
    # Every row the column defaults write is named "Default" and is
    # `is_default`, so the set-era unique indexes are what refuse a second
    # record for one user until the follow-up migration restores the unique
    # key on `user_id` (whose name is the third).
    |> unique_constraint(:user_id, name: :inference_credentials_one_default_index)
    |> unique_constraint(:user_id, name: :inference_credentials_user_id_name_index)
    |> unique_constraint(:user_id, name: :inference_credentials_user_id_index)
    |> foreign_key_constraint(:user_id)
  end
end
