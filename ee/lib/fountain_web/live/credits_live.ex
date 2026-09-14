defmodule FountainWeb.Live.CreditsLive do
  @moduledoc """
  `/account/billing` — the credit balance, what of it expires and when, the
  ledger, this month's usage, and the buttons that open Stripe Checkout for
  a credit pack.

  Accessible to every authenticated user whatever the balance, so an account
  at zero can buy its way back.

  Purely billing since #479: data export and account deletion live on the
  core `/account` page. On a billing-disabled instance this page does not
  exist — old bookmarks redirect to `/account`.
  """

  use FountainWeb, :live_view

  alias Fountain.Billing
  alias Fountain.Credits

  @impl true
  def mount(_params, _session, socket) do
    if Credits.enabled?() do
      user = socket.assigns.current_user
      period = Billing.month_range()

      {:ok,
       assign(socket,
         page_title: "Billing",
         usage: Billing.usage_summary(user.id, period.start, period.end),
         period: period,
         credits: Credits.summary(user),
         ledger: Credits.list_entries(user.id, limit: 10),
         sandbox_cap: Fountain.Quotas.sandbox_limit_for(user),
         stripe_url_loading: false
       )}
    else
      {:ok, redirect(socket, to: ~p"/account")}
    end
  end

  @impl true
  def handle_event("buy_credits", %{"cents" => cents}, socket) do
    user = socket.assigns.current_user
    socket = assign(socket, :stripe_url_loading, true)

    with {cents, ""} <- Integer.parse(to_string(cents)),
         {:ok, url} <- Credits.Purchases.checkout_url(user, cents, billing_return_url()) do
      {:noreply, redirect(socket, external: url)}
    else
      {:error, :comped} ->
        {:noreply,
         socket
         |> assign(:stripe_url_loading, false)
         |> put_flash(:info, "This account is comped — there is nothing to buy.")}

      _ ->
        {:noreply,
         socket
         |> assign(:stripe_url_loading, false)
         |> put_flash(:error, "Unable to reach Stripe. Please try again.")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-2xl space-y-8 px-4 py-8">
      <h1 class="text-2xl font-semibold">Billing</h1>

      <%!-- Concurrency: what the balance funds (ADR 0031). --%>
      <p class="text-sm text-gray-500">
        You can run <span class="font-semibold text-gray-900">{@sandbox_cap}</span>
        agents at once.
        The cap follows your balance: one more sandbox for every {Credits.format_cents(
          Fountain.Quotas.settings().reserve_cents
        )} you hold, up to {Fountain.Quotas.settings().cap_ceiling}.
      </p>

      <%!-- Prepaid credits (ADR 0030, 0031): the balance, and the packs that
            top it up. At zero, new work is refused until it is positive. --%>
      <div :if={@credits.active?} class="rounded-lg border bg-white p-6 shadow-sm" id="credits">
        <div class="flex items-baseline justify-between">
          <h2 class="text-lg font-medium">Credits</h2>
          <p class="text-sm tabular-nums">
            <span class={[
              "font-semibold",
              @credits.balance_cents < 0 && "text-amber-700"
            ]}>
              {Credits.format_cents(@credits.balance_cents)}
            </span>
            <span class="text-gray-500">remaining</span>
          </p>
        </div>
        <p class="mt-3 text-xs text-gray-500">
          Conversation time costs {Credits.format_cents(@credits.price_card.turn_hour)} per turn hour
          and comes out of this balance. Credit you buy never expires; the opening credit
          expires on its date.
        </p>
        <p :if={@credits.expires_at} class="mt-2 text-xs text-gray-500">
          {Credits.format_cents(@credits.expiring_cents)} of this expires on {Calendar.strftime(
            @credits.expires_at,
            "%b %-d"
          )}.
          <span :if={@credits.purchased_cents > 0}>
            {Credits.format_cents(@credits.purchased_cents)} is money you bought and keeps.
          </span>
        </p>
        <p :if={@credits.balance_cents < 0} class="mt-2 text-xs text-amber-700">
          Your balance is below zero. New conversations and new turns are paused until it
          is positive again; anything already running finishes. Buying credit brings it back up.
        </p>
        <div :if={not @current_user.comped} class="mt-4 flex flex-wrap items-center gap-2">
          <button
            :for={cents <- Credits.packs()}
            phx-click="buy_credits"
            phx-value-cents={cents}
            disabled={@stripe_url_loading}
            class="rounded-md border border-indigo-600 px-3 py-1.5 text-sm font-medium text-indigo-700 hover:bg-indigo-50 disabled:cursor-not-allowed disabled:opacity-50"
          >
            Buy {Credits.format_cents(cents)}
          </button>
          <span class="text-xs text-gray-500">One-time payment. Never expires.</span>
        </div>
        <p :if={@current_user.comped} class="mt-4 text-xs text-gray-500">
          This account is comped: nothing is refused, whatever the balance says.
        </p>
        <table :if={@ledger != []} class="mt-4 w-full text-xs">
          <thead class="text-left text-gray-500">
            <tr>
              <th class="py-1 font-normal">When</th>
              <th class="py-1 font-normal">What</th>
              <th class="py-1 text-right font-normal">Amount</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={entry <- @ledger} class="border-t">
              <td class="py-1 tabular-nums text-gray-500">
                {Calendar.strftime(entry.inserted_at, "%b %-d")}
              </td>
              <td class="py-1">{ledger_label(entry)}</td>
              <td class={[
                "py-1 text-right tabular-nums",
                entry.amount_cents < 0 && "text-gray-500"
              ]}>
                {Credits.format_cents(entry.amount_cents)}
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <%!-- Usage over the billing period --%>
      <div class="rounded-lg border bg-white p-6 shadow-sm">
        <h2 class="mb-1 text-lg font-medium">Usage this period</h2>
        <p class="mb-4 text-xs text-gray-400">
          {Calendar.strftime(@period.start, "%b %-d")} – {Calendar.strftime(
            DateTime.add(@period.end, -1, :second),
            "%b %-d, %Y"
          )}
        </p>
        <dl class="grid grid-cols-4 gap-4">
          <div class="rounded-md bg-gray-50 p-4 text-center">
            <dt class="text-xs text-gray-500">Spent</dt>
            <dd class="mt-1 text-2xl font-semibold">
              {Credits.format_cents(@usage.credit_burned_cents)}
            </dd>
          </div>
          <div class="rounded-md bg-gray-50 p-4 text-center">
            <dt class="text-xs text-gray-500">Conversations</dt>
            <dd class="mt-1 text-2xl font-semibold">{@usage.conversations}</dd>
          </div>
          <div class="rounded-md bg-gray-50 p-4 text-center">
            <dt class="text-xs text-gray-500">Turns</dt>
            <dd class="mt-1 text-2xl font-semibold">{@usage.turns}</dd>
          </div>
          <div class="rounded-md bg-gray-50 p-4 text-center">
            <dt class="text-xs text-gray-500">Sandbox-min</dt>
            <dd class="mt-1 text-2xl font-semibold">{format_minutes(@usage.sandbox_minutes)}</dd>
          </div>
        </dl>
        <p :if={@usage.sandbox_minutes_by_provider != %{}} class="mt-3 text-xs text-gray-500">
          Sandbox minutes by provider
          <span
            :for={{provider, minutes} <- Enum.sort(@usage.sandbox_minutes_by_provider)}
            class="ml-2 inline-block rounded bg-gray-100 px-1.5 py-0.5 tabular-nums"
          >
            <span class="font-medium text-gray-700">{provider}</span> {format_minutes(minutes)}
          </span>
        </p>
      </div>
    </div>
    """
  end

  # ─── Private helpers ───────────────────────────────────────────────────────────

  # Refused outright rather than relying on the button being hidden (#399):
  # a stale socket or a hand-sent event must not open Checkout for a comped
  # account, which has nothing to pay for.
  # Both surfaces mint the same URLs under the same rules, so the rules live in
  # the context (#524) rather than in a copy per surface.
  defp billing_return_url, do: FountainWeb.Endpoint.url() <> ~p"/account/billing"

  defp format_minutes(minutes) do
    minutes
    |> Float.round(1)
    |> to_string()
  end

  defp ledger_label(%{reason: "grant_opening"}), do: "Opening credit"
  defp ledger_label(%{reason: "grant_admin"}), do: "Credit from Fountain"
  defp ledger_label(%{reason: "purchase"}), do: "Purchase"

  defp ledger_label(%{reason: "burn_turn", metadata: %{"turn_seconds" => s}}),
    do: "Conversation time, #{format_seconds(s)}"

  defp ledger_label(%{reason: "burn_turn"}), do: "Conversation time"

  # A platform-inference burn (#1388). The model is on the row because it is
  # what the price came from, and because "Fountain's key" is the answer to
  # the question this line raises: why am I paying for tokens? A tenant who
  # adds their own credential stops seeing these.
  defp ledger_label(%{reason: "burn_inference", metadata: %{"model" => model}})
       when is_binary(model),
       do: "Inference on Fountain's key, #{model}"

  defp ledger_label(%{reason: "burn_inference"}), do: "Inference on Fountain's key"
  # Rows from before Team comms was retired (#2143); nothing writes them now.
  defp ledger_label(%{reason: "burn_rent"}), do: "Number or inbox, one month"
  defp ledger_label(%{reason: "burn_message"}), do: "Message"
  defp ledger_label(%{reason: "expire"}), do: "Expired with the period"
  defp ledger_label(%{reason: "clawback_" <> _}), do: "Refund reversed"
  defp ledger_label(%{reason: reason}), do: reason

  defp format_seconds(s) when is_integer(s) and s < 60, do: "#{s}s"
  defp format_seconds(s) when is_integer(s) and s < 3600, do: "#{div(s, 60)}m"
  defp format_seconds(s) when is_integer(s), do: "#{Float.round(s / 3600, 1)}h"
end
