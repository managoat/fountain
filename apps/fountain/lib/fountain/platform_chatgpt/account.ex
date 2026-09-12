defmodule Fountain.PlatformChatGPT.Account do
  @moduledoc """
  A ChatGPT grant in the historical platform account table (ADRs 0047/0052).
  The null-owner row uses platform encryption; owned rows use their owner's
  DEK through `Fountain.ChatGPTAccounts.Cipher`. Ownership is not cast by
  lifecycle changesets and cannot be changed through this interface.
  `id_claims` holds the non-secret claims codex reads from its `id_token`.

  `kind` says what the row holds: `"chatgpt"` is a ChatGPT sign-in with a
  rotating refresh token managed server-side by `Fountain.ChatGPTAccounts`;
  `"workspace_token"` is a static Business/Enterprise access token with no
  refresh token, which lapses on its admin-set expiry.

  Reconnect changes `generation`. Normal refresh retains the generation and
  increments `lock_version`, as do terminal lifecycle writes. These fields
  fence stale writes; broker authorization is not yet generation-aware.

  `connect_changeset/2` is the only changeset here, because it is the only
  write that starts a new lifecycle. Refresh, revocation and expiry are
  fenced `update_all` statements in `Fountain.ChatGPTAccounts`, conditioned
  on the generation and version the caller read. A changeset for one of them
  would write on the primary key alone and so would skip the fence, which is
  why the three that used to exist were removed rather than left unused.

  There is no plaintext column. User linking is not yet built; the current
  application writers are the admin surface and the owner-scoped refreshers.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @kinds ~w(chatgpt workspace_token)
  @statuses ~w(active revoked expired)

  @type t :: %__MODULE__{}
  schema "platform_chatgpt_account" do
    field :user_id, :binary_id
    field :generation, Ecto.UUID, autogenerate: true
    field :lock_version, :integer, default: 1
    field :kind, :string
    field :refresh_token_ciphertext, :binary
    field :access_token_ciphertext, :binary
    field :id_claims, :map, default: %{}
    field :account_id, :string
    field :account_email, :string
    field :plan_type, :string
    field :access_expires_at, :utc_datetime
    field :last_refreshed_at, :utc_datetime
    field :status, :string, default: "active"
    field :revoked_reason, :string

    belongs_to :updated_by, Fountain.Accounts.User, foreign_key: :updated_by_user_id

    timestamps(type: :utc_datetime)
  end

  def kinds, do: @kinds
  def statuses, do: @statuses

  @doc "A fresh grant, or a reconnect over an existing row."
  def connect_changeset(account, attrs) do
    account
    |> cast(attrs, [
      :kind,
      :refresh_token_ciphertext,
      :access_token_ciphertext,
      :id_claims,
      :account_id,
      :account_email,
      :plan_type,
      :access_expires_at,
      :last_refreshed_at,
      :updated_by_user_id
    ])
    |> put_change(:status, "active")
    |> put_change(:revoked_reason, nil)
    |> put_change(:generation, Ecto.UUID.generate())
    |> version_existing()
    |> validate_required([:kind, :access_token_ciphertext, :last_refreshed_at])
    |> validate_inclusion(:kind, @kinds)
    |> unique_constraint(:user_id, name: :platform_chatgpt_account_platform_row)
  end

  defp version_existing(%{data: %{__meta__: %{state: :loaded}}} = changeset),
    do: optimistic_lock(changeset, :lock_version)

  defp version_existing(changeset), do: changeset
end
