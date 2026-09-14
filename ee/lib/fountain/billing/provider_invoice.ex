defmodule Fountain.Billing.ProviderInvoice do
  @moduledoc "One provider's bill for one month, as invoiced (#1038)."

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @providers ~w(sprites e2b daytona)

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "provider_invoices" do
    field :provider, :string
    field :period_start, :date
    field :period_end, :date
    field :amount_cents, :integer
    field :note, :string
    timestamps(type: :utc_datetime)
  end

  @doc "The providers an invoice can be recorded for."
  def providers, do: @providers

  def changeset(invoice, attrs) do
    invoice
    |> cast(attrs, [:provider, :period_start, :period_end, :amount_cents, :note])
    |> validate_required([:provider, :period_start, :period_end, :amount_cents])
    |> validate_inclusion(:provider, @providers)
    |> validate_number(:amount_cents, greater_than_or_equal_to: 0)
    |> validate_length(:note, max: 500)
    |> unique_constraint([:provider, :period_start])
  end
end
