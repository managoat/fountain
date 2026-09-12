defmodule Fountain.Conversations.Conversation do
  use Ecto.Schema
  import Ecto.Changeset

  alias Fountain.Accounts.User
  alias Fountain.Agents.Agent
  alias Fountain.Conversations.{Sandbox, Turn}
  alias Fountain.Environments.Environment
  alias Fountain.Vaults.Vault

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  # No `completed`. It was in this list, three query sites filtered on it, and
  # nothing ever wrote it — production has 247 terminated, 5 idle, 3 failed and
  # zero completed, so every filter keyed on it was silently always empty.
  #
  # There is also no state it could describe. A conversation is either usable
  # (pending/running/idle) or finished with (failed/terminated), and #167
  # settled the ambiguous case: reclaiming an idle sandbox leaves the
  # conversation `idle` and resumable rather than closing it. "Done" is the
  # user's decision, and that is `terminated`.
  @statuses ~w(pending running idle failed terminated)
  @sources ~w(ui api agent)
  @sandbox_api_access_modes ~w(owner none)

  @type t :: %__MODULE__{}

  schema "conversations" do
    field :runtime, :string
    field :status, :string, default: "pending"
    # Counts committed selections (#1565). Turn admission checks it against
    # the revision the live server loaded, so a server that missed the refresh
    # notification cannot start a turn on settings it has not read.
    field :configuration_revision, :integer, default: 0
    field :runtime_session_id, :string
    field :source, :string, default: "api"
    field :parent_conversation_id, :binary_id
    field :callback_api_key_id, :binary_id
    # Immutable launch boundary: none never mints a sandbox callback credential.
    field :sandbox_api_access, :string, default: "owner"
    field :title, :string
    field :last_read_at, :utc_datetime_usec
    # Client-supplied key for the external channel this conversation is bound
    # to (a Buzz channel id via ACP `session/new` `_meta.channelId`, #774).
    # `start_or_resume_conversation/2` resumes by it. Opaque to Fountain.
    field :channel_id, :string
    # Running sums of the turns' `usage.input` / `usage.output` (#827), kept
    # by `Conversations._unsafe_record_turn_usage/2` as each turn ends. Not
    # in `changeset/2`: nothing user-facing writes them.
    field :usage_input_tokens, :integer, default: 0
    field :usage_output_tokens, :integer, default: 0

    # Per-launch permission override (#939). nil means "this launch had no
    # opinion" and the agent's policy stands alone. Set, it is merged with the
    # agent's by `Permissions.effective/2`, which takes the stricter of the two
    # per tool — so this can only ever narrow, and an agent that tightens later
    # tightens this conversation too. The widening case is rejected at the door
    # in `start_conversation/2` rather than silently clamped.
    field :permission_policy, :map
    # The caller-defined tools of the bridge (#1202, `Fountain.CallerTools`).
    field :caller_tools, {:array, :map}, default: []
    # Free-form `key => value` strings (#1637). Set at launch, merged by the
    # labels route and by the agent's own `_fountain/labels` ACP notification,
    # and filtered on with jsonb containment. `Conversations.Labels` owns the
    # limits and the merge; writes here go through `Labels.changeset/1` below,
    # which is why every door enforces the same rule.
    field :labels, :map, default: %{}

    # Populated by list_conversations_by_activity/1 — not persisted.
    field :turn_count, :integer, virtual: true, default: 0
    field :last_active_at, :utc_datetime_usec, virtual: true

    belongs_to :user, User
    belongs_to :sandbox, Sandbox
    belongs_to :agent, Agent
    belongs_to :vault, Vault
    # Per-launch environment override (#783). nil means "the agent's
    # environment" — resolved at provision, so a conversation whose agent
    # later changes environments follows the agent, as before. Set, it is the
    # baseline this conversation's sandboxes are provisioned from instead,
    # every time (a wake provisions a fresh sandbox from it too).
    belongs_to :environment, Environment
    # Per-launch credential set override (ADR 0053 decision 3). nil means
    # "this launch had no opinion" and the agent's set answers, resolved at
    # provision -- so a conversation whose agent later moves sets follows the
    # agent, exactly as the environment override behaves. Set, it is the
    # credential every sandbox of this conversation provisions with.
    belongs_to :inference_credential, Fountain.InferenceCredentials.Credential

    # Which shape of the agent this conversation launched under — provenance,
    # like the snapshotted `runtime`. The live agent row still drives the
    # sandbox; this only records what the config was at launch.
    belongs_to :agent_version, Fountain.Agents.AgentVersion

    belongs_to :parent_conversation, __MODULE__,
      foreign_key: :parent_conversation_id,
      references: :id,
      type: :binary_id,
      define_field: false

    has_many :child_conversations, __MODULE__, foreign_key: :parent_conversation_id
    has_many :turns, Turn
    timestamps(type: :utc_datetime)
  end

  def statuses, do: @statuses
  def sources, do: @sources
  def sandbox_api_access_modes, do: @sandbox_api_access_modes

  defp validate_sandbox_api_access_immutable(changeset) do
    if changeset.data.__meta__.state == :loaded and
         get_change(changeset, :sandbox_api_access) do
      add_error(changeset, :sandbox_api_access, "cannot change after launch")
    else
      changeset
    end
  end

  def changeset(conv, attrs) do
    conv
    |> cast(attrs, [
      :runtime,
      :status,
      :runtime_session_id,
      :source,
      :parent_conversation_id,
      :callback_api_key_id,
      :sandbox_api_access,
      :title,
      :user_id,
      :sandbox_id,
      :agent_id,
      :agent_version_id,
      :vault_id,
      :environment_id,
      :inference_credential_id,
      :channel_id,
      :permission_policy,
      :caller_tools,
      :labels
    ])
    |> validate_required([:runtime, :status, :sandbox_id, :user_id])
    |> Fountain.Changeset.validate_ids([
      :parent_conversation_id,
      :callback_api_key_id,
      :user_id,
      :sandbox_id,
      :agent_id,
      :agent_version_id,
      :vault_id,
      :environment_id,
      :inference_credential_id
    ])
    |> validate_length(:channel_id, max: 255)
    |> validate_length(:title, max: 120)
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:source, @sources)
    |> validate_inclusion(:sandbox_api_access, @sandbox_api_access_modes)
    |> validate_sandbox_api_access_immutable()
    |> Fountain.Conversations.Labels.changeset()
    |> foreign_key_constraint(:sandbox_id)
    |> foreign_key_constraint(:agent_id)
    |> foreign_key_constraint(:agent_version_id)
    |> foreign_key_constraint(:vault_id)
    |> foreign_key_constraint(:environment_id)
    |> foreign_key_constraint(:inference_credential_id)
    |> foreign_key_constraint(:parent_conversation_id)
  end
end
