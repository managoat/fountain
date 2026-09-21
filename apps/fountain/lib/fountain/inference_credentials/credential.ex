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

  A set may also name one of its owner's ChatGPT subscriptions,
  `chatgpt_grant_id` (ADR 0060 decision 2). That is a reference and never a
  token: the grant lives in its own row with its own lifecycle
  (`Fountain.ChatGPTAccounts`), and the set only says which one serves a
  codex run. It sits beside `openai_api_key` rather than in place of it: the
  grant serves codex, the key serves every other OpenAI consumer.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @providers ~w(anthropic_api_key claude_code_oauth_token openai_api_key gemini_api_key)a

  @type t :: %__MODULE__{}
  schema "inference_credentials" do
    field :name, :string
    field :revision, Ecto.UUID, read_after_writes: true
    # Exactly one per account, enforced by a partial unique index. Writes go
    # through `InferenceCredentials.set_default/2`, which moves the flag in
    # one transaction.
    field :is_default, :boolean, default: false

    field :anthropic_api_key_ciphertext, :binary
    field :claude_code_oauth_token_ciphertext, :binary
    field :openai_api_key_ciphertext, :binary
    field :gemini_api_key_ciphertext, :binary

    # A grant of the same owner, which the composite foreign key holds in the
    # database. No association: core reads a grant only through
    # `Fountain.ChatGPTAccounts`, scoped by its owner. Written only by
    # `InferenceCredentials.set_grant/3`.
    field :chatgpt_grant_id, :binary_id

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

  @grant_message "is not a ChatGPT subscription this account can name"

  @doc """
  What a set is told when the grant it was asked to name is not one its
  owner may name. One message for another account's grant, a missing one and
  an id that is not one, so an id cannot be probed.
  """
  @spec grant_message() :: String.t()
  def grant_message, do: @grant_message

  @doc false
  # Apart from `changeset/2` on purpose: `:chatgpt_grant_id` is not in the
  # general cast list, so no caller that writes a credential or a name can
  # carry a grant along without the ownership check `set_grant/3` makes. The
  # constraint is the backstop for a grant that vanishes between that check
  # and the write; both hold the owner's source lock, so it should not fire.
  def grant_changeset(credential, grant_id) when is_binary(grant_id) or is_nil(grant_id) do
    credential
    |> change(chatgpt_grant_id: grant_id)
    |> foreign_key_constraint(:chatgpt_grant_id,
      name: :inference_credentials_chatgpt_grant_id_fkey,
      message: @grant_message
    )
  end
end
