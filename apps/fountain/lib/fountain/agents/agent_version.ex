defmodule Fountain.Agents.AgentVersion do
  @moduledoc """
  An immutable snapshot of an agent's config, written by `Fountain.Agents`
  on create and on every update that changes a configuration field.

  `config` holds the full string-keyed payload (see
  `Fountain.Agents.snapshot_config/1`), so a version can be rendered, diffed
  and rolled back to without consulting the live row. This is deliberately a
  copy of tenant data in a tenant-owned table — unlike the audit trail, which
  records only *which* fields moved (decisions/0013), a version's whole point
  is restoring the values. Versions live exactly as long as their agent: the
  FK cascades on agent delete, and account deletion takes the lot.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Fountain.Accounts.User
  alias Fountain.Agents.Agent

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "agent_versions" do
    field :version, :integer
    field :config, :map
    # Missing historical keys mean a partial restore, never inferred access.
    field :vault_access, :string, read_after_writes: true, writable: :never
    field :environment_access, :string, read_after_writes: true, writable: :never
    belongs_to :agent, Agent
    belongs_to :user, User
    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc "Internal changeset — versions are written by the context, never from user input."
  def changeset(agent_version, attrs) do
    agent_version
    |> cast(attrs, [:version, :config, :agent_id, :user_id])
    |> validate_required([:version, :config, :agent_id, :user_id])
    |> unique_constraint([:agent_id, :version])
  end
end
