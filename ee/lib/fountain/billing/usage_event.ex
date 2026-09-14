defmodule Fountain.Billing.UsageEvent do
  @moduledoc """
  Schema for the `usage_events` table.

  **Nothing here is money any more** (#1143). These rows are the product
  signal: a count on a dashboard and the PostHog mirror that
  `Billing.record_usage/5` writes from the same choke point. That writer
  rescues and logs rather than failing the action that produced it, because a
  metering outage must never fail a conversation — the right contract for a
  count and the wrong one for a row the ledger keys on.

  Comms messages used to be priced from the `comms_*` rows here, so a dropped
  event was a message the customer was never charged for (#1143). Messages are
  not priced at all any more; the `comms_*` types stay in the vocabulary, and
  stay product-only.

  Written from `ConversationServer` at key lifecycle points and from the comms
  paths; never updated after insertion (no `updated_at`).
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

  # The closed vocabulary. Sandbox lifecycle, and the teammate messages.
  #
  # None of it is priced. `sandbox_terminated` never was — it is forensic
  # only, and `SandboxUsage` reads the sandbox rows — and the `comms_*` types
  # are a product count only. Do not add a type expecting it to bill.
  @valid_event_types ~w(sandbox_provisioned sandbox_provision_failed turn_started sandbox_terminated
                         sandbox_suspended sandbox_resumed
                         comms_email_sent comms_sms_sent comms_sms_received)

  def changeset(usage_event, attrs) do
    usage_event
    |> cast(attrs, [:user_id, :event_type, :resource_id, :resource_type, :metadata, :inserted_at])
    |> validate_required([:user_id, :event_type, :inserted_at])
    |> validate_inclusion(:event_type, @valid_event_types)
  end
end
