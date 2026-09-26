defmodule Fountain.Environments.Environment do
  use Ecto.Schema
  import Ecto.Changeset

  alias Fountain.Accounts.User
  alias Fountain.Environments.Secret

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @networking ~w(unrestricted limited)

  # Fields that affect provisioning. Changing any of these invalidates
  # the env's sprite checkpoint — the warm-start state would be wrong.
  @warm_start_fields [
    :packages,
    :env_vars,
    :setup_script,
    :setup_timeout_seconds,
    :networking_type,
    :networking_config,
    :repositories
  ]

  schema "environments" do
    field :inference_revision, Ecto.UUID, read_after_writes: true
    field :name, :string
    field :packages, :map, default: %{}
    field :env_vars, :map, default: %{}
    field :setup_script, :string, default: ""
    field :setup_timeout_seconds, :integer, default: 120
    field :networking_type, :string, default: "unrestricted"
    field :networking_config, :map, default: %{}
    field :repositories, {:array, :map}, default: []
    field :checkpoint_id, :string
    # Free-form caller bookkeeping. Deliberately NOT a warm-start field:
    # changing it must not invalidate the provisioning checkpoint.
    field :metadata, :map, default: %{}

    # Populated by the *_with_counts reads — not persisted. "Is this
    # environment in use / safe to delete" is the question these answer.
    field :secret_count, :integer, virtual: true, default: 0
    field :agent_count, :integer, virtual: true, default: 0

    belongs_to :user, User
    has_many :secrets, Secret
    timestamps(type: :utc_datetime)
  end

  def warm_start_fields, do: @warm_start_fields

  @doc """
  Where this environment's repositories are cloned: each entry's `mount_path`,
  in order. A runtime whose sandbox limits writes to its own working directory
  is handed these as writable roots (#1684), since a clone the agent cannot
  branch from or commit to is rarely what the environment's author meant.
  """
  @spec repository_mounts(t() | nil) :: [String.t()]
  def repository_mounts(nil), do: []

  def repository_mounts(%__MODULE__{repositories: repos}) do
    for %{"mount_path" => mount} <- repos || [], is_binary(mount), uniq: true, do: mount
  end

  def networking, do: @networking

  @doc false
  def cast_fields,
    do: [
      :name,
      :packages,
      :env_vars,
      :setup_script,
      :setup_timeout_seconds,
      :networking_type,
      :networking_config,
      :repositories,
      :checkpoint_id,
      :metadata,
      :user_id
    ]

  def changeset(env, attrs) do
    env
    |> cast(attrs, cast_fields())
    |> validate_required([:name, :setup_timeout_seconds])
    |> validate_number(:setup_timeout_seconds,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: 900
    )
    |> validate_inclusion(:networking_type, @networking)
    |> validate_length(:name, min: 1, max: 200)
    |> validate_change(:networking_config, &validate_networking_config/2)
    |> validate_change(:repositories, &validate_repositories/2)
    |> maybe_invalidate_checkpoint()
    |> unique_constraint(:name, name: :environments_user_id_name_index)
  end

  # If any provisioning-relevant field changed AND the caller didn't
  # explicitly set checkpoint_id in this changeset, drop the existing
  # checkpoint — the warm-start state would diverge from the env's
  # actual config. The next provision will create a fresh checkpoint.
  defp maybe_invalidate_checkpoint(changeset) do
    explicitly_set? = Map.has_key?(changeset.changes, :checkpoint_id)

    changed_warm? =
      Enum.any?(@warm_start_fields, fn f -> Map.has_key?(changeset.changes, f) end)

    if changed_warm? and not explicitly_set? do
      put_change(changeset, :checkpoint_id, nil)
    else
      changeset
    end
  end

  defp validate_repositories(_field, list) when is_list(list) do
    Enum.flat_map(list, fn
      %{"url" => url, "mount_path" => mount}
      when is_binary(url) and is_binary(mount) and url != "" and mount != "" ->
        if String.starts_with?(mount, "/") and String.starts_with?(url, "https://") do
          []
        else
          [repositories: "url must be https:// and mount_path must be absolute"]
        end

      _ ->
        [repositories: "each entry needs `url` (https://...) and `mount_path` (/abs/path)"]
    end)
  end

  defp validate_repositories(_, _), do: []

  # networking_config's only honored key is "allowed_hosts" (see
  # Provisioning.apply_network_policy/3 — under `limited` it becomes the
  # sprite's domain allowlist). Unknown keys stay allowed for forward
  # compat, but a malformed allowed_hosts fails here instead of silently
  # producing a policy the author didn't intend.
  defp validate_networking_config(_field, %{} = config) do
    case Map.get(config, "allowed_hosts") || Map.get(config, :allowed_hosts) do
      nil ->
        []

      hosts when is_list(hosts) ->
        if Enum.all?(hosts, fn h -> is_binary(h) and h != "" end) do
          []
        else
          [networking_config: "allowed_hosts entries must be non-empty strings"]
        end

      _ ->
        [networking_config: "allowed_hosts must be a list of hostnames"]
    end
  end

  defp validate_networking_config(_, _), do: []
end
