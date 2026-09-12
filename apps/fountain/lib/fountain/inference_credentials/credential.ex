defmodule Fountain.InferenceCredentials.Credential do
  @moduledoc """
  One named set of a user's inference provider credentials (ADR 0053
  decision 1).

  An account holds one or more. Exactly one is `is_default`, and that is the
  one every surface reads unless something names another — which is what
  keeps an account that never opens the feature behaving as it did when this
  table held one row per user (ADR 0008).

  Each row holds up to four encrypted credentials, one per supported provider:

  - `anthropic_api_key` — for the `claude` runtime (when no OAuth token is set)
    and for `opencode` runs against an `anthropic/...` model.
  - `claude_code_oauth_token` — preferred for the `claude` runtime; bills
    against a Claude.ai Pro/Team subscription instead of metered API usage.
  - `openai_api_key` — for the `codex` runtime and `opencode` runs against an
    `openai/...` model.
  - `gemini_api_key` — for the `gemini` runtime and `opencode` runs against a
    `google/...` model.

  Each ciphertext is encrypted with the user's per-tenant DEK
  (see `Fountain.Crypto`). The schema does not store plaintext.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @providers ~w(anthropic_api_key claude_code_oauth_token openai_api_key gemini_api_key)a

  @type t :: %__MODULE__{}
  schema "inference_credentials" do
    field :name, :string
    # Exactly one per account, enforced by a partial unique index. Writes go
    # through `InferenceCredentials.set_default/3`, which moves the flag in
    # one transaction.
    field :is_default, :boolean, default: false

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

  @doc "The name every account's first set is given, and the only one until they make another."
  @spec default_name() :: String.t()
  def default_name, do: "Default"

  @doc false
  def changeset(credential, attrs) do
    credential
    |> cast(attrs, [
      :user_id,
      :name,
      :is_default,
      :anthropic_api_key_ciphertext,
      :claude_code_oauth_token_ciphertext,
      :openai_api_key_ciphertext,
      :gemini_api_key_ciphertext
    ])
    |> validate_required([:user_id, :name])
    |> validate_length(:name, min: 1, max: 200)
    # On `:name`, not on the index's leading `:user_id`: the tenant did not
    # choose their user id and a form cannot show them an error against it.
    |> unique_constraint(:name,
      name: :inference_credentials_user_id_name_index,
      message: "already names a credential set on this account"
    )
    |> unique_constraint(:is_default,
      name: :inference_credentials_one_default_index,
      message: "an account has exactly one default credential set"
    )
    |> foreign_key_constraint(:user_id)
  end
end
