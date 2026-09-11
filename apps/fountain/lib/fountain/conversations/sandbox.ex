defmodule Fountain.Conversations.Sandbox do
  use Ecto.Schema
  import Ecto.Changeset

  alias Fountain.Accounts.User
  alias Fountain.Conversations.Conversation
  alias Fountain.Environments.Environment

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  # `suspended`: the sprite still exists at sprites.dev (scaled to zero on its
  # own) but no ConversationServer is attached. The durable resting state of an
  # idle conversation — not counted toward the concurrency quota, woken by the
  # next prompt via the reattach path. See decisions/0017.
  @statuses ~w(pending starting ready suspended terminated failed)

  # `ephemeral`: the conversation's machine, created with it and reclaimed
  # with it. `persistent`: the agent identity's machine — a home — that every
  # conversation of that identity lands on, kept when a conversation ends,
  # parked rather than destroyed at the ceiling, and single per identity by
  # the partial unique index (ADR 0023).
  @modes ~w(ephemeral persistent)

  @type t :: %__MODULE__{}

  schema "sandboxes" do
    # Provider-scoped sandbox identity: the name Fountain mints
    # (`fountain-<tenant-prefix>-<hex>`) and uses as the primary external ref.
    # The column name predates multiple providers and survives for API and
    # historical-metadata compatibility.
    field :sprite_name, :string
    field :status, :string, default: "pending"
    # Which sandbox backend owns this row. Stamped at creation and never
    # re-resolved: a parked sandbox wakes on the provider that holds its
    # disk, whatever the instance default is by then.
    field :provider, :string, default: "sprites"
    # Adapter-opaque state (e.g. a server-assigned id). Never tenant-visible.
    field :provider_meta, :map, default: %{}
    # Trusted control-plane identity; general sandbox attributes cannot set it.
    field :provider_instance_id, :string
    field :mode, :string, default: "ephemeral"
    field :terminated_at, :utc_datetime
    field :last_resumed_at, :utc_datetime
    # Internal reset fence; retained after completion as operation evidence.
    field :reset_requested_at, :utc_datetime_usec
    # Forced teardown intent; admission still uses the shared reset fence.
    field :teardown_requested_at, :utc_datetime_usec
    # A digest of the Environment fields provisioning turned into disk state:
    # packages, repositories, the setup script and the network policy. Written
    # when the machine reaches `ready`, so a later reapply can tell whether the
    # selection it is asked for would need the disk built again, rather than
    # assuming it would. See `Fountain.Conversations.Reapply` (#1565).
    field :build_fingerprint, :string
    # The skill selection this machine was last reconciled to, so the next
    # reconciliation knows which entries under the skills root are ours.
    field :applied_skills, {:array, :map}
    belongs_to :environment, Environment
    # The identity the disk was materialized from, with the environment
    # (ADR 0023): env vars, packages, repos and setup scripts are written at
    # provision, so a machine built for one agent, environment and vault is
    # not a machine built for another. A conversation attaches only with the
    # same three. Nilified when the agent or vault is deleted, like a
    # conversation's own pointers — the row outlives them as history.
    belongs_to :agent, Fountain.Agents.Agent
    belongs_to :vault, Fountain.Vaults.Vault
    belongs_to :user, User
    has_many :conversations, Conversation
    timestamps(type: :utc_datetime)
  end

  def statuses, do: @statuses

  @doc "The sandbox modes (ADR 0023)."
  def modes, do: @modes

  def changeset(sandbox, attrs) do
    sandbox
    |> cast(attrs, [
      :sprite_name,
      :status,
      :provider,
      :provider_meta,
      :mode,
      :terminated_at,
      :last_resumed_at,
      :build_fingerprint,
      :applied_skills,
      :environment_id,
      :agent_id,
      :vault_id,
      :user_id
    ])
    |> validate_required([:sprite_name, :status, :provider, :mode, :user_id])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:mode, @modes)
    |> validate_inclusion(:provider, Fountain.SandboxProviders.known_providers())
    # One live home per identity. Surfaced under `:home` so a launch that
    # lost the race to create it can tell and attach to the winner instead.
    |> unique_constraint(:home,
      name: :sandboxes_home_identity_index,
      message: "a home for this agent, environment and vault already exists"
    )
  end
end
