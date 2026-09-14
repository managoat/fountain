defmodule FountainWeb.Live.AdminFinanceLive do
  @moduledoc """
  `/admin/finance` — what Fountain is paid, what Fountain pays, and the gap,
  per tenant.

  `/admin` had both halves and never put them together: a deferred-credit
  tile with no cost beside it, and a sandbox-hours table with no money in it. Neither could
  answer the only question an operator actually asks a finance page, which is
  which accounts cost more than they bring in.

  Three things this page is careful about, because each has a way of lying:

    * **It shows no money it was not told.** The rate card
      (`Fountain.Billing.Finance.rate_card/0`) is config, and an unpriced line
      renders as `—`, never as `$0.00`. A deployment that has set nothing sees
      hours — a complete report in the units it does know.
    * **It does not assume which hours the provider bills.** Cost prices either
      every hour a sandbox was awake or only the hours with a prompt in
      flight, and the toggle switches between them. Which one is right is a
      fact about the provider's invoice rather than about this codebase, so
      the page offers both and labels the one it is on. Active hours and turn
      hours sit on every row either way, because the gap between them is idle
      time and that is the lever on the bill.
    * **The window is one calendar month for everybody.** That is the window
      a provider invoice covers, so a total over it is a number that can be
      held next to one.

  Read-only. Every lever stays on `/admin` next to its confirmation.
  """

  use FountainWeb, :live_view

  import FountainWeb.AdminLive.Helpers
  import FountainWeb.AdminLive.Shell

  alias Fountain.Billing
  alias Fountain.Billing.Finance
  alias Fountain.Billing.Reconciliation
  alias Fountain.Billing.SandboxUsage

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Process.send_after(self(), :refresh, 30_000)

    {:ok,
     socket
     |> assign(:page_title, "Admin · Finance")
     |> assign(:credits_enabled, Fountain.Credits.enabled?())
     |> assign(:months_ago, 0)
     |> assign(:basis, Finance.default_basis())
     |> assign_finance()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    months_ago =
      case params["months_ago"] do
        raw when is_binary(raw) ->
          case Integer.parse(raw) do
            {n, ""} when n >= 0 and n <= 11 -> n
            _ -> 0
          end

        _ ->
          0
      end

    {:noreply,
     socket
     |> assign(:months_ago, months_ago)
     |> assign(:basis, parse_basis(params["basis"]))
     |> assign_finance()}
  end

  # Both names are honoured, because the toggle emits both: a link reading
  # "active hours" has to select active even where the deployment default is
  # turn. Anything else falls back to the default rather than to `:active`, so
  # a mistyped URL does not quietly show a self-hoster the wrong basis.
  defp parse_basis("turn"), do: :turn
  defp parse_basis("active"), do: :active
  defp parse_basis(_), do: Finance.default_basis()

  @impl true
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, 30_000)
    {:noreply, assign_finance(socket)}
  end

  # Heavier than the /admin refresh (a full attribution pass plus four grouped
  # queries), so it runs on 30s rather than 10s, and a closed month is not
  # recomputed at all — nothing in it can change.
  defp assign_finance(socket) do
    {period_start, _} = month_range(socket.assigns.months_ago)

    finance =
      Finance.summary(
        period: month_range(socket.assigns.months_ago),
        basis: socket.assigns.basis
      )

    invoices = Reconciliation.invoices_for(DateTime.to_date(period_start))

    socket
    |> assign(:finance, finance)
    |> assign(:invoice_lines, Reconciliation.lines(finance, invoices))
    |> assign(:dropped, Reconciliation.dropped_on_this_node())
  end

  # An invoice is typed in dollars and stored in cents; the month is the one
  # the page is showing, so a closed month's bill lands on that month.
  @impl true
  def handle_event(
        "record_invoice",
        %{"provider" => provider, "amount" => amount} = params,
        socket
      ) do
    {period_start, period_end} = month_range(socket.assigns.months_ago)

    with {:ok, cents} <- parse_dollars(amount),
         {:ok, _} <-
           Reconciliation.record_invoice(
             %{
               "provider" => provider,
               "period_start" => DateTime.to_date(period_start),
               "period_end" => period_end |> DateTime.add(-1, :second) |> DateTime.to_date(),
               "amount_cents" => cents,
               "note" => params["note"]
             },
             FountainWeb.Audited.attribution(socket)
           ) do
      {:noreply,
       socket
       |> put_flash(:info, "Recorded #{provider}'s invoice for the month.")
       |> assign_finance()}
    else
      _ ->
        {:noreply, put_flash(socket, :error, "Enter the invoice total in dollars, like 123.45.")}
    end
  end

  defp parse_dollars(raw) when is_binary(raw) do
    case Float.parse(String.trim(String.replace(raw, ["$", ","], ""))) do
      {dollars, ""} when dollars >= 0 -> {:ok, round(dollars * 100)}
      _ -> :error
    end
  end

  # `months_ago` back from the current month, as a whole half-open UTC month
  # (`Billing.month_range/1`). Zero is the running month, the only one moving.
  defp month_range(months_ago) do
    %{start: period_start, end: period_end} = Billing.month_range(months_ago)
    {period_start, period_end}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-8">
      <div>
        <.admin_header title="Finance" current={:finance} credits_enabled={@credits_enabled}>
          <:subtitle>
            Revenue against platform spend, per tenant, for {Calendar.strftime(
              @finance.period_start,
              "%B %Y"
            )}. {if @months_ago == 0,
              do: "The month so far; refreshes every 30s.",
              else: "A closed month."}
          </:subtitle>
        </.admin_header>
        <div class="flex flex-wrap gap-2 mt-3">
          <.link
            :for={n <- 0..5}
            patch={~p"/admin/finance?months_ago=#{n}&basis=#{@basis}"}
            class={[
              "rounded border px-2 py-1 text-xs",
              if(@months_ago == n,
                do: "bg-zinc-900 text-white border-zinc-900",
                else: "bg-white text-zinc-600 border-zinc-200 hover:border-zinc-400"
              )
            ]}
          >
            {month_label(n)}
          </.link>
        </div>
        <%!-- Which hours a provider rate multiplies is a fact about their
              invoice, and the only way to settle it is to try both and see
              which total lands. So it is a toggle, not a constant. --%>
        <div class="flex flex-wrap items-center gap-2 mt-2 text-xs">
          <span class="text-zinc-500">Charge sandbox hours as</span>
          <.link
            :for={b <- Finance.bases()}
            patch={~p"/admin/finance?months_ago=#{@months_ago}&basis=#{b}"}
            class={[
              "rounded border px-2 py-1",
              if(@basis == b,
                do: "bg-zinc-900 text-white border-zinc-900",
                else: "bg-white text-zinc-600 border-zinc-200 hover:border-zinc-400"
              )
            ]}
          >
            {basis_label(b)}
          </.link>
        </div>
      </div>

      <%!-- The whole page's honesty depends on this being visible when it
            applies: without a rate card the cost columns are hours and units,
            not dollars, and a reader who assumes otherwise reads every `—` as
            a zero. --%>
      <div
        :if={not @finance.priced?}
        class="bg-amber-50 border border-amber-200 rounded px-4 py-3 text-sm text-amber-900 space-y-1"
      >
        <div class="font-medium">No rate card is configured, so there is no cost in dollars.</div>
        <div class="text-xs">
          The hours below are real. Set <code>PROVIDER_HOURLY_CENTS</code> to price them.
          An unpriced line stays <code>—</code>; it never becomes $0.
        </div>
      </div>

      <%!-- ── The three numbers, and the one that matters ── --%>
      <section class="grid grid-cols-2 lg:grid-cols-4 gap-3">
        <div class="bg-white rounded shadow border border-zinc-200 px-4 py-3">
          <div class="text-xs text-zinc-500">Credit earned</div>
          <div class="text-2xl font-semibold tabular-nums">
            {money(@finance.revenue.earned_cents)}
          </div>
          <div class="text-xs text-zinc-500">
            burned this period, at the customer price
          </div>
        </div>
        <div class="bg-white rounded shadow border border-zinc-200 px-4 py-3">
          <div class="text-xs text-zinc-500">Platform cost</div>
          <div class="text-2xl font-semibold tabular-nums">{money(total_cost(@finance))}</div>
          <div class="text-xs text-zinc-500">
            sandboxes · inference
          </div>
        </div>
        <div class="bg-white rounded shadow border border-zinc-200 px-4 py-3">
          <div class="text-xs text-zinc-500">Gross margin</div>
          <div class={[
            "text-2xl font-semibold tabular-nums",
            negative?(gross_margin(@finance)) && "text-red-700"
          ]}>
            {money(gross_margin(@finance))}
          </div>
          <div class="text-xs text-zinc-500">
            {margin_pct(@finance) || "no rate card"}
          </div>
        </div>
        <div class="bg-white rounded shadow border border-zinc-200 px-4 py-3">
          <div class="text-xs text-zinc-500">Credits burned / granted + sold</div>
          <div class="text-2xl font-semibold tabular-nums">
            {money(@finance.credits.burned_cents)}
            <span class="text-base text-zinc-400">
              / {money(@finance.credits.granted_cents + @finance.credits.sold_cents)}
            </span>
          </div>
          <div class="text-xs text-zinc-500">
            {if @finance.credits.utilization,
              do: "#{round(@finance.credits.utilization * 100)}% of what tenants hold",
              else: "nothing granted or sold"} · {money(@finance.credits.deferred_cents)} deferred
            <span :if={@finance.credits.negative_balances > 0} class="text-amber-700">
              · {@finance.credits.negative_balances} below zero
            </span>
          </div>
        </div>
      </section>

      <%!-- ── Revenue: credit (ADR 0031) ── --%>
      <section :if={@credits_enabled} class="space-y-3">
        <h2 class="text-lg font-medium">Revenue</h2>
        <div class="grid grid-cols-2 lg:grid-cols-3 gap-3">
          <div class="bg-white rounded shadow border border-zinc-200 px-4 py-3">
            <div class="text-xs text-zinc-500">Credit earned</div>
            <div class="text-xl font-semibold tabular-nums">
              {money(@finance.revenue.earned_cents)}
            </div>
            <div class="text-xs text-zinc-500">burned by paying accounts this period</div>
          </div>
          <div class="bg-white rounded shadow border border-zinc-200 px-4 py-3">
            <div class="text-xs text-zinc-500">Credit sold</div>
            <div class="text-xl font-semibold tabular-nums">
              {money(@finance.revenue.sold_cents)}
            </div>
            <div class="text-xs text-zinc-500">packs bought this period; deferred until burned</div>
          </div>
          <div class="bg-white rounded shadow border border-zinc-200 px-4 py-3">
            <div class="text-xs text-zinc-500">Comped burn</div>
            <div class="text-xl font-semibold tabular-nums">
              {money(@finance.revenue.comped_cents)}
            </div>
            <div class="text-xs text-zinc-500">what free accounts used, at the customer price</div>
          </div>
        </div>
      </section>

      <section class="space-y-3">
        <h2 class="text-lg font-medium">Cost</h2>
        <div class="grid grid-cols-2 gap-3">
          <div class="bg-white rounded shadow border border-zinc-200 px-4 py-3">
            <div class="text-xs text-zinc-500">Sandboxes</div>
            <div class="text-xl font-semibold tabular-nums">
              {money(@finance.cost.sandbox_cents)}
            </div>
            <div class="text-xs text-zinc-500 tabular-nums">
              {format_hours(billed_hours(@finance))} {basis_label(@basis)}, on providers we pay
            </div>
            <div
              :if={@basis == :active and @finance.cost.idle_hours > 0}
              class="text-xs tabular-nums text-amber-700"
            >
              {format_hours(@finance.cost.idle_hours)} of it idle
              <span :if={@finance.cost.idle_cents}>
                — {money(@finance.cost.idle_cents)} a shorter timeout would remove
              </span>
            </div>
            <div :if={@basis == :turn} class="text-xs text-zinc-400 tabular-nums">
              {format_hours(@finance.cost.active_hours)} awake in total; the idle part is charged
              at nothing on this basis
            </div>
          </div>
          <div class="bg-white rounded shadow border border-zinc-200 px-4 py-3">
            <div class="text-xs text-zinc-500">Platform inference</div>
            <div class="text-xl font-semibold tabular-nums">
              {money(@finance.cost.inference_cents)}
            </div>
            <div class="text-xs text-zinc-500">
              tokens on Fountain's own keys, for tenants with none of their own
            </div>
            <div class="text-xs text-zinc-400">
              sold at provider list price, so this is earned revenue too and nets to zero margin
            </div>
          </div>
        </div>

        <div :if={@finance.cost.by_provider != %{}} class="grid grid-cols-2 sm:grid-cols-4 gap-3">
          <div
            :for={{provider, totals} <- Enum.sort(@finance.cost.by_provider)}
            class="bg-white rounded shadow border border-zinc-200 px-4 py-3"
          >
            <div class="text-xs text-zinc-500">{provider}</div>
            <div class="text-lg font-semibold tabular-nums">
              {format_hours(SandboxUsage.hours(totals.active_seconds))}
            </div>
            <div class="text-xs text-zinc-500 tabular-nums">
              {rate_label(@finance.rate_card, provider)}
            </div>
            <div :if={not SandboxUsage.platform_cost?(provider)} class="text-xs text-zinc-400">
              tenant hardware, not our bill
            </div>
          </div>
        </div>

        <div :if={@finance.unattributed_cost_cents not in [nil, 0]} class="text-xs text-zinc-500">
          {money(@finance.unattributed_cost_cents)} of that belongs to deleted accounts and is in
          no tenant row below — spend nobody can be charged for.
        </div>
      </section>

      <%!-- ── Computed against invoiced (#1038) ── --%>
      <section class="space-y-3" id="reconciliation">
        <h2 class="text-lg font-medium">Provider invoices</h2>
        <p class="text-xs text-zinc-500">
          The computed cost is a model with an unknown error until a real invoice sits beside it.
          Record each provider's bill for this month; the delta is invoiced minus computed, so a
          positive number means the model under-reports.
        </p>
        <div
          :if={@dropped > 0}
          class="bg-amber-50 border border-amber-200 rounded px-4 py-2 text-xs text-amber-900"
        >
          {@dropped} metering {pluralize(@dropped, "event", "events")} dropped on this node since it
          booted. The figures for any period that overlaps are approximate.
        </div>
        <table class="w-full text-sm bg-white rounded shadow border border-zinc-200">
          <thead class="text-left text-xs text-zinc-500">
            <tr>
              <th class="px-3 py-2 font-normal">Provider</th>
              <th class="px-3 py-2 font-normal text-right">Computed</th>
              <th class="px-3 py-2 font-normal text-right">Invoiced</th>
              <th class="px-3 py-2 font-normal text-right">Delta</th>
              <th class="px-3 py-2 font-normal">Note</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={line <- @invoice_lines} class="border-t border-zinc-100">
              <td class="px-3 py-2">{line.provider}</td>
              <td class="px-3 py-2 text-right tabular-nums">{money(line.computed_cents)}</td>
              <td class="px-3 py-2 text-right tabular-nums">{money(line.recorded_cents)}</td>
              <td class={[
                "px-3 py-2 text-right tabular-nums",
                line.delta_cents && line.delta_cents != 0 && "text-amber-700"
              ]}>
                {money(line.delta_cents)}
              </td>
              <td class="px-3 py-2 text-xs text-zinc-500">{line.note}</td>
            </tr>
          </tbody>
        </table>
        <form phx-submit="record_invoice" class="flex flex-wrap items-end gap-2 text-sm">
          <label class="flex flex-col text-xs text-zinc-500">
            Provider
            <select
              name="provider"
              class="rounded border border-zinc-300 px-2 py-1 text-sm text-zinc-900"
            >
              <option :for={p <- Fountain.Billing.ProviderInvoice.providers()} value={p}>{p}</option>
            </select>
          </label>
          <label class="flex flex-col text-xs text-zinc-500">
            Invoice total ($)
            <input
              name="amount"
              type="text"
              inputmode="decimal"
              placeholder="123.45"
              class="rounded border border-zinc-300 px-2 py-1 text-sm text-zinc-900 w-28"
            />
          </label>
          <label class="flex flex-col text-xs text-zinc-500">
            Note
            <input
              name="note"
              type="text"
              placeholder="invoice number"
              class="rounded border border-zinc-300 px-2 py-1 text-sm text-zinc-900 w-48"
            />
          </label>
          <button type="submit" class="rounded bg-zinc-900 px-3 py-1.5 text-xs font-medium text-white">
            Record for {Calendar.strftime(@finance.period_start, "%B")}
          </button>
        </form>
      </section>

      <%!-- ── The row that matters ── --%>
      <section class="space-y-3">
        <h2 class="text-lg font-medium">Per tenant ({length(@finance.tenants)})</h2>
        <p class="text-xs text-zinc-500">
          Worst margin first. <strong>Active hours</strong>
          is what a provider charges for; <strong>turn hours</strong>
          is the part with a prompt in flight, which is what burns credit. The gap is idle time.
        </p>
        <div class="overflow-x-auto">
          <table class="w-full text-sm bg-white rounded shadow border border-zinc-200">
            <thead class="text-left text-zinc-500 border-b border-zinc-200">
              <tr>
                <th class="px-3 py-2">Account</th>
                <th class="px-3 py-2 text-right">Balance</th>
                <th class="px-3 py-2 text-right">Revenue</th>
                <th class="px-3 py-2 text-right" title="Turn hours with a prompt in flight">
                  Turn h
                </th>
                <th
                  class="px-3 py-2 text-right"
                  title="Credit burned this period, and the balance held now"
                >
                  Credits
                </th>
                <th
                  class="px-3 py-2 text-right"
                  title="Active sandbox hours — what providers charge for"
                >
                  Active h
                </th>
                <th class="px-3 py-2 text-right">Cost</th>
                <th class="px-3 py-2 text-right">Margin</th>
              </tr>
            </thead>
            <tbody>
              <tr :if={@finance.tenants == []}>
                <td colspan="8" class="px-3 py-6 text-center text-sm text-zinc-500">No accounts.</td>
              </tr>
              <tr
                :for={t <- @finance.tenants}
                class="border-b border-zinc-100 last:border-0 hover:bg-zinc-50"
              >
                <td class="px-3 py-2 font-mono text-xs">
                  <.link navigate={~p"/admin/users/#{t.user_id}"} class="hover:underline">
                    {t.email}
                  </.link>
                  <span
                    :if={t.comped}
                    class={[
                      "ml-1 inline-flex items-center rounded px-1.5 py-0.5 text-xs font-medium border",
                      account_badge_class(true)
                    ]}
                  >
                    comped
                  </span>
                </td>
                <td class={[
                  "px-3 py-2 text-right tabular-nums text-xs",
                  t.credit_balance_cents < 0 && "text-amber-700"
                ]}>
                  {money(t.credit_balance_cents)}
                </td>
                <td class="px-3 py-2 text-right tabular-nums text-xs">
                  {money(t.revenue_cents)}
                </td>
                <td class="px-3 py-2 text-right tabular-nums text-xs">
                  {Float.round(t.turn_hours, 1)}
                </td>
                <td class={[
                  "px-3 py-2 text-right tabular-nums text-xs",
                  t.credit_balance_cents < 0 && "text-amber-700 font-medium"
                ]}>
                  {money(t.credit_burned_cents)}
                  <div class="text-zinc-400">{money(t.credit_balance_cents)} held</div>
                </td>
                <td class="px-3 py-2 text-right tabular-nums text-xs">
                  {Float.round(t.active_hours, 1)}
                  <div :if={t.idle_hours > 0} class="text-zinc-400">
                    {Float.round(t.idle_hours, 1)} idle
                  </div>
                </td>
                <td class="px-3 py-2 text-right tabular-nums text-xs" title={cost_breakdown(t)}>
                  {money(t.cost_cents)}
                </td>
                <td class={[
                  "px-3 py-2 text-right tabular-nums text-xs font-medium",
                  negative?(t.margin_cents) && "text-red-700"
                ]}>
                  {money(t.margin_cents)}
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>
    </div>
    """
  end

  ## ── formatting ────────────────────────────────────────────────────────────

  # `nil` is "we were not told", and it must not render as a number. Every
  # money cell on this page goes through here for that reason.
  defp money(nil), do: "—"

  # Rates are fractional cents (#1029) and a cost total is whole ones. Every
  # cost path rounds before it gets here, but a float reaching this function
  # must round rather than raise: a 500 on the finance page is a worse answer
  # than a cent of rounding, and that is exactly what shipped — `rate_label/2`
  # handed `money/1` a raw `10.76` and took the whole page down the moment a
  # rate card was configured.
  defp money(cents) when is_float(cents), do: money(round(cents))

  defp money(cents) when is_integer(cents) do
    sign = if cents < 0, do: "-", else: ""
    abs = abs(cents)
    "#{sign}$#{div(abs, 100)}.#{String.pad_leading(to_string(rem(abs, 100)), 2, "0")}"
  end

  defp negative?(cents), do: is_integer(cents) and cents < 0

  defp total_cost(%{cost: cost}) do
    [cost.sandbox_cents, cost.inference_cents]
    |> then(fn parts -> if Enum.any?(parts, &is_nil/1), do: nil, else: Enum.sum(parts) end)
  end

  defp gross_margin(finance) do
    case total_cost(finance) do
      nil -> nil
      cost -> finance.revenue.earned_cents - cost
    end
  end

  defp margin_pct(finance) do
    earned = finance.revenue.earned_cents

    case gross_margin(finance) do
      nil -> nil
      _ when earned <= 0 -> "no revenue to divide"
      margin -> "#{round(margin / earned * 100)}% of credit earned"
    end
  end

  # A rate is not a total, and rounding it to whole cents throws away the part
  # that matters: 10.76c/hr and 5.45c/hr both render as "$0.11" and "$0.05"
  # once, and as the same "$0.05" for anything between 4.5 and 5.5. Rates are
  # shown in cents, with their fraction.
  defp rate_label(card, provider) do
    cond do
      not SandboxUsage.platform_cost?(provider) -> "no cost to us"
      rate = Map.get(card.providers, provider) -> "#{trim_zeros(rate)}c/hour"
      true -> "no rate configured"
    end
  end

  # `10.76` renders as "10.76", `2.0` as "2" — a whole rate should not grow a
  # decimal point just because the config parser returns a float.
  defp trim_zeros(rate) when is_integer(rate), do: Integer.to_string(rate)

  defp trim_zeros(rate) when is_float(rate) do
    if rate == Float.round(rate), do: Integer.to_string(trunc(rate)), else: to_string(rate)
  end

  defp cost_breakdown(t) do
    "sandboxes #{money(t.sandbox_cost_cents)} · inference #{money(t.inference_cost_cents)}"
  end

  defp pluralize(1, singular, _plural), do: singular
  defp pluralize(_n, _singular, plural), do: plural

  defp basis_label(:active), do: "active hours"
  defp basis_label(:turn), do: "turn hours"

  # The hours the reported cost was actually computed from, so the tile's
  # subtitle cannot claim one basis while its number came from the other.
  defp billed_hours(%{cost: cost, tenants: tenants}) do
    case cost.basis do
      :turn -> tenants |> Enum.map(& &1.turn_hours) |> Enum.sum() |> Float.round(2)
      :active -> cost.active_hours
    end
  end

  defp month_label(0), do: "This month"
  defp month_label(1), do: "Last month"
  defp month_label(n), do: "#{n} months ago"
end
