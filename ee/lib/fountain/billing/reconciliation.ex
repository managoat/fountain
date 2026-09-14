defmodule Fountain.Billing.Reconciliation do
  @moduledoc """
  Computed spend held next to what the provider actually charged (#1038
  step 1), and the count of metering events this node has dropped (step 2).

  `Finance.summary/1` is a plausible number with an unknown error until a
  real invoice sits beside it. `record_invoice/2` stores one per provider
  per month; `lines/2` produces, for every provider Fountain pays, the
  computed cents, the recorded cents, and the delta. A month of deltas is
  what turns each gap in the model from a silent bias into a measured one,
  and is what a price change should rest on (ADR 0030 §8).

  Recording an invoice is an admin act on platform data, not on a tenant, so
  the audit row carries no `user_id` and an `admin:<id>` actor.
  """

  import Ecto.Query

  alias Fountain.Audit
  alias Fountain.Billing.Finance
  alias Fountain.Billing.ProviderInvoice
  alias Fountain.Repo

  @doc """
  Record (or replace) what `provider` charged for the month starting
  `period_start`. `attrs` is string-keyed: `provider`, `period_start`,
  `period_end`, `amount_cents`, `note`. Options carry the audit attribution.
  """
  @spec record_invoice(map(), keyword()) ::
          {:ok, ProviderInvoice.t()} | {:error, Ecto.Changeset.t()}
  def record_invoice(attrs, opts \\ []) do
    changeset = ProviderInvoice.changeset(%ProviderInvoice{}, attrs)

    with {:ok, invoice} <-
           Repo.insert(changeset,
             on_conflict: {:replace, [:period_end, :amount_cents, :note, :updated_at]},
             conflict_target: [:provider, :period_start],
             returning: true
           ) do
      Audit.record(%{
        user_id: nil,
        action: "finance.invoice.recorded",
        resource_type: "provider_invoice",
        resource_id: invoice.id,
        actor: Keyword.get(opts, :actor, "admin"),
        request_ip: Keyword.get(opts, :request_ip),
        metadata: %{
          "provider" => invoice.provider,
          "period_start" => Date.to_iso8601(invoice.period_start),
          "amount_cents" => invoice.amount_cents
        }
      })

      {:ok, invoice}
    end
  end

  @doc "Invoices recorded for the month starting `period_start`, by provider."
  @spec invoices_for(Date.t()) :: %{optional(String.t()) => ProviderInvoice.t()}
  def invoices_for(%Date{} = period_start) do
    from(i in ProviderInvoice, where: i.period_start == ^period_start)
    |> Repo.all()
    |> Map.new(&{&1.provider, &1})
  end

  @typedoc "One provider's computed-versus-invoiced line."
  @type line :: %{
          provider: String.t(),
          computed_cents: integer() | nil,
          recorded_cents: integer() | nil,
          delta_cents: integer() | nil,
          note: String.t() | nil
        }

  @doc """
  One line per provider Fountain pays, from a `Finance.summary/1` and the
  invoices recorded for its month. `computed_cents` is nil where the rate
  card cannot price the provider; `delta_cents` is recorded minus computed,
  so a positive delta means the model under-reports.
  """
  @spec lines(map(), %{optional(String.t()) => ProviderInvoice.t()}) :: [line()]
  def lines(summary, invoices) do
    computed = computed_by_provider(summary)

    for provider <- ProviderInvoice.providers() do
      c = Map.get(computed, provider)
      r = invoices[provider] && invoices[provider].amount_cents

      %{
        provider: provider,
        computed_cents: c,
        recorded_cents: r,
        delta_cents: if(is_integer(c) and is_integer(r), do: r - c),
        note: invoices[provider] && invoices[provider].note
      }
    end
  end

  # Sandbox providers from the attribution roll-up at the summary's basis.
  # Priced by `Finance`'s own function so the two can never round differently.
  defp computed_by_provider(summary) do
    card = summary.rate_card

    Map.new(summary.cost.by_provider, fn {provider, totals} ->
      seconds = if(card.basis == :turn, do: totals.busy_seconds, else: totals.active_seconds)
      {provider, Finance.provider_cost_cents(seconds, provider, card)}
    end)
  end

  @doc """
  Metering events dropped on this node since it booted (`[:fountain, :usage,
  :dropped]`). A non-zero count means the period's figures rest on an
  incomplete record. Per node and since boot — a fleet-wide, durable count is
  what a metric backend is for; this is the number that belongs beside the
  figures it undermines.
  """
  @spec dropped_on_this_node() :: non_neg_integer()
  def dropped_on_this_node do
    case :persistent_term.get({__MODULE__, :dropped}, nil) do
      nil -> 0
      ref -> :counters.get(ref, 1)
    end
  end

  @doc false
  def attach_drop_counter do
    ref = :counters.new(1, [:write_concurrency])
    :persistent_term.put({__MODULE__, :dropped}, ref)

    :telemetry.attach(
      "fountain-usage-dropped-counter",
      [:fountain, :usage, :dropped],
      &__MODULE__.handle_drop/4,
      ref
    )
  end

  @doc false
  def handle_drop(_event, %{count: n}, _meta, ref), do: :counters.add(ref, 1, n)

  @doc false
  def reset_drop_counter do
    case :persistent_term.get({__MODULE__, :dropped}, nil) do
      nil -> :ok
      ref -> :counters.put(ref, 1, 0)
    end
  end
end
