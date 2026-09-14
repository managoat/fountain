defmodule Fountain.Billing.Finance do
  @moduledoc """
  What Fountain is paid and what Fountain pays, per tenant, over a period.

  The pieces have existed for a while and never met. `Billing.overview_admin/1`
  had revenue with no cost beside it, and `Billing.provider_spend/1` had cost
  with no revenue beside it and deliberately no money in it at all. This
  module puts the two on one row so the question "which tenants cost more
  than they pay" has an answer.

  ## Revenue

  Credits are the product (ADR 0031): a tenant's revenue is the credit it
  burned in the period — turn hours and platform inference — reported under
  `credits/1` beside what was granted and what was sold. A comped account burns credit like any other
  (the ledger is how a comp's cost is seen) but paid for none of it.

  ## Cost, and the rate card

  Fountain's spend is not in this codebase, and inventing it would make this
  page look authoritative when it is not — the reasoning `provider_spend/1`
  already committed to. So cost is priced from a **rate card in config**, and
  where the card is silent the answer is `nil`, never a guess:

  | Config key | Env var | Unit |
  |---|---|---|
  | `:provider_hourly_cents` | `PROVIDER_HOURLY_CENTS` | cents per sandbox hour, per provider |
  | `:cost_basis` | `PROVIDER_COST_BASIS` | `active` (default) or `turn` — which hours that rate multiplies |

  **Every rate may be fractional.** Rates stay fractional through the
  arithmetic and each cost component rounds to whole cents exactly once, at
  the end.

  One rate card covers every provider, and it prices them all on the same
  basis. That is right while the providers Fountain actually bills for behave
  the same way, and `sprites` (asleep after 30s idle, billed awake) and `e2b`
  (billed until paused) do not. Today it does not bite — every hour on the
  bill is a Sprites hour — but a deployment with real traffic on both wants a
  per-provider basis, not this.

  `nil` propagates: a tenant with sandbox hours on a provider that has no rate
  has `cost_cents: nil`, not a cost that silently omits them, and their margin
  is `nil` too. `priced?/0` says whether the card covers anything at all, so a
  surface can offer hours instead of dollars rather than showing zeroes. A
  self-hosted instance sets none of it and gets exactly the hours report it
  had before.

  ## Two kinds of cost, two shapes

  **Sandbox hours** come in two flavours and the panel prices whichever one
  the invoice actually tracks. `:active` is the whole window a sprite was
  awake, idle included; `:turn` is only the part with a prompt in flight. A
  provider that bills wall-clock matches the first, and one that scales to
  near-zero between prompts matches the second closely enough to reconcile
  against. `:cost_basis` on the config (`PROVIDER_COST_BASIS`) sets the
  default and `summary/1` takes a `:basis` override, because the way to find
  out which one a provider bills is to hold both next to the invoice.

  Every row carries active hours **and** turn hours whichever basis is
  chosen, because the gap between them is the tenant's idle time and it is
  the single largest lever on the bill. Turn hours are also what burns a
  tenant's prepaid credit (ADR 0030), so on the `:turn` basis cost and burn
  move together, and on `:active` they do not.

  **Credits** are the usage revenue: what a period's grants put in, what
  turns burned, what packs sold, and the deferred balance — money taken and
  not yet burned, which is a liability rather than revenue until it is.

  **Platform inference** is the one cost that is not priced from the rate
  card at all: it is read straight off the `burn_inference` ledger rows
  (#1388). Those rows *are* the bill — the rate card in
  `Fountain.Credits.InferenceRates` is the provider's list price with no
  markup (ADR 0038), so what a tenant was charged and what Fountain paid are
  the same number. It is therefore never `nil`, it appears in `revenue` and
  in `cost` both, and it nets to zero margin. That is the intended reading:
  the panel exists to show that inference is passed through and sandbox time
  is where the margin is.

  ## Cost, ownership and the tenants that are not there

  Sandbox seconds whose owner has been deleted keep a `nil` `user_id` all the
  way through `SandboxUsage` (decisions/0009). They are real spend and they
  are in `:unattributed_cost_cents`, out of the per-tenant rows, because there
  is no tenant to put them on. A total that quietly dropped them would
  understate the bill.

  ## Cost

  `summary/1` is two queries plus the two `SandboxUsage.attribution/3`
  already runs — one pass for every tenant, not a query per row. The finance
  panel refreshes on a timer, and so does `/admin`.
  """

  import Ecto.Query

  alias Fountain.Accounts.User
  alias Fountain.Billing
  alias Fountain.Billing.SandboxUsage
  alias Fountain.Repo

  @typedoc "One tenant's money for a period. Every `*_cents` may be `nil` when the rate card is silent."
  @type tenant_row :: %{
          user_id: binary(),
          email: String.t(),
          comped: boolean(),
          revenue_cents: non_neg_integer(),
          turn_hours: float(),
          credit_granted_cents: non_neg_integer(),
          credit_burned_cents: non_neg_integer(),
          credit_sold_cents: non_neg_integer(),
          credit_balance_cents: integer(),
          active_hours: float(),
          idle_hours: float(),
          sandbox_cost_cents: non_neg_integer() | nil,
          inference_cost_cents: non_neg_integer(),
          cost_cents: non_neg_integer() | nil,
          margin_cents: integer() | nil
        }

  ## ── the rate card ───────────────────────────────────────────────────────

  @doc """
  What this deployment says it pays, in cents. Absent keys mean "unpriced",
  which is a different answer from zero and is reported as `nil` throughout.
  """
  @spec rate_card() :: %{
          providers: %{optional(String.t()) => non_neg_integer()},
          basis: :active | :turn
        }
  def rate_card(basis \\ nil) do
    %{providers: provider_rates(), basis: basis || default_basis()}
  end

  @doc """
  The hours a provider rate multiplies, unless a caller overrides it.

  `:active` — every hour the sandbox was awake — unless
  `PROVIDER_COST_BASIS=turn` says this deployment's providers bill closer to
  prompt time. Anything else reads as `:active`: a misspelt env var must not
  silently halve the reported bill.
  """
  @spec default_basis() :: :active | :turn
  def default_basis do
    case Application.get_env(:fountain, :cost_basis) do
      :turn -> :turn
      "turn" -> :turn
      _ -> :active
    end
  end

  @doc "Both bases, for a surface that offers the choice."
  @spec bases() :: [:active | :turn]
  def bases, do: [:active, :turn]

  @doc """
  Whether the rate card prices anything at all.

  False on a fresh or self-hosted instance, where the panel shows hours and
  units and says out loud that it has no rates — which is the honest state,
  not an error.
  """
  @spec priced?() :: boolean()
  def priced?, do: rate_card().providers != %{}

  defp provider_rates do
    case Application.get_env(:fountain, :provider_hourly_cents) do
      map when is_map(map) -> map
      _ -> %{}
    end
  end

  ## ── the whole panel ─────────────────────────────────────────────────────

  @doc """
  Everything the finance panel renders, in one pass.

  Options:
    * `:period` — `{start, end}`, default the current calendar month. Per-user
      billing periods are deliberately not used here: the panel adds tenants
      together, and a sum over windows that each start on a different day is
      not a number anyone can hold next to a provider invoice. Each tenant's
      own invoiced window stays on their detail page.
    * `:basis` — `:active` or `:turn`, which hours the provider rates
      multiply. Defaults to `default_basis/0`. See the moduledoc: the way to
      learn which one a provider bills is to compare both against an invoice.
    * `:now` — pins the clock (tests)

  Returns `%{period_start:, period_end:, priced?:, rate_card:, revenue:,
  cost:, turn_hours:, tenants:, unattributed_cost_cents:}`. `rate_card.basis`
  says which hours were priced, so a surface can label its own number.
  """
  @spec summary(keyword()) :: map()
  def summary(opts \\ []) do
    {period_start, period_end} = Keyword.get(opts, :period) || Billing.current_month_range()
    now = Keyword.get(opts, :now) || DateTime.utc_now()

    rows = SandboxUsage.attribution(period_start, period_end, now: now)
    users = all_users()
    card = rate_card(Keyword.get(opts, :basis))
    fraction = period_fraction(period_start, period_end, now)

    usage = usage_by_user(rows)
    ledger = ledger_by_user(period_start, period_end)

    tenants =
      users
      |> Enum.map(
        &tenant_row(
          &1,
          Map.get(usage, &1.id, empty_usage()),
          Map.get(ledger, &1.id, empty_ledger()),
          card
        )
      )
      |> Enum.sort_by(&sort_key/1)

    %{
      period_start: period_start,
      period_end: period_end,
      period_fraction: fraction,
      priced?: priced?(),
      rate_card: card,
      revenue: revenue(tenants),
      cost: cost(tenants, rows, card),
      credits: credits(tenants),
      tenants: tenants,
      unattributed_cost_cents: unattributed_cost_cents(rows, card)
    }
  end

  # Biggest loss first, then biggest cost — the row an operator opened the
  # page for. An unpriced deployment has no margin to sort on and falls back
  # to sandbox hours, which is the only cost signal it has.
  defp sort_key(%{margin_cents: nil, active_hours: hours}), do: {0, -hours}
  defp sort_key(%{margin_cents: margin}), do: {-1, margin}

  ## ── revenue ─────────────────────────────────────────────────────────────

  @doc """
  Revenue is credit (ADR 0031): what was **sold** (packs, cash in — a
  liability until burned), what was **earned** (credit burned by turns and
  inference), and what comps cost (burn on comped accounts, which nobody
  paid for). There is no MRR.
  """
  @spec revenue([tenant_row()]) :: map()
  def revenue(tenants) when is_list(tenants) do
    %{
      sold_cents: tenants |> Enum.map(& &1.credit_sold_cents) |> Enum.sum(),
      earned_cents: tenants |> Enum.map(& &1.revenue_cents) |> Enum.sum(),
      comped_cents:
        tenants |> Enum.filter(& &1.comped) |> Enum.map(& &1.credit_burned_cents) |> Enum.sum()
    }
  end

  ## ── cost ────────────────────────────────────────────────────────────────

  @doc """
  Platform spend for the period: the hours behind it, and the money when the
  rate card can price them.

  `:sandbox_cents` covers every provider Fountain pays for — including the
  seconds of deleted accounts, which is why it is computed from the raw
  attribution rows rather than by adding the tenant rows up.
  """
  @spec cost([tenant_row()], [SandboxUsage.row()], map()) :: map()
  def cost(tenants, rows, card) do
    %{paid: paid, active_seconds: active, idle_seconds: idle} = platform_totals(rows)

    %{
      active_hours: SandboxUsage.hours(active),
      idle_hours: SandboxUsage.hours(idle),
      basis: card.basis,
      sandbox_cents:
        sum_or_nil(paid, &provider_cost_cents(billed_seconds(&1, card.basis), &1.provider, card)),
      # Only meaningful on the `:active` basis: on `:turn` the idle hours are
      # already outside the bill, so there is nothing for a shorter timeout to
      # remove and reporting a saving would be an invention.
      idle_cents:
        if(card.basis == :active,
          do: sum_or_nil(paid, &provider_cost_cents(&1.idle_seconds, &1.provider, card))
        ),
      # What the platform inference keys cost this period (#1388). Equal to
      # the `burn_inference` credit inside `revenue.earned_cents`, because
      # inference is sold at cost.
      inference_cents: tenants |> Enum.map(& &1.inference_cost_cents) |> Enum.sum(),
      by_provider: SandboxUsage.by_provider(rows)
    }
  end

  @doc """
  The platform-paid part of an attribution: the rows on providers Fountain
  pays for, their active and idle seconds summed, and the per-provider split
  of every row. The one fold behind both `cost/3` and
  `Billing.provider_spend/1`, so the finance page and the `/admin` tiles
  cannot disagree about what Fountain was billed for.
  """
  @spec platform_totals([SandboxUsage.row()]) :: %{
          paid: [SandboxUsage.row()],
          active_seconds: non_neg_integer(),
          idle_seconds: non_neg_integer(),
          by_provider: map()
        }
  def platform_totals(rows) when is_list(rows) do
    paid = Enum.filter(rows, &SandboxUsage.platform_cost?(&1.provider))

    %{
      paid: paid,
      active_seconds: paid |> Enum.map(& &1.active_seconds) |> Enum.sum(),
      idle_seconds: paid |> Enum.map(& &1.idle_seconds) |> Enum.sum(),
      by_provider: SandboxUsage.by_provider(rows)
    }
  end

  # The spend nobody can be charged for: sandboxes whose owner has been
  # deleted. Real money, no tenant row.
  defp unattributed_cost_cents(rows, card) do
    rows
    |> Enum.filter(&(is_nil(&1.user_id) and SandboxUsage.platform_cost?(&1.provider)))
    |> sum_or_nil(&provider_cost_cents(billed_seconds(&1, card.basis), &1.provider, card))
  end

  ## ── credits ─────────────────────────────────────────────────────────────

  @doc """
  The prepaid ledger over the period (ADR 0030): what the grants put in,
  what burned, what packs sold, and the deferred balance — the sum of every
  positive balance today, which is money already taken for work not yet
  done. Burned against granted-plus-sold is the utilisation of what tenants
  hold; a deferred balance that only grows is revenue that is not arriving.
  """
  @spec credits([tenant_row()]) :: map()
  def credits(tenants) do
    granted = tenants |> Enum.map(& &1.credit_granted_cents) |> Enum.sum()
    burned = tenants |> Enum.map(& &1.credit_burned_cents) |> Enum.sum()
    sold = tenants |> Enum.map(& &1.credit_sold_cents) |> Enum.sum()

    %{
      granted_cents: granted,
      burned_cents: burned,
      sold_cents: sold,
      deferred_cents: deferred_cents(),
      negative_balances: Enum.count(tenants, &(&1.credit_balance_cents < 0)),
      utilization: if(granted + sold > 0, do: Float.round(burned / (granted + sold), 4))
    }
  end

  @doc """
  Every positive balance, whoever holds it — a deleted account's ledger is
  gone with the account (ADR 0009), so this is what is owed today. The one
  query behind both the finance page and the `/admin` tile.
  """
  @spec deferred_cents() :: non_neg_integer()
  def deferred_cents do
    Repo.one(
      from u in User,
        where: u.credit_balance_cents > 0,
        select: coalesce(sum(u.credit_balance_cents), 0)
    )
  end

  ## ── one tenant ──────────────────────────────────────────────────────────

  defp tenant_row(user, usage, ledger, card) do
    sandbox_cost =
      sum_or_nil(
        usage.by_provider,
        &provider_cost_cents(billed_seconds(&1, card.basis), &1.provider, card)
      )

    turn_seconds = billable_turn_seconds(usage)

    # Never nil: the inference bill is read off the ledger rather than priced
    # from a rate card, so unlike the sandbox cost it is always known.
    inference_cost = ledger.inference

    cost = add_or_nil([sandbox_cost, inference_cost])

    # Earned revenue is credit burned, unless the account is comped and the
    # burn was never paid for.
    revenue_cents = if user.comped, do: 0, else: ledger.burned

    %{
      user_id: user.id,
      email: user.email,
      comped: user.comped,
      revenue_cents: revenue_cents,
      turn_hours: SandboxUsage.hours(turn_seconds),
      credit_granted_cents: ledger.granted,
      credit_burned_cents: ledger.burned,
      credit_sold_cents: ledger.sold,
      credit_balance_cents: user.credit_balance_cents,
      active_hours: SandboxUsage.hours(usage.active_seconds),
      idle_hours: SandboxUsage.hours(usage.idle_seconds),
      sandbox_cost_cents: sandbox_cost,
      inference_cost_cents: inference_cost,
      cost_cents: cost,
      margin_cents: cost && revenue_cents - cost
    }
  end

  # Turn seconds that spend a tenant's allowance: the providers Fountain pays
  # for, so a tenant's own runner (ADR 0022) is excluded, summed per turn
  # rather than the sandbox's busy union (ADR 0023 step 6). The same filter and
  # the same figure `Billing.usage_summary/3` reports and `CreditPricer` burns,
  # and it has to be the same one — the hours shown here and the hours on the
  # tenant's own billing page cannot come apart.
  defp billable_turn_seconds(usage) do
    usage.by_provider
    |> Enum.filter(&SandboxUsage.platform_cost?(&1.provider))
    |> Enum.map(& &1.turn)
    |> Enum.sum()
  end

  ## ── pricing helpers ─────────────────────────────────────────────────────

  # Which seconds a provider rate multiplies. The two row shapes in play name
  # the same two numbers differently — `SandboxUsage.row()` has
  # `active_seconds`/`busy_seconds`, the per-tenant fold has `active`/`busy` —
  # so both are read here rather than at four call sites.
  defp billed_seconds(%{active_seconds: active}, :active), do: active
  defp billed_seconds(%{busy_seconds: busy}, :turn), do: busy
  defp billed_seconds(%{active: active}, :active), do: active
  defp billed_seconds(%{busy: busy}, :turn), do: busy

  # `nil` for a provider the rate card does not name, and for one Fountain
  # does not pay at all (a tenant's own runner, ADR 0022) — but zero for the
  # runner rather than nil, because "we pay nothing for this" is a known
  # price, not a missing one.
  @doc false
  def provider_cost_cents(seconds, provider, card) do
    cond do
      not SandboxUsage.platform_cost?(provider) -> 0
      rate = Map.get(card.providers, provider) -> round(seconds / 3600 * rate)
      true -> nil
    end
  end

  # `nil` is contagious: a total missing one of its parts is not a total. It
  # must not silently become the sum of the parts that happened to be priced.
  defp add_or_nil(parts) do
    if Enum.any?(parts, &is_nil/1), do: nil, else: Enum.sum(parts)
  end

  defp sum_or_nil(items, fun) do
    items |> Enum.map(fun) |> add_or_nil()
  end

  ## ── the reads ───────────────────────────────────────────────────────────

  # Every account. Deleted accounts are gone; suspended ones still cost money,
  # so they stay.
  defp all_users do
    Repo.all(
      from u in User,
        select: %{
          id: u.id,
          email: u.email,
          comped: u.comped,
          credit_balance_cents: u.credit_balance_cents
        }
    )
  end

  # One pass over the ledger for the period: cents granted, burned and sold
  # per tenant. Expiries and clawbacks are neither — an expiry is credit that
  # was never earned, a clawback is money that went back.
  defp ledger_by_user(period_start, period_end) do
    from(e in Fountain.Credits.LedgerEntry,
      where: e.inserted_at >= ^period_start and e.inserted_at < ^period_end,
      group_by: e.user_id,
      select:
        {e.user_id,
         %{
           granted:
             fragment(
               "coalesce(sum(case when ? like 'grant_%' then ? end), 0)",
               e.reason,
               e.amount_cents
             ),
           burned:
             fragment(
               "coalesce(sum(case when ? like 'burn_%' then -? end), 0)",
               e.reason,
               e.amount_cents
             ),
           sold:
             fragment(
               "coalesce(sum(case when ? = 'purchase' then ? end), 0)",
               e.reason,
               e.amount_cents
             ),
           # Platform inference (#1388) is inside `burned` — it is credit the
           # tenant spent — and also a bill Fountain paid, so it is pulled out
           # again here as a cost. Priced pass-through at list (ADR 0038), so
           # the two cancel and inference contributes nothing to margin, which
           # is the point and is only visible because both numbers are on the
           # row.
           inference:
             fragment(
               "coalesce(sum(case when ? = 'burn_inference' then -? end), 0)",
               e.reason,
               e.amount_cents
             )
         }}
    )
    |> Repo.all()
    |> Map.new()
  end

  defp empty_ledger, do: %{granted: 0, burned: 0, sold: 0, inference: 0}

  defp empty_usage,
    do: %{active_seconds: 0, busy_seconds: 0, idle_seconds: 0, turn_seconds: 0, by_provider: []}

  @doc """
  `SandboxUsage.attribution/3` rows folded per tenant, keeping the per-provider
  split the totals were built from.

  `SandboxUsage.by_user/1` collapses to `%{provider => active_seconds}`, which
  loses both the busy/idle split and the ability to price a provider at its
  own rate. Public because `/admin`'s user table wants the same fold for the
  turn hours on each row.
  """
  @spec usage_by_user([SandboxUsage.row()]) :: %{optional(binary()) => map()}
  def usage_by_user(rows) when is_list(rows) do
    rows
    |> Enum.reject(&is_nil(&1.user_id))
    |> Enum.group_by(& &1.user_id)
    |> Map.new(fn {user_id, group} ->
      {user_id,
       %{
         active_seconds: group |> Enum.map(& &1.active_seconds) |> Enum.sum(),
         busy_seconds: group |> Enum.map(& &1.busy_seconds) |> Enum.sum(),
         idle_seconds: group |> Enum.map(& &1.idle_seconds) |> Enum.sum(),
         turn_seconds: group |> Enum.map(& &1.turn_seconds) |> Enum.sum(),
         by_provider:
           Enum.map(
             group,
             &%{
               provider: &1.provider,
               active: &1.active_seconds,
               busy: &1.busy_seconds,
               idle: &1.idle_seconds,
               turn: &1.turn_seconds
             }
           )
       }}
    end)
  end

  @doc """
  How much of the period has actually elapsed, `0.0..1.0`.

  Recurring monthly charges are pro-rated by this so a panel opened on the 3rd
  reports three days of AgentMail rather than a month of it, and so the cost
  column can be read against sandbox hours, which are only ever accrued
  hours. A period entirely in the past is `1.0`.
  """
  @spec period_fraction(DateTime.t(), DateTime.t(), DateTime.t()) :: float()
  def period_fraction(period_start, period_end, now) do
    total = DateTime.diff(period_end, period_start, :second)
    elapsed = DateTime.diff(now, period_start, :second)

    cond do
      total <= 0 -> 1.0
      elapsed >= total -> 1.0
      elapsed <= 0 -> 0.0
      true -> elapsed / total
    end
  end
end
