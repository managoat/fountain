defmodule Fountain.Billing.SandboxUsage do
  @moduledoc """
  Active sandbox seconds, split by tenant and by provider, clipped to a period.

  Fountain pays Sprites, E2B and Daytona for the seconds its tenants' sandboxes
  are running (ADR 0005, ADR 0018). This module answers the question that turns
  one of those invoices into an internal number: *which tenant, on which
  provider, ran how long inside this period?*

  ## Where the numbers come from

  The `sandboxes` table is the authority, not `usage_events`. A sandbox row
  carries the four facts an interval needs — `provider`, `user_id`,
  `inserted_at` and `terminated_at` — every status change is the machine
  owner's write (`Fountain.Machines.Lease.cas_update/4`, ADR 0058), and it
  is never pruned. `usage_events` supplies exactly one thing on top: the
  `sandbox_suspended` / `sandbox_resumed` pairs that say when a sandbox was
  parked rather than running.

  Billing starts at `inserted_at`, not at the moment the sandbox reported
  ready: a provider charges from the moment provisioning begins, which is the
  same basis `Fountain.Quotas` counts on.

  ## Clipping, and why it matters

  Every interval is intersected with `[period_start, period_end)`:

    * a sandbox that spans a month boundary contributes to each month only what
      it actually ran in that month;
    * a sandbox still running at `period_end` contributes everything up to
      `period_end`, rather than nothing.

  Both were wrong before. Minutes accrued only when a sandbox was torn down and
  the whole lifetime landed in whichever period the teardown happened to fall
  in, so a long-lived agent reported zero for months and then a spike, and no
  month's total could be reconciled against that month's invoice. Clipping is
  what makes these numbers add up to something a provider bill can be checked
  against.

  ## Parked time

  Time between `sandbox_suspended` and the `sandbox_resumed` that closes it is
  subtracted: a parked sandbox is scaled to zero and costs ~nothing
  (decisions/0017). A suspend still open at the end of the interval is closed
  by the sandbox's own end, or by `period_end`.

  **The interval is durable; the discount is not.** A sandbox row is written
  synchronously and cannot be lost, but `Billing.record_usage/5` is
  deliberately best-effort — metering must never be able to fail a
  conversation (#503) — so the suspend/resume rows this subtraction pairs on
  can be dropped. A dropped `sandbox_suspended` bills parked time as running;
  a dropped `sandbox_resumed` treats a woken sandbox as parked until it dies.
  Neither can crash a report and neither is silent: every drop increments
  `[:fountain, :usage, :dropped]`. A non-zero count on that counter over a
  period means that period's parked figures rest on an incomplete record, and
  the numbers here should be read as approximate until it is back to zero.

  ## Idle time

  A sandbox nobody is prompting still runs and is still charged at full rate,
  so idle time counts as active — that is what the invoice says. It is also
  reported on its own, because it is the part that a shorter idle timeout can
  remove (decisions/0017, `docs/guides/operate/sandbox-lifetime.md`), and an
  hours total that cannot separate work from waiting says nothing about
  whether the bill is avoidable.

  Busy time is the union of the sandbox's turn intervals (`turns.started_at`
  to `turns.ended_at`), not their sum: two conversations on one sandbox
  prompting at once is one busy sandbox, not two. A turn still running closes
  at the same ceiling everything else does. So

      active = busy + idle

  by construction, with `busy` capped at `active` so an odd row cannot produce
  negative idle.

  Turn time (`turn_seconds`) is the *sum* of those same intervals, each clipped
  to the period. What credits buy (decisions/0031) is hours of work, and
  two conversations each running an hour on one machine are two hours of work
  on a machine that was busy for one (decisions/0023, step 6). It is not
  capped at `active` and may exceed it; `busy` is the machine's view, `turn`
  the tenant's.

  ## What a provider column does and does not mean

  `runner` is a tenant's own machine (decisions/0022) — real sandbox time, zero
  platform spend. It is reported so the hours are complete, and
  `platform_cost?/1` marks the providers whose seconds Fountain actually pays
  for. Do not sum across providers and call the result cost: an E2B second and
  a Sprites second are bought at different prices, which is the whole reason
  this module reports them apart.

  Seconds whose owner has been deleted stay in the totals under a `nil`
  `user_id` (account deletion nilifies the column rather than dropping the row,
  decisions/0009). The platform still paid for them; they are simply no longer
  attributable.

  ## Cost

  Two queries: the sandbox rows overlapping the period, and the park events for
  those rows. Pairing suspends with resumes needs the per-sandbox timeline, so
  the folding happens in Elixir — the same trade `Billing.usage_summaries/2`
  already makes, and on a strictly smaller set of rows.
  """

  import Ecto.Query

  alias Fountain.Billing.UsageEvent
  alias Fountain.Conversations.Conversation
  alias Fountain.Conversations.Sandbox
  alias Fountain.Conversations.Turn
  alias Fountain.Repo

  @terminal ~w(terminated failed)
  @park_events ~w(sandbox_suspended sandbox_resumed)

  # Providers whose seconds land on a bill Fountain pays. `runner` is the
  # tenant's own hardware and is deliberately absent — see the moduledoc.
  @platform_paid ~w(sprites e2b daytona)

  @typedoc """
  One tenant's time on one provider inside the period.

  `active_seconds` is what the provider charges for. `busy_seconds` is the part
  of it with a turn in flight and `idle_seconds` the rest; the two add up to
  `active_seconds`. `turn_seconds` is the turns themselves, summed — the unit
  credit is burned in — and is not bounded by `active_seconds`.

  `user_id` is `nil` for sandboxes whose owner has been deleted.
  """
  @type row :: %{
          user_id: binary() | nil,
          provider: String.t(),
          active_seconds: non_neg_integer(),
          busy_seconds: non_neg_integer(),
          idle_seconds: non_neg_integer(),
          turn_seconds: non_neg_integer(),
          sandboxes: pos_integer()
        }

  @doc """
  Active seconds per `{user_id, provider}` over `[period_start, period_end)`.

  Pass `user_id: id` to scope to a single tenant — the same computation, one
  tenant's rows. `:now` pins the clock (tests); a test driving a surface end to
  end, with nowhere to pass an option, pins the same clock with
  `Application.put_env(:fountain, Fountain.Billing.SandboxUsage, now: dt)`.

  A still-running sandbox accrues only up to *now*, never to a `period_end`
  that has not happened yet: asked about the current month, this reports what
  has been spent so far, not what the month will cost if nothing changes.

  Sorted by provider, then by seconds descending, so the head of the list is
  the tenant costing the most on each provider.
  """
  @spec attribution(DateTime.t(), DateTime.t(), keyword()) :: [row()]
  def attribution(%DateTime{} = period_start, %DateTime{} = period_end, opts \\ []) do
    sandboxes = overlapping_sandboxes(period_start, period_end, opts)
    ceiling = earliest(period_end, Keyword.get(opts, :now) || now())

    overlapping =
      sandboxes
      |> Enum.map(&{&1, overlap_seconds(&1, period_start, ceiling)})
      |> Enum.reject(fn {_sandbox, seconds} -> seconds <= 0 end)

    sandboxes_in_period = Enum.map(overlapping, &elem(&1, 0))
    parked = parked_seconds(sandboxes_in_period, period_start, ceiling)
    busy = busy_seconds(sandboxes_in_period, period_start, ceiling)

    overlapping
    |> Enum.group_by(fn {sandbox, _} -> {sandbox.user_id, sandbox.provider} end)
    |> Enum.map(fn {{user_id, provider}, group} ->
      {active, busy_total, turn_total} =
        Enum.reduce(group, {0, 0, 0}, fn {sandbox, seconds}, {active_acc, busy_acc, turn_acc} ->
          sandbox_active = max(seconds - Map.get(parked, sandbox.id, 0), 0)
          {union, sum} = Map.get(busy, sandbox.id, {0, 0})

          # Capped per sandbox rather than per group: a single row whose turns
          # somehow outrun its own active window must not borrow headroom from
          # a sibling and hide the anomaly.
          sandbox_busy = min(union, sandbox_active)

          # Turn seconds are deliberately not capped: two conversations each
          # running an hour on one machine are two hours of work on a machine
          # that was busy for one (decisions/0023, step 6).
          {active_acc + sandbox_active, busy_acc + sandbox_busy, turn_acc + sum}
        end)

      %{
        user_id: user_id,
        provider: provider,
        active_seconds: active,
        busy_seconds: busy_total,
        idle_seconds: active - busy_total,
        turn_seconds: turn_total,
        sandboxes: length(group)
      }
    end)
    |> Enum.sort_by(&{&1.provider, -&1.active_seconds})
  end

  @doc """
  Roll `attribution/3` rows up to one entry per provider — the operator's view,
  and the one to hold a provider invoice next to.

  `users` counts distinct owners; every unattributable sandbox collapses into
  the single `nil` owner, so it is a floor rather than an exact count when
  deleted accounts are in the period.
  """
  @spec by_provider([row()]) :: %{
          optional(String.t()) => %{
            active_seconds: non_neg_integer(),
            busy_seconds: non_neg_integer(),
            idle_seconds: non_neg_integer(),
            turn_seconds: non_neg_integer(),
            sandboxes: non_neg_integer(),
            users: non_neg_integer()
          }
        }
  def by_provider(rows) when is_list(rows) do
    rows
    |> Enum.group_by(& &1.provider)
    |> Map.new(fn {provider, group} ->
      {provider,
       %{
         active_seconds: group |> Enum.map(& &1.active_seconds) |> Enum.sum(),
         busy_seconds: group |> Enum.map(& &1.busy_seconds) |> Enum.sum(),
         idle_seconds: group |> Enum.map(& &1.idle_seconds) |> Enum.sum(),
         turn_seconds: group |> Enum.map(& &1.turn_seconds) |> Enum.sum(),
         sandboxes: group |> Enum.map(& &1.sandboxes) |> Enum.sum(),
         users: group |> Enum.map(& &1.user_id) |> Enum.uniq() |> length()
       }}
    end)
  end

  @doc """
  Roll `attribution/3` rows up to `%{user_id => %{provider => active_seconds}}`
  — the per-tenant view of the same numbers.
  """
  @spec by_user([row()]) :: %{
          optional(binary() | nil) => %{optional(String.t()) => non_neg_integer()}
        }
  def by_user(rows) when is_list(rows) do
    rows
    |> Enum.group_by(& &1.user_id)
    |> Map.new(fn {user_id, group} ->
      {user_id, Map.new(group, &{&1.provider, &1.active_seconds})}
    end)
  end

  @doc """
  One tenant's active seconds per provider: `%{provider => active_seconds}`.

  Providers the tenant did not use in the period are absent rather than zero —
  an empty map means no sandbox time at all.
  """
  @spec for_user(binary(), DateTime.t(), DateTime.t()) :: %{
          optional(String.t()) => non_neg_integer()
        }
  def for_user(user_id, %DateTime{} = period_start, %DateTime{} = period_end)
      when is_binary(user_id) do
    period_start
    |> attribution(period_end, user_id: user_id)
    |> Map.new(&{&1.provider, &1.active_seconds})
  end

  @doc """
  One tenant's *busy* seconds per provider: `%{provider => busy_seconds}` —
  for each sandbox, how long it had any turn in flight (a union).

  The same rows `for_user/3` reads, reporting the part of each with a prompt
  actually in flight rather than the whole active window. This is the
  machine's view, the one a provider bill on the `:turn` basis relates to. The
  tenant's credit is burned in `turn_seconds_for_user/3`, which sums turns
  instead: on a shared sandbox the two differ.

  Providers with no turn time in the period are absent rather than zero, so a
  tenant whose sandboxes all sat idle gets an empty map, not `%{"sprites" => 0}`.
  """
  @spec busy_for_user(binary(), DateTime.t(), DateTime.t()) :: %{
          optional(String.t()) => non_neg_integer()
        }
  def busy_for_user(user_id, %DateTime{} = period_start, %DateTime{} = period_end)
      when is_binary(user_id) do
    period_start
    |> attribution(period_end, user_id: user_id)
    |> Enum.reject(&(&1.busy_seconds == 0))
    |> Map.new(&{&1.provider, &1.busy_seconds})
  end

  @doc """
  One tenant's *turn* seconds per provider: `%{provider => turn_seconds}` —
  the sum over its turns, each clipped to the period.

  This is the unit credit is burned in (`Fountain.Credits.turn_cost_cents/1`):
  an idle sandbox costs Fountain money and is reported by `for_user/3`, but
  burning none of a customer's credit for it is the deliberate choice — the
  price measures work, not forgetfulness. And it is a sum, not a union: two conversations each running
  an hour on one machine are two hours of work (decisions/0023, step 6).

  Same shape and absence rule as `busy_for_user/3`.
  """
  @spec turn_seconds_for_user(binary(), DateTime.t(), DateTime.t()) :: %{
          optional(String.t()) => non_neg_integer()
        }
  def turn_seconds_for_user(user_id, %DateTime{} = period_start, %DateTime{} = period_end)
      when is_binary(user_id) do
    period_start
    |> attribution(period_end, user_id: user_id)
    |> Enum.reject(&(&1.turn_seconds == 0))
    |> Map.new(&{&1.provider, &1.turn_seconds})
  end

  @doc """
  Does time on this provider land on a bill Fountain pays?

  False for `runner` (the tenant's own machine) and for any provider this
  build does not know about — a name we cannot price is not a name to assume
  we are paying for.
  """
  @spec platform_cost?(String.t()) :: boolean()
  def platform_cost?(provider) when is_binary(provider), do: provider in @platform_paid

  @doc "Seconds as minutes, rounded to two places — for display."
  @spec minutes(non_neg_integer()) :: float()
  def minutes(seconds) when is_integer(seconds), do: Float.round(seconds / 60, 2)

  @doc "Seconds as hours, rounded to two places — the unit provider invoices use."
  @spec hours(non_neg_integer()) :: float()
  def hours(seconds) when is_integer(seconds), do: Float.round(seconds / 3600, 2)

  @doc "Providers whose seconds Fountain pays for, in report order."
  @spec platform_paid_providers() :: [String.t()]
  def platform_paid_providers, do: @platform_paid

  # ── internals ───────────────────────────────────────────────────────────────

  defp overlapping_sandboxes(period_start, period_end, opts) do
    query =
      from s in Sandbox,
        where: s.inserted_at < ^period_end,
        where: is_nil(s.terminated_at) or s.terminated_at >= ^period_start,
        select: %{
          id: s.id,
          user_id: s.user_id,
          provider: s.provider,
          status: s.status,
          inserted_at: s.inserted_at,
          terminated_at: s.terminated_at,
          updated_at: s.updated_at
        }

    query =
      case Keyword.get(opts, :user_id) do
        nil -> query
        user_id -> from s in query, where: s.user_id == ^user_id
      end

    Repo.all(query)
  end

  # When the sandbox stopped costing money. `terminated_at` where it is set;
  # `updated_at` for a terminal row predating the migration that backfilled the
  # column (the last write such a row ever received); otherwise it is still
  # running and the ceiling is as far as this report can see.
  defp effective_end(%{terminated_at: %DateTime{} = at}, _ceiling), do: at

  defp effective_end(%{status: status, updated_at: at}, _ceiling) when status in @terminal,
    do: at

  defp effective_end(_sandbox, ceiling), do: ceiling

  defp overlap_seconds(sandbox, period_start, ceiling) do
    span_seconds(sandbox.inserted_at, effective_end(sandbox, ceiling), period_start, ceiling)
  end

  # An interval intersected with the period, in whole seconds. Negative
  # intersections (an interval entirely outside the period) clamp to zero.
  defp span_seconds(from, to, period_start, ceiling) do
    start = latest(from, period_start)
    stop = earliest(to, ceiling)

    stop |> DateTime.diff(start, :second) |> max(0)
  end

  # The clock every window is clipped against. `:now` on the call is the way to
  # pin it; this is for a test that drives a surface end to end and has nowhere
  # to pass one. The dashboard's turn-hours tile is that case: the console has
  # no month picker, so the tile can only be read against the running month,
  # and a two-hour turn seeded at the month's start does not exist yet during
  # the month's first two hours (#1586). Unset outside tests, so this is one
  # application-env read per attribution pass.
  defp now do
    case Application.get_env(:fountain, __MODULE__, [])[:now] do
      %DateTime{} = pinned -> pinned
      nil -> DateTime.utc_now()
    end
  end

  defp earliest(a, b), do: if(DateTime.compare(a, b) == :gt, do: b, else: a)
  defp latest(a, b), do: if(DateTime.compare(a, b) == :lt, do: b, else: a)

  defp parked_seconds([], _period_start, _ceiling), do: %{}

  defp parked_seconds(sandboxes, period_start, ceiling) do
    ids = Enum.map(sandboxes, & &1.id)

    events =
      from(e in UsageEvent,
        where: e.resource_id in ^ids,
        where: e.event_type in @park_events,
        order_by: [asc: e.inserted_at, asc: e.id],
        select: %{
          resource_id: e.resource_id,
          event_type: e.event_type,
          inserted_at: e.inserted_at
        }
      )
      |> Repo.all()
      |> Enum.group_by(& &1.resource_id)

    Enum.reduce(sandboxes, %{}, fn sandbox, acc ->
      case Map.get(events, sandbox.id) do
        nil -> acc
        own -> Map.put(acc, sandbox.id, sum_parked(own, sandbox, period_start, ceiling))
      end
    end)
  end

  defp busy_seconds([], _period_start, _ceiling), do: %{}

  defp busy_seconds(sandboxes, period_start, ceiling) do
    ids = Enum.map(sandboxes, & &1.id)

    # Bounded at the database by the period: `turns` is the largest table in
    # play here, and only the ones overlapping the window can contribute.
    turns =
      from(t in Turn,
        join: c in Conversation,
        on: c.id == t.conversation_id,
        where: c.sandbox_id in ^ids,
        where: not is_nil(t.started_at),
        where: is_nil(t.orphaned_at),
        where: t.started_at < ^ceiling,
        where: is_nil(t.ended_at) or t.ended_at >= ^period_start,
        select: %{sandbox_id: c.sandbox_id, started_at: t.started_at, ended_at: t.ended_at}
      )
      |> Repo.all()
      |> Enum.group_by(& &1.sandbox_id)

    Enum.reduce(sandboxes, %{}, fn sandbox, acc ->
      case Map.get(turns, sandbox.id) do
        nil ->
          acc

        own ->
          # A turn with no end is still running, or ended without the row being
          # written; either way it cannot outlive the sandbox.
          close = effective_end(sandbox, ceiling)
          intervals = Enum.map(own, &{&1.started_at, &1.ended_at || close})
          clipped = fn {from, to} -> span_seconds(from, to, period_start, ceiling) end

          # Both readings of the same intervals: the union (how long the
          # machine had any turn in flight — `busy_seconds`) and the sum (how
          # much turn time the tenant spent — `turn_seconds`).
          union = intervals |> merge_intervals() |> Enum.map(clipped) |> Enum.sum()
          sum = intervals |> Enum.map(clipped) |> Enum.sum()

          Map.put(acc, sandbox.id, {union, sum})
      end
    end)
  end

  # Union, not sum, for the busy figure: two conversations prompting on one
  # sandbox at the same moment is one busy sandbox. Summing them would let busy
  # exceed active and report negative idle. (The sum is kept separately as
  # `turn_seconds`, where exceeding active is the point.)
  defp merge_intervals(intervals) do
    intervals
    |> Enum.sort_by(fn {from, _} -> from end, DateTime)
    |> Enum.reduce([], fn
      interval, [] ->
        [interval]

      {from, to}, [{open_from, open_to} | rest] = acc ->
        if DateTime.compare(from, open_to) == :gt do
          [{from, to} | acc]
        else
          [{open_from, latest(to, open_to)} | rest]
        end
    end)
  end

  # Pairs each suspend with the resume that closes it, in event order, and adds
  # up the parts of those intervals that fall inside the period. A suspend with
  # no resume is closed by the sandbox's own end — the sandbox was torn down
  # while parked, or is parked still.
  defp sum_parked(events, sandbox, period_start, ceiling) do
    close = effective_end(sandbox, ceiling)

    {total, open} =
      Enum.reduce(events, {0, nil}, fn
        %{event_type: "sandbox_suspended", inserted_at: at}, {total, nil} ->
          {total, at}

        %{event_type: "sandbox_resumed", inserted_at: at}, {total, since}
        when not is_nil(since) ->
          {total + span_seconds(since, at, period_start, ceiling), nil}

        _event, acc ->
          acc
      end)

    case open do
      nil -> total
      since -> total + span_seconds(since, close, period_start, ceiling)
    end
  end
end
