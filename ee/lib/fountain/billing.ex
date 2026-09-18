defmodule Fountain.Billing do
  @moduledoc """
  The money side that is not the ledger: the Stripe customer and webhooks,
  usage summaries, provider spend and the admin overview. The name stays
  (#1144) — this is billing in the sense of "what Fountain is billed and
  reports", not the retired subscription; the switch, the gate and the
  customer-facing surfaces are `Fountain.Credits` and `Credits*`.

  Billing context (ADR 0031): the credit gate, the Stripe till, and usage
  aggregation.

  Credits are the product. What lives here is what is not the ledger itself
  (`Fountain.Credits`): `enabled?/0`, `check_spend/1` (the gate every spend
  passes), the Stripe customer and webhook plumbing that sells packs and
  claws them back, the comp lever, and the usage summaries the surfaces
  render.
  """

  import Ecto.Query

  require Logger

  alias Fountain.Accounts.User
  alias Fountain.Audit
  alias Fountain.Billing.Finance
  alias Fountain.Billing.SandboxUsage
  alias Fountain.Billing.UsageEvent
  alias Fountain.Repo

  @doc """
  The gate every spend passes (ADR 0031): the balance. `:ok` when billing is
  off, the account is comped, or the balance is positive; in-flight turns
  finish (ADR 0030 decision 6).
  """
  @spec check_spend(User.t() | binary()) :: :ok | {:error, :insufficient_credits}
  def check_spend(subject), do: Fountain.Credits.gate(subject)

  @doc """
  What this deployment's platform inference keys have cost today, in cents,
  across every tenant — the number `Fountain.PlatformInference` holds against
  `PLATFORM_INFERENCE_DAILY_CENTS` (#1388).

  `nil` with credits off: nothing is priced then (ADR 0031), so there is no
  spend to report and "zero" would be a claim rather than an answer.

  A UTC day, deliberately, and not each tenant's billing window: the ceiling
  is a property of the deployment's own bill, and a sum over windows that
  each start on a different day is not a number to bound anything with — the
  same reasoning `Finance.summary/1` gives for the calendar month.
  """
  @spec platform_inference_spend_today(DateTime.t() | nil) :: non_neg_integer() | nil
  def platform_inference_spend_today(now \\ nil) do
    if Fountain.Credits.enabled?() do
      now = now || DateTime.utc_now()
      day_start = now |> DateTime.to_date() |> DateTime.new!(~T[00:00:00], "Etc/UTC")

      Repo.one(
        from e in Fountain.Credits.LedgerEntry,
          where: e.reason == "burn_inference" and e.inserted_at >= ^day_start,
          select: coalesce(sum(-e.amount_cents), 0)
      )
    end
  end

  @doc """
  Creates a Stripe Customer for the given user and stores its id.

  Customer only: a customer is what Checkout attaches a credit-pack payment
  to, and what a refund or dispute is traced back through. Nothing is
  subscribed and nothing is charged here (ADR 0031).
  """
  @spec create_stripe_customer(User.t()) :: {:ok, User.t()} | {:error, term()}
  def create_stripe_customer(%User{} = user) do
    with {:ok, %Stripe.Customer{id: customer_id}} <-
           Stripe.Customer.create(%{email: user.email, metadata: %{"user_id" => user.id}}) do
      user
      |> User.billing_changeset(%{stripe_customer_id: customer_id})
      |> Repo.update()
    end
  end

  @doc """
  Make an account free: its balance is never checked and nothing is refused
  (ADR 0031). Reversible with `revoke_comp/1`. Burns are still written, so
  Finance can see what the comp cost.
  """
  @spec comp_account(User.t(), keyword()) :: {:ok, User.t()} | {:error, term()}
  def comp_account(user, opts \\ [])
  def comp_account(%User{comped: true} = user, _opts), do: {:ok, user}

  def comp_account(%User{} = user, opts) do
    user
    |> User.comp_changeset(%{comped: true})
    |> Repo.update()
    |> audit_comp(user, "billing.comp.granted", opts)
  end

  @doc "Undo `comp_account/2`: the balance is checked again from the next spend."
  @spec revoke_comp(User.t(), keyword()) :: {:ok, User.t()} | {:error, :not_comped}
  def revoke_comp(user, opts \\ [])
  def revoke_comp(%User{comped: false}, _opts), do: {:error, :not_comped}

  def revoke_comp(%User{} = user, opts) do
    user
    |> User.comp_changeset(%{comped: false})
    |> Repo.update()
    |> audit_comp(user, "billing.comp.revoked", opts)
  end

  defp audit_comp({:ok, %User{} = updated} = ok, %User{} = before, action, opts) do
    Audit.record(%{
      user_id: updated.id,
      action: action,
      resource_type: "user",
      resource_id: updated.id,
      actor: Keyword.get(opts, :actor, "admin"),
      request_ip: Keyword.get(opts, :request_ip),
      metadata: %{"from" => before.comped, "to" => updated.comped}
    })

    ok
  end

  defp audit_comp(other, _before, _action, _opts), do: other

  @doc """
  The Stripe Customer for `user`, created on first need. Checkout must never
  be opened without one: passing `customer_email` instead makes Stripe mint
  its own Customer whose id we never learn.
  """
  @spec ensure_stripe_customer(User.t()) :: {:ok, User.t()} | {:error, term()}
  def ensure_stripe_customer(%User{stripe_customer_id: id} = user)
      when is_binary(id) and id != "",
      do: {:ok, user}

  def ensure_stripe_customer(%User{} = user), do: create_stripe_customer(user)

  # ─── Stripe webhooks ────────────────────────────────────────────────────────

  @doc """
  Claim a verified Stripe event once (`stripe_events`) and apply it inside the
  same transaction, so a failed apply leaves the event unclaimed for Stripe to
  redeliver. Returns `{:ok, :duplicate}` for an event already seen.
  """
  @spec handle_event(Stripe.Event.t()) ::
          {:ok, :ignored | :duplicate | :credits_purchased | :credits_clawed_back}
          | {:error, term()}
  def handle_event(%Stripe.Event{id: id, type: type} = event) when is_binary(id) do
    Repo.transaction(fn ->
      if claim_event(id, type) == :claimed do
        case apply_event(event) do
          {:ok, result} -> result
          {:error, reason} -> Repo.rollback(reason)
        end
      else
        :duplicate
      end
    end)
  end

  # No id (hand-built events in tests) — nothing to dedupe against.
  def handle_event(%Stripe.Event{} = event), do: apply_event(event)

  @doc """
  Best-effort record of a webhook processing failure (#501).

  A failed apply rolls the `stripe_events` claim back by design, so without
  this a failing event leaves zero DB trace — the failure exists only in
  Stripe's dashboard and our logs, and a purchase or a clawback silently
  never reaches the ledger. One row per event id: a retried delivery bumps `failure_count`
  and `last_failed_at` (and un-resolves a previously resolved row) rather
  than accumulating a row per attempt across Stripe's three days of retries.

  Best-effort on the same contract as `record_usage/5`: recording the
  failure must never change the webhook response.
  """
  @spec record_webhook_failure(Stripe.Event.t(), term()) :: :ok | :error
  def record_webhook_failure(%Stripe.Event{id: id, type: type}, reason) when is_binary(id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    error = reason |> inspect() |> String.slice(0, 500)

    Repo.insert_all(
      "stripe_webhook_failures",
      [
        %{
          event_id: id,
          event_type: type,
          error: error,
          failure_count: 1,
          first_failed_at: now,
          last_failed_at: now
        }
      ],
      on_conflict: [
        set: [error: error, last_failed_at: now, resolved_at: nil],
        inc: [failure_count: 1]
      ],
      conflict_target: :event_id
    )

    :ok
  rescue
    e ->
      Logger.error(
        "webhook failure record failed for #{inspect(reason)}: #{Exception.message(e)}"
      )

      :error
  end

  def record_webhook_failure(_event, _reason), do: :ok

  @doc """
  Marks a previously recorded webhook failure resolved — called when a later
  delivery of the same event processes successfully (or dedupes/goes stale,
  which means the event no longer needs applying). Best-effort, like
  `record_webhook_failure/2`.
  """
  @spec resolve_webhook_failure(String.t() | nil) :: :ok
  def resolve_webhook_failure(event_id) when is_binary(event_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.update_all(
      from(f in "stripe_webhook_failures",
        where: f.event_id == ^event_id and is_nil(f.resolved_at)
      ),
      set: [resolved_at: now]
    )

    :ok
  rescue
    e ->
      Logger.error("webhook failure resolve failed for #{event_id}: #{Exception.message(e)}")
      :ok
  end

  def resolve_webhook_failure(_), do: :ok

  # Atomic claim: the unique primary key is what makes concurrent deliveries of
  # the same event resolve to exactly one winner.
  defp claim_event(id, type) do
    {count, _} =
      Repo.insert_all(
        "stripe_events",
        [
          %{
            id: id,
            type: type,
            inserted_at: DateTime.utc_now() |> DateTime.truncate(:second)
          }
        ],
        on_conflict: :nothing
      )

    if count == 1, do: :claimed, else: :duplicate
  end

  @doc """
  Apply one verified Stripe event to the credit ledger (ADR 0031). Three
  event types matter, all handled by `Fountain.Credits.Purchases`:
  `checkout.session.completed` for a credit pack, `charge.refunded` and
  `charge.dispute.created` for the clawbacks. Everything else returns
  `{:ok, :ignored}` without touching the database.
  """
  @spec apply_event(Stripe.Event.t()) ::
          {:ok, :ignored | :credits_purchased | :credits_clawed_back} | {:error, term()}
  def apply_event(%Stripe.Event{
        type: "checkout.session.completed",
        data: %{object: session}
      }) do
    # Only a credit pack (ADR 0031): a session Fountain did not open for
    # credits is somebody else's, acknowledged and ignored.
    if Fountain.Credits.Purchases.credits_session?(session) do
      case Fountain.Credits.Purchases.complete(session) do
        {:ok, _entry} -> {:ok, :credits_purchased}
        {:ok, :duplicate, _entry} -> {:ok, :credits_purchased}
        {:error, :user_not_found} -> {:error, :user_not_found}
        {:error, reason} -> {:error, reason}
      end
    else
      {:ok, :ignored}
    end
  end

  # charge.refunded and charge.dispute.created only matter for a credit pack
  # (ADR 0030 decision 5). Neither names a customer we need to look up: the
  # purchase row does.
  def apply_event(%Stripe.Event{type: "charge.refunded", data: %{object: charge}}) do
    case Fountain.Credits.Purchases.refund(charge) do
      {:ok, :nothing} -> {:ok, :ignored}
      {:ok, _entry} -> {:ok, :credits_clawed_back}
      {:ok, :duplicate, _} -> {:ok, :credits_clawed_back}
      {:error, reason} -> {:error, reason}
    end
  end

  def apply_event(%Stripe.Event{type: "charge.dispute.created", data: %{object: dispute}}) do
    case Fountain.Credits.Purchases.dispute(dispute) do
      {:ok, :nothing} -> {:ok, :ignored}
      {:ok, _entry} -> {:ok, :credits_clawed_back}
      {:ok, :duplicate, _} -> {:ok, :credits_clawed_back}
      {:error, reason} -> {:error, reason}
    end
  end

  def apply_event(_event), do: {:ok, :ignored}

  @doc """
  Here rather than in each caller because the billing page, the billing API
  and the console's dashboard all report "this month" and must mean the same
  month — three copies of this arithmetic is three chances to disagree.
  """
  @spec current_month_range() :: {DateTime.t(), DateTime.t()}
  def current_month_range do
    %{start: period_start, end: period_end} = month_range()
    {period_start, period_end}
  end

  @doc """
  One whole UTC calendar month as a **half-open** `%{start, end}`:
  `months_ago` back from the running month (0, the default, is this month;
  `:now` pins the clock).
  `end` is the first instant of the next month, so every consumer that
  filters `>= start and < end` covers the whole month — the old inclusive
  `23:59:59` end (a Stripe `current_period_end` habit) dropped the last
  second of every month from every query. A surface that prints the window
  shows `end` minus a second, or its date minus a day.
  """
  @spec month_range(non_neg_integer(), keyword()) :: %{start: DateTime.t(), end: DateTime.t()}
  def month_range(months_ago \\ 0, opts \\ []) when is_integer(months_ago) and months_ago >= 0 do
    now = Keyword.get(opts, :now) || DateTime.utc_now()
    total = now.year * 12 + (now.month - 1) - months_ago
    {year, month} = {div(total, 12), rem(total, 12) + 1}

    %{
      start: month_start(year, month),
      end: month_start(year + div(month, 12), rem(month, 12) + 1)
    }
  end

  defp month_start(year, month),
    do: DateTime.new!(Date.new!(year, month, 1), ~T[00:00:00], "Etc/UTC")

  @doc """
  Returns a usage summary for `user_id` over the given period.

  Fields:
  - `:conversations` — count of `sandbox_provisioned` plus
    `sandbox_provision_failed` events. Failed attempts count because they
    still accrue sandbox minutes; excluding them makes the two numbers
    diverge for exactly the accounts where provisioning is failing.
  - `:turns` — count of `turn_started` events
  - `:sandbox_minutes` — active sandbox time in minutes inside the period,
    parked time excluded. Computed by `Fountain.Billing.SandboxUsage` from the
    sandbox rows themselves, clipped to the period: a sandbox that spans a
    month boundary contributes to each month what it ran in that month, and
    one still running contributes everything up to now.
  - `:sandbox_minutes_by_provider` — the same minutes split per sandbox
    provider, `%{provider => minutes}`. Providers the tenant did not use are
    absent. Minutes on different providers are bought at different prices, so
    this split is what makes the total attributable to a cost.
  - `:turn_hours` — hours of turns on the providers Fountain pays for, summed
    per turn (two conversations each an hour on one machine are two, ADR 0023
    step 6), not the sandbox's busy time. The same number
    `CreditPricer` burns, carried here so a surface showing usage does
    not need a second pass over the same rows to show the unit credit is
    burned in (`Fountain.Credits.turn_cost_cents/1`).
  """
  @spec usage_summary(binary(), DateTime.t(), DateTime.t()) ::
          %{
            conversations: non_neg_integer(),
            turns: non_neg_integer(),
            credit_burned_cents: non_neg_integer(),
            sandbox_minutes: float(),
            sandbox_minutes_by_provider: %{optional(String.t()) => float()},
            turn_hours: float()
          }
  def usage_summary(user_id, %DateTime{} = period_start, %DateTime{} = period_end) do
    # Counted from `turn_started` events, which survive a deleted
    # conversation: a conversation is one that ran a turn in the window,
    # whichever sandbox it ran on (a conversation on a persistent home
    # provisions nothing, ADR 0023, so a provision count missed it).
    {turns, conversations} =
      from(e in UsageEvent,
        where:
          e.user_id == ^user_id and
            e.inserted_at >= ^period_start and
            e.inserted_at < ^period_end and
            e.event_type == "turn_started",
        select: {count(e.id), count(fragment("distinct ? ->> 'conversation_id'", e.metadata))}
      )
      |> Repo.one()

    burned = Fountain.Credits.burned_between(user_id, period_start, period_end)

    # One attribution pass, read two ways. `for_user/3` and `busy_for_user/3`
    # would each run it again; this is the same two queries once.
    rows = SandboxUsage.attribution(period_start, period_end, user_id: user_id)

    %{
      conversations: conversations,
      turns: turns,
      # What the ledger actually took for the window: the number the customer
      # was charged, as opposed to `turn_hours`, which is what will be charged
      # when the in-flight turns close.
      credit_burned_cents: burned,
      # Rounded once, from the total — summing rounded per-provider minutes
      # would let the parts disagree with the whole.
      sandbox_minutes:
        rows |> Enum.map(& &1.active_seconds) |> Enum.sum() |> SandboxUsage.minutes(),
      sandbox_minutes_by_provider:
        rows
        |> Enum.reject(&(&1.active_seconds == 0))
        |> Map.new(&{&1.provider, SandboxUsage.minutes(&1.active_seconds)}),
      turn_hours:
        rows
        |> Enum.filter(&SandboxUsage.platform_cost?(&1.provider))
        |> Enum.map(& &1.turn_seconds)
        |> Enum.sum()
        |> SandboxUsage.hours()
    }
  end

  @doc """
  `usage_summary/3` for every user at once, in one query — for the admin view,
  which refreshes on a timer and must not run a query per user.

  Returns `%{user_id => %{conversations: n, turns: n, sandbox_minutes: f,
  sandbox_minutes_by_provider: %{provider => f}, turn_hours: f}}`; users with
  neither turns nor sandbox time in the period are absent. Conversations are
  the ones that ran a turn in the window, as in `usage_summary/3`; the
  ledger's burn is `Finance`'s to report, not this table's.

  Carries two units on purpose, because they answer different questions and
  the admin table shows both. `sandbox_minutes` is wall-clock sandbox time —
  what a provider bills Fountain, so minutes, per provider, because the
  providers charge differently. `turn_hours` is time with a prompt in flight —
  what credit is burned for (`Fountain.Credits.turn_cost_cents/1`), so hours,
  and summed only over the providers Fountain pays for, exactly as
  `usage_summary/3` computes it for one tenant.
  """
  @spec usage_summaries(DateTime.t(), DateTime.t()) :: %{optional(binary()) => map()}
  def usage_summaries(%DateTime{} = period_start, %DateTime{} = period_end) do
    empty = %{
      conversations: 0,
      turns: 0,
      sandbox_minutes: 0.0,
      sandbox_minutes_by_provider: %{},
      turn_hours: 0.0
    }

    counted =
      from(e in UsageEvent,
        where:
          e.inserted_at >= ^period_start and e.inserted_at < ^period_end and
            e.event_type == "turn_started",
        group_by: e.user_id,
        select:
          {e.user_id, count(e.id),
           count(fragment("distinct ? ->> 'conversation_id'", e.metadata))}
      )
      |> Repo.all()
      |> Map.new(fn {user_id, turns, conversations} ->
        {user_id, %{empty | turns: turns, conversations: conversations}}
      end)

    # Both sandbox figures come from the sandbox rows, not from these events —
    # the period-clipped, per-provider computation in `SandboxUsage`, which is
    # two more queries for every user at once rather than one per user.
    # `Finance.usage_by_user/1` rather than `SandboxUsage.by_user/1` because
    # the latter collapses to active seconds and drops the busy/idle split
    # turn hours are read off. Sandboxes whose owner has been deleted keep
    # their seconds under a `nil` owner in the provider report; it drops them,
    # since here there is no user row to hang them on.
    period_start
    |> SandboxUsage.attribution(period_end)
    |> Finance.usage_by_user()
    |> Enum.reduce(counted, fn {user_id, usage}, acc ->
      summary = Map.get(acc, user_id, empty)

      Map.put(acc, user_id, %{
        summary
        | sandbox_minutes: SandboxUsage.minutes(usage.active_seconds),
          sandbox_minutes_by_provider:
            Map.new(usage.by_provider, fn row ->
              {row.provider, SandboxUsage.minutes(row.active)}
            end),
          turn_hours:
            usage.by_provider
            |> Enum.filter(&SandboxUsage.platform_cost?(&1.provider))
            |> Enum.map(& &1.turn)
            |> Enum.sum()
            |> SandboxUsage.hours()
      })
    end)
  end

  # ─── Provider spend attribution ─────────────────────────────────────────────

  @doc """
  Sandbox time per provider for a period, and who it belongs to — the number to
  hold a Sprites, E2B or Daytona invoice next to.

  Options:
    * `:period` — `{period_start, period_end}`, default the current month
    * `:top` — how many tenants `:top_tenants` names (default 10)
    * `:now` — pins the clock (tests)

  Returns:
    * `:period_start` / `:period_end` — the window these numbers cover
    * `:by_provider` — `%{provider => %{active_seconds, busy_seconds,
      idle_seconds, sandboxes, users}}`, parked time already excluded
    * `:platform_seconds` — seconds on providers Fountain pays for. Self-hosted
      runners (decisions/0022) run on the tenant's own machine, so they appear
      in `:by_provider` but deliberately not in this total
    * `:platform_idle_seconds` — the part of `:platform_seconds` with no turn
      in flight. This is the number a shorter idle timeout removes, so it is
      the one to read before changing anything about the bill
    * `:top_tenants` — the accounts behind that total, biggest first, each with
      its `email` (`nil` once the account is deleted — the seconds were still
      paid for, they are simply no longer attributable)
    * `:attribution` — every per-tenant row the totals were built from

  Deliberately no money: prices are per-provider, per-machine-size and
  negotiated, and none of them are in this codebase. A made-up rate would make
  this look authoritative when it is not — multiply outside, against the rate
  card you actually pay.
  """
  @spec provider_spend(keyword()) :: %{
          period_start: DateTime.t(),
          period_end: DateTime.t(),
          by_provider: map(),
          platform_seconds: non_neg_integer(),
          platform_idle_seconds: non_neg_integer(),
          top_tenants: [map()],
          attribution: [SandboxUsage.row()]
        }
  def provider_spend(opts \\ []) do
    {period_start, period_end} = Keyword.get(opts, :period) || current_month_range()

    attribution_opts =
      case Keyword.fetch(opts, :now) do
        {:ok, now} -> [now: now]
        :error -> []
      end

    rows = SandboxUsage.attribution(period_start, period_end, attribution_opts)
    # The same fold `Finance.cost/3` reads, so the hours here and the money
    # on /admin/finance are one computation.
    totals = Finance.platform_totals(rows)

    %{
      period_start: period_start,
      period_end: period_end,
      by_provider: totals.by_provider,
      platform_seconds: totals.active_seconds,
      platform_idle_seconds: totals.idle_seconds,
      top_tenants: top_tenants(totals.paid, Keyword.get(opts, :top, 10)),
      attribution: rows
    }
  end

  # One email lookup for the whole list rather than one per row — this renders
  # on the admin panel's ten-second refresh.
  defp top_tenants(rows, limit) do
    top = rows |> Enum.sort_by(& &1.active_seconds, :desc) |> Enum.take(limit)

    emails =
      top
      |> Enum.map(& &1.user_id)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> case do
        [] -> %{}
        ids -> Repo.all(from u in User, where: u.id in ^ids, select: {u.id, u.email}) |> Map.new()
      end

    Enum.map(top, &Map.put(&1, :email, Map.get(emails, &1.user_id)))
  end

  # ─── Admin billing overview (#286) ──────────────────────────────────────────

  @doc """
  The numbers an operator checks daily, in one read-only pass — for the admin
  panel (no tenant scoping; the caller is behind `require_admin`).

  - `funded` — accounts with a positive credit balance
  - `deferred_cents` — the sum of every positive balance: credit granted or
    sold and not yet spent
  - `purchases_this_month` — `checkout.session.completed` webhook events
    since the start of the current UTC month. Every verified webhook is
    claimed into `stripe_events` before handling, so the claim table is a
    complete record of checkouts.
  - `webhook_failures` — unresolved rows from `record_webhook_failure/2`

  Read the function for the exact keys; they are what `/admin` renders.
  """
  def overview_admin(opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    event_limit = Keyword.get(opts, :event_limit, 10)

    # Claimable principals are `users` rows (ADR 0044) and are excluded from all
    # three counts. A principal is not an account somebody holds, and its
    # balance is not a second sale: the money in it came out of the balance of
    # the application that opened it, which this panel already counted when
    # that application bought it.
    accounts = from(u in User, where: u.principal == false)

    comped = Repo.one(from(u in accounts, where: u.comped, select: count(u.id))) || 0
    total = Repo.one(from(u in accounts, select: count(u.id))) || 0

    funded =
      Repo.one(from(u in accounts, where: u.credit_balance_cents > 0, select: count(u.id))) || 0

    deferred = Fountain.Billing.Finance.deferred_cents()
    %{start: month_start} = month_range(0, now: now)

    purchases_this_month =
      Repo.one(
        from e in Fountain.Credits.LedgerEntry,
          where: e.reason == "purchase" and e.inserted_at >= ^month_start,
          select: count(e.id)
      ) || 0

    recent_events =
      Repo.all(
        from e in "stripe_events",
          order_by: [desc: e.inserted_at],
          limit: ^event_limit,
          select: %{id: e.id, type: e.type, inserted_at: e.inserted_at}
      )

    failed_events =
      Repo.all(
        from f in "stripe_webhook_failures",
          where: is_nil(f.resolved_at),
          order_by: [desc: f.last_failed_at],
          limit: ^event_limit,
          select: %{
            event_id: f.event_id,
            event_type: f.event_type,
            error: f.error,
            failure_count: f.failure_count,
            last_failed_at: f.last_failed_at
          }
      )

    %{
      accounts: total,
      comped: comped,
      funded: funded,
      deferred_cents: deferred,
      purchases_this_month: purchases_this_month,
      recent_events: recent_events,
      failed_events: failed_events
    }
  end

  @doc """
  Best-effort `emit/5`.

  Metering is bookkeeping: it must never be able to fail a conversation. A bad
  changeset, a dropped connection or an unexpected raise is logged and swallowed,
  the same contract `Fountain.Audit.record/1` uses. Because the swallow makes a
  metering outage look like zero usage, every drop also emits
  `[:fountain, :usage, :dropped]` — any non-zero count on that counter means
  billing data is being lost (#503).
  """
  @spec record_usage(binary(), String.t(), binary() | nil, String.t() | nil, map()) ::
          {:ok, UsageEvent.t()} | {:error, term()}
  def record_usage(user_id, event_type, resource_id, resource_type, metadata \\ %{}) do
    case emit(user_id, event_type, resource_id, resource_type, metadata) do
      {:ok, _} = ok ->
        mirror_usage_to_analytics(user_id, event_type, resource_type, metadata)
        ok

      {:error, %Ecto.Changeset{} = cs} ->
        usage_dropped(event_type, "rejected", cs.errors)
        {:error, :invalid}
    end
  rescue
    e ->
      usage_dropped(event_type, "exception", Exception.message(e))
      {:error, :exception}
  end

  # The six metering event types are also the six moments that say whether
  # anyone is actually *using* the product, so they go to PostHog from the
  # same choke point that writes the billing row — never from the callers,
  # which is the whole point of `record_usage/5` being the choke point.
  #
  # `usage.` prefixed so a product event and its billing counterpart are
  # obviously the same fact seen twice, and so they cannot collide with an
  # audit action name in the same PostHog project.
  defp mirror_usage_to_analytics(user_id, event_type, resource_type, metadata) do
    if Fountain.Analytics.enabled?(),
      do: do_mirror_usage(user_id, event_type, resource_type, metadata)

    :ok
  end

  defp do_mirror_usage(user_id, event_type, resource_type, metadata) do
    Fountain.Analytics.capture(
      "usage.#{event_type}",
      user_id,
      metadata
      |> Fountain.Analytics.sanitize()
      |> Map.merge(%{"resource_type" => resource_type, "source" => "metering"})
    )
  end

  defp usage_dropped(event_type, kind, reason) do
    Logger.warning("usage: #{event_type} #{kind}, event dropped: #{inspect(reason)}")

    :telemetry.execute(
      [:fountain, :usage, :dropped],
      %{count: 1},
      %{event_type: event_type, kind: kind}
    )
  end

  @doc """
  Writes a usage event synchronously to `usage_events`.

  Raises nothing itself but returns `{:error, changeset}` on rejection. Callers
  on a conversation's critical path should use `record_usage/5`, which cannot
  fail the operation it is measuring.

  Emitted from `Conversations.sandbox_status_effects/2` (which the machine owner
  runs after every status write) and `Conversations._unsafe_create_turn/1`
  rather than from `ConversationServer`, so every path that provisions, runs or
  tears down a sandbox is counted — including the wake path and the
  terminate-when-the-server-is-already-dead path.
  """
  @spec emit(binary(), String.t(), binary() | nil, String.t() | nil, map()) ::
          {:ok, UsageEvent.t()} | {:error, Ecto.Changeset.t()}
  def emit(user_id, event_type, resource_id, resource_type, metadata \\ %{}) do
    %UsageEvent{}
    |> UsageEvent.changeset(%{
      user_id: user_id,
      event_type: event_type,
      resource_id: resource_id,
      resource_type: resource_type,
      metadata: metadata,
      inserted_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.insert()
  end

  # ─── Private helpers ────────────────────────────────────────────────────────
end
