defmodule Fountain.Usage.Event do
  @moduledoc """
  Schema for the `usage_events` table: the sandbox lifecycle, one row per
  provision, turn start, park, wake and teardown.

  **Nothing here is money** (#1143). The rows are counts for the dashboard and
  the admin usage summaries, and the park/wake pairs
  `Fountain.Machines.Usage` subtracts from sandbox time. The writer,
  `Fountain.Usage.record_usage/5`, rescues and logs rather than failing the
  action that produced it, because a metering outage must never fail a
  conversation.

  Never updated after insertion (no `updated_at`).
  """

  use Ecto.Schema
  import Ecto.Changeset

  # The migration uses the default integer (bigint) PK — better for append-only
  # ordered reads than UUID.
  @primary_key {:id, :id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}
  schema "usage_events" do
    field :user_id, :binary_id
    field :event_type, :string
    field :resource_id, :binary_id
    field :resource_type, :string
    field :metadata, :map, default: %{}
    # Write-once timestamp managed manually (no `timestamps()` macro).
    field :inserted_at, :utc_datetime
  end

  # The closed vocabulary: the sandbox lifecycle.
  #
  # None of it is priced. `sandbox_terminated` never was — it is forensic
  # only, and `Fountain.Machines.Usage` reads the sandbox rows. Do not add a type
  # expecting it to bill.
  @valid_event_types ~w(sandbox_provisioned sandbox_provision_failed turn_started sandbox_terminated
                         sandbox_suspended sandbox_resumed)

  def changeset(usage_event, attrs) do
    usage_event
    |> cast(attrs, [:user_id, :event_type, :resource_id, :resource_type, :metadata, :inserted_at])
    |> validate_required([:user_id, :event_type, :inserted_at])
    |> validate_inclusion(:event_type, @valid_event_types)
  end
end
