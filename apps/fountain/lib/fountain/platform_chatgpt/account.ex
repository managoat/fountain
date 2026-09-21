defmodule Fountain.PlatformChatGPT.Account do
  @moduledoc """
  A ChatGPT grant: the deployment's (ADR 0047), or one of a user's (ADR
  0060). The null-owner row uses platform encryption; an owned row uses its
  owner's DEK through `Fountain.ChatGPTAccounts.Cipher`. Ownership is not
  cast by any changeset here and cannot be changed through this interface.
  `id_claims` holds the non-secret claims codex reads from its `id_token`.

  The table keeps its historical name (ADR 0052 decision 1). It holds at
  most one null-owner row (`platform_chatgpt_account_platform_row`) and any
  number of owned rows per user. An owned row has a `name`, unique per owner
  (`platform_chatgpt_account_user_id_name_index`), and its upstream
  `account_id` is unique per owner too
  (`platform_chatgpt_account_user_id_account_id_index`): one subscription
  linked twice would be two refresh chains OpenAI cannot tell apart.
  `platform_chatgpt_account_id_user_id_index` is there for ADR 0060 stage
  2's reference from a credential set to a grant together with its owner;
  that reference is not built and nothing uses the index yet. The platform
  row's name is NULL, and `chatgpt_grant_name_follows_owner` holds both
  halves of that in the database.

  `kind` says what the row holds: `"chatgpt"` is a ChatGPT sign-in with a
  rotating refresh token managed server-side by `Fountain.ChatGPTAccounts`;
  `"workspace_token"` is a static Business/Enterprise access token with no
  refresh token, which lapses on its admin-set expiry. An owned row is
  always `"chatgpt"`.

  `status` is `"active"`, `"revoked"` (the auth server refused the refresh
  token), `"expired"` (a workspace token lapsed) or, for an owned row only,
  `"disconnected"`: the user disconnected it and the row is a tombstone. A
  tombstone holds no token (`chatgpt_grant_tokens_follow_status` says so in
  the database) and keeps its id, name and upstream `account_id`, so
  whatever named the grant still names it and can say which subscription is
  gone, and the same account comes back by reconnecting this row rather than
  by a second link. It is deleted only by an explicit removal. The platform
  grant has no tombstone: disconnecting it deletes the row.

  Reconnect and disconnect change `generation`. Normal refresh retains the
  generation and increments `lock_version`, as do terminal lifecycle writes.
  These fields fence stale writes, and `generation` fences the broker too:
  a broker session that may use a grant is pinned to one generation, and
  every request is admitted against the row's current one
  (`Fountain.ChatGPTAccounts.protected_credential/2`).

  `connect_changeset/2` starts a lifecycle: a fresh grant, or a reconnect
  over an existing row. `user_connect_changeset/2` and
  `user_reconnect_changeset/2` are the same write for an owned row, with the
  rules only an owned row has; the first also takes the name, the second
  keeps it. `disconnect_changeset/1` ends one: it drops both tokens and the
  stored claims, advances `generation` and `lock_version` so an in-flight
  refresh's fenced write finds nothing, and keeps the name and the account.
  `rename_changeset/2` changes the name and nothing else: not `generation`,
  because a label is not a credential change, and not `lock_version`,
  because an in-flight refresh is fenced on it and losing that fence would
  discard a refresh token OpenAI has already rotated. Refresh, revocation
  and expiry are fenced `update_all` statements in
  `Fountain.ChatGPTAccounts`, conditioned on the generation and version the
  caller read. There is no changeset for any of them: one would write on the
  primary key alone and so would skip the fence.

  `usage_exhausted_at` and `usage_exhausted_until` record that OpenAI
  confirmed the account ran out of Codex usage, and the reset time it gave
  (#2362). `usage_checked_at` is when the server last asked, which throttles
  the asking. All three are written by
  `Fountain.ChatGPTAccounts.platform_confirm_exhausted/2` with fenced
  `update_all`s like the other lifecycle writes, and never change `status`:
  the token is still good, and the grant is skipped for new selections only
  until the reset passes. Nothing writes them for an owned row.

  Both ciphertexts, `id_claims` and `account_email` are `redact: true`: a
  row or a changeset that reaches a log line through `inspect/1` prints
  `**redacted**` for them, in the struct and in a changeset's `changes`
  alike. A refused write hands its caller a changeset, and a user's row
  holds a tenant-wrapped refresh token and the email of their ChatGPT
  account.

  There is no plaintext column. The application writers are
  `Fountain.ChatGPTAccounts`'s admin mutations and refresh path, and its
  `*_for_user` writes (ADR 0060).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @kinds ~w(chatgpt workspace_token)
  @statuses ~w(active revoked expired disconnected)

  @type t :: %__MODULE__{}
  schema "platform_chatgpt_account" do
    field :user_id, :binary_id
    field :name, :string
    field :generation, Ecto.UUID, autogenerate: true
    field :lock_version, :integer, default: 1
    field :kind, :string
    field :refresh_token_ciphertext, :binary, redact: true
    field :access_token_ciphertext, :binary, redact: true
    field :id_claims, :map, default: %{}, redact: true
    field :account_id, :string
    field :account_email, :string, redact: true
    field :plan_type, :string
    field :access_expires_at, :utc_datetime
    field :last_refreshed_at, :utc_datetime
    field :status, :string, default: "active"
    field :revoked_reason, :string
    field :usage_exhausted_at, :utc_datetime
    field :usage_exhausted_until, :utc_datetime
    field :usage_checked_at, :utc_datetime

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
    |> clear_exhaustion_on_new_account()
    |> version_existing()
    |> validate_required([:kind, :access_token_ciphertext, :last_refreshed_at])
    |> validate_inclusion(:kind, @kinds)
    |> unique_constraint(:user_id, name: :platform_chatgpt_account_platform_row)
  end

  @doc """
  A user's first link of one subscription: `connect_changeset/2` plus the
  name, on a struct that already carries its owner. The name is cast here
  and in `rename_changeset/2` only; a reconnect goes through
  `user_reconnect_changeset/2` and keeps it.
  """
  def user_connect_changeset(%__MODULE__{user_id: user_id} = account, attrs)
      when is_binary(user_id) do
    account
    |> connect_changeset(attrs)
    |> cast(attrs, [:name])
    |> name_rules()
    |> owned_rules()
  end

  @doc """
  A reconnect of one of a user's grants: `connect_changeset/2` over the
  loaded row, so `generation` changes and `lock_version` advances, with the
  name left as it is.
  """
  def user_reconnect_changeset(
        %__MODULE__{user_id: user_id, __meta__: %{state: :loaded}} = account,
        attrs
      )
      when is_binary(user_id) do
    account
    |> connect_changeset(attrs)
    |> owned_rules()
  end

  @doc """
  The tombstone of a user's grant. Under the row lock its caller holds, so
  the optimistic lock is there to advance `lock_version`, not to detect a
  race, as in `connect_changeset/2`.
  """
  def disconnect_changeset(%__MODULE__{user_id: user_id, __meta__: %{state: :loaded}} = account)
      when is_binary(user_id) do
    account
    |> change(%{
      status: "disconnected",
      revoked_reason: nil,
      access_token_ciphertext: nil,
      refresh_token_ciphertext: nil,
      id_claims: %{},
      access_expires_at: nil,
      generation: Ecto.UUID.generate()
    })
    |> optimistic_lock(:lock_version)
    |> check_constraint(:status, name: :chatgpt_grant_tokens_follow_status)
  end

  @doc """
  A new label for an owned grant. Touches neither `generation` nor
  `lock_version` (see the moduledoc), and Ecto writes only the changed
  columns, so it cannot clobber a concurrent token write either.
  """
  def rename_changeset(%__MODULE__{user_id: user_id} = account, attrs)
      when is_binary(user_id) do
    account
    |> cast(attrs, [:name])
    |> name_rules()
  end

  @doc """
  What a grant's name has to be, without the indexes that say it is free:
  trimmed, present, at most 200 characters. A link attempt holds the name
  for minutes before any grant row exists
  (`Fountain.ChatGPTAccounts.LinkAttempt`), and asks the same thing of it.
  `cast/3` turns a blank name into a nil change on a row that has one, so
  the trim has to let nil through for `validate_required/2` to answer.
  """
  def name_format(changeset) do
    changeset
    |> update_change(:name, &(&1 && String.trim(&1)))
    |> validate_required([:name])
    |> validate_length(:name, min: 1, max: 200)
  end

  # The unique error sits on the field a person can change, not on the
  # index's leading `user_id`.
  defp name_rules(changeset) do
    changeset
    |> name_format()
    |> unique_constraint(:name,
      name: :platform_chatgpt_account_user_id_name_index,
      message: "already names a ChatGPT subscription on this account"
    )
    |> check_constraint(:name, name: :chatgpt_grant_name_follows_owner, message: "is required")
  end

  # An owned row is always a refreshable ChatGPT sign-in. A NULL
  # `account_id` would slip the per-owner index, so one is required.
  # `updated_by_user_id` is the operator who connected the platform grant and
  # stays nil here: the owner is `user_id`, and a second user column would
  # have that user's deletion write this owner's row.
  defp owned_rules(changeset) do
    changeset
    |> put_change(:updated_by_user_id, nil)
    |> validate_required([:account_id, :refresh_token_ciphertext])
    |> validate_inclusion(:kind, ["chatgpt"])
    |> unique_constraint(:account_id,
      name: :platform_chatgpt_account_user_id_account_id_index,
      message: "is already linked to this account"
    )
  end

  # Codex usage limits belong to the ChatGPT account, not to its token
  # (#2362): reconnecting the same account keeps the recorded exhaustion,
  # because its next turn would fail with the same reset time. A different
  # account starts clean.
  defp clear_exhaustion_on_new_account(changeset) do
    if changed?(changeset, :account_id) do
      changeset
      |> put_change(:usage_exhausted_at, nil)
      |> put_change(:usage_exhausted_until, nil)
      |> put_change(:usage_checked_at, nil)
    else
      changeset
    end
  end

  defp version_existing(%{data: %{__meta__: %{state: :loaded}}} = changeset),
    do: optimistic_lock(changeset, :lock_version)

  defp version_existing(changeset), do: changeset
end
