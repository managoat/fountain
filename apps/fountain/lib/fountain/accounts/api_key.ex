defmodule Fountain.Accounts.ApiKey do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @moduledoc """
  A tenant API key.

  ## Scopes

    * `"full"`   — everything, including issuing and revoking API keys. What a
      human gets from the UI or `managoat keys create`.
    * `"sprite"` — the per-conversation token handed to a sandbox. It reaches
      its own conversation tree (the conversation and its descendants) and,
      outside it, only reads agents, environments and vaults to spawn from
      (`FountainWeb.Plugs.SandboxKeyScope`, ADR 0096), because spawning
      sub-agents from inside a sprite is a supported workflow. It does **not**
      reach API key management: without that
      exclusion, code running in a sandbox can mint a permanent key that
      survives the conversation-scoped revoke at teardown, turning a
      one-conversation credential into standing tenant access. Nor does it
      write agents, environments, vaults or their secrets, or apply a
      manifest (ADR 0039, amended 2026-10-14). The router's
      `:require_full_scope` pipeline is where each of those is refused.
    * `"conversation"` — the key an `"auth": "conversation"` MCP server
      receives (ADR 0086, amended for #2934). It reads its own conversation
      and nothing else: `GET /api/auth/me` and that conversation's show,
      turns, events, stream and turn images
      (`FountainWeb.Plugs.ConversationKeyScope`). It names that conversation
      (`conversation_id`) and the sandbox callback key it was minted from
      (`parent_key_id`); revoking the parent revokes it, it never outlives the
      parent's `expires_at`, and deleting either deletes it. Minted only by
      `Fountain.Accounts.create_conversation_api_key/4`.
    * `"admin"`  — the operator surface, `/api/admin` (#2660). Always carried
      beside `"full"`, never alone, and minted only by
      `Fountain.Accounts.create_admin_api_key/3`: the admin's Account → API
      keys page, or the `Fountain.Release.create_admin_key/2` release task.
      OAuth, `POST /api/auth/token` and `POST /api/auth/api-keys` mint
      `"full"` keys and nothing else, so signing an admin into an app or the
      CLI does not hand that app operator powers. `/api/admin` requires this
      scope *and* the admin role (`FountainWeb.Plugs.RequireAdminApi`).
  """

  @scopes ~w(full sprite conversation admin)

  # What an admin key carries: `full` too, so it still passes the
  # `:require_full_scope` gate in front of `/api/admin`.
  @admin_scopes ~w(full admin)

  # Scopes permitted to issue, list, or revoke API keys.
  @key_management_scopes ~w(full)

  @type t :: %__MODULE__{}
  schema "api_keys" do
    field :name, :string
    field :key_hash, :string
    field :key_prefix, :string
    field :last_used_at, :utc_datetime
    field :revoked_at, :utc_datetime
    field :expires_at, :utc_datetime
    field :scopes, {:array, :string}, default: ["full"]

    # Set only on a `"conversation"` key (#2934): the conversation it reads,
    # and the sandbox callback key it was minted from and dies with.
    field :conversation_id, :binary_id
    field :parent_key_id, :binary_id

    belongs_to :user, Fountain.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def scopes, do: @scopes

  @doc "The scopes an admin key carries (#2660)."
  def admin_scopes, do: @admin_scopes

  @doc "Whether `key` carries the `admin` scope that `/api/admin` requires (#2660)."
  def admin?(%__MODULE__{scopes: scopes}), do: "admin" in scopes

  @doc "Whether `key` may issue, list, or revoke API keys."
  def may_manage_keys?(%__MODULE__{scopes: scopes}) do
    Enum.any?(scopes, &(&1 in @key_management_scopes))
  end

  @doc """
  Whether `key` is a `"conversation"` key (#2934): one that may read its own
  conversation and nothing else.
  """
  def conversation_bound?(%__MODULE__{scopes: scopes}), do: "conversation" in scopes

  @doc "Whether `key` is past its expiry. Keys without one never expire."
  def expired?(%__MODULE__{expires_at: nil}), do: false

  def expired?(%__MODULE__{expires_at: at}) do
    DateTime.compare(DateTime.utc_now(), at) == :gt
  end

  @doc """
  Changeset for creating a new API key record.
  Expects :name, :key_hash, :key_prefix, :user_id to be provided.
  The raw key is never stored — callers must compute key_hash and key_prefix before
  calling this changeset.
  """
  def changeset(api_key, attrs) do
    api_key
    |> cast(attrs, [
      :name,
      :key_hash,
      :key_prefix,
      :user_id,
      :scopes,
      :expires_at,
      :conversation_id,
      :parent_key_id
    ])
    |> validate_required([:name, :key_hash, :key_prefix, :user_id, :scopes])
    |> validate_length(:name, min: 1, max: 200)
    |> validate_length(:scopes, min: 1)
    |> validate_subset(:scopes, @scopes)
    |> validate_conversation_binding()
    |> unique_constraint(:key_hash)
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:conversation_id)
    |> foreign_key_constraint(:parent_key_id)
  end

  # A `"conversation"` key is that scope alone and names its conversation and
  # parent; no other key names either. A `"conversation"` key beside `"full"`
  # or `"sprite"` would carry their reach, which is what the scope exists to
  # take away (#2934).
  defp validate_conversation_binding(changeset) do
    scopes = get_field(changeset, :scopes) || []

    if "conversation" in scopes do
      changeset
      |> validate_required([:conversation_id, :parent_key_id])
      |> validate_length(:scopes,
        is: 1,
        message: "a conversation key carries no other scope"
      )
    else
      changeset
      |> validate_inclusion(:conversation_id, [nil], message: "only a conversation key names one")
      |> validate_inclusion(:parent_key_id, [nil],
        message: "only a conversation key has a parent"
      )
    end
  end
end
