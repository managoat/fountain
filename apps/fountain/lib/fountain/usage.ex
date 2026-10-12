defmodule Fountain.Usage do
  @moduledoc """
  The sandbox lifecycle as counted rows (`usage_events`), and the per-account
  usage summaries the console and `/admin` render.

  `record_usage/5` is the one writer. It is called from
  `Conversations.sandbox_status_effects/2` (which the machine owner runs after
  every status write) and from `Conversations._unsafe_create_turn/1`, so every
  path that provisions, runs or tears down a sandbox is counted — including the
  wake path and the terminate-when-the-server-is-already-dead path.

  Metering is bookkeeping: it must never be able to fail a conversation, so
  `record_usage/5` logs and swallows. Because the swallow makes a metering
  outage look like zero usage, every drop also emits
  `[:fountain, :usage, :dropped]` (the `fountain.usage.dropped.count` metric,
  and `dropped_on_this_node/0`): any non-zero count means the figures below
  rest on an incomplete record (#503).

  Sandbox *time* is not counted here: `Fountain.Machines.Usage` computes it
  from the sandbox rows themselves, and reads only the park/wake pairs from
  this table.
  """

  import Ecto.Query

  require Logger

  alias Fountain.Machines.Usage, as: SandboxUsage
  alias Fountain.Repo
  alias Fountain.Usage.Event

  @doc """
  Best-effort `emit/5`: a bad changeset, a dropped connection or an unexpected
  raise is logged and swallowed, the same contract `Fountain.Audit.record/1`
  uses, and counted on `[:fountain, :usage, :dropped]`.
  """
  @spec record_usage(binary(), String.t(), binary() | nil, String.t() | nil, map()) ::
          {:ok, Event.t()} | {:error, term()}
  def record_usage(user_id, event_type, resource_id, resource_type, metadata \\ %{}) do
    case emit(user_id, event_type, resource_id, resource_type, metadata) do
      {:ok, _} = ok ->
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

  Returns `{:error, changeset}` on rejection. Callers on a conversation's
  critical path use `record_usage/5`, which cannot fail the operation it is
  measuring.
  """
  @spec emit(binary(), String.t(), binary() | nil, String.t() | nil, map()) ::
          {:ok, Event.t()} | {:error, Ecto.Changeset.t()}
  def emit(user_id, event_type, resource_id, resource_type, metadata \\ %{}) do
    %Event{}
    |> Event.changeset(%{
      user_id: user_id,
      event_type: event_type,
      resource_id: resource_id,
      resource_type: resource_type,
      metadata: metadata,
      inserted_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.insert()
  end

  # ─── Periods ────────────────────────────────────────────────────────────────

  @doc """
  The running UTC calendar month as `{start, end}`, half-open. Every surface
  that reports "this month" reads it here, so they mean the same month.
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
  filters `>= start and < end` covers the whole month. A surface that prints
  the window shows `end` minus a second, or its date minus a day.
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

  # ─── Summaries ──────────────────────────────────────────────────────────────

  @doc """
  A usage summary for `user_id` over the given period.

  Fields:
  - `:conversations` — conversations that ran a turn in the window, counted
    from `turn_started` events (which survive a deleted conversation)
  - `:turns` — count of `turn_started` events
  - `:sandbox_minutes` — active sandbox time in minutes inside the period,
    parked time excluded, from `Fountain.Machines.Usage` and clipped to the
    period: a sandbox that spans a month boundary contributes to each month
    what it ran in that month, and one still running contributes everything
    up to now.
  - `:sandbox_minutes_by_provider` — the same minutes split per sandbox
    provider, `%{provider => minutes}`. Providers the account did not use are
    absent.
  - `:turn_hours` — hours of turns on the providers the operator pays for,
    summed per turn (two conversations each an hour on one machine are two,
    ADR 0023 step 6), not the sandbox's busy time.
  """
  @spec usage_summary(binary(), DateTime.t(), DateTime.t()) ::
          %{
            conversations: non_neg_integer(),
            turns: non_neg_integer(),
            sandbox_minutes: float(),
            sandbox_minutes_by_provider: %{optional(String.t()) => float()},
            turn_hours: float()
          }
  def usage_summary(user_id, %DateTime{} = period_start, %DateTime{} = period_end) do
    {turns, conversations} =
      from(e in Event,
        where:
          e.user_id == ^user_id and
            e.inserted_at >= ^period_start and
            e.inserted_at < ^period_end and
            e.event_type == "turn_started",
        select: {count(e.id), count(fragment("distinct ? ->> 'conversation_id'", e.metadata))}
      )
      |> Repo.one()

    # One attribution pass, read two ways.
    rows = SandboxUsage.attribution(period_start, period_end, user_id: user_id)

    %{
      conversations: conversations,
      turns: turns,
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
  `usage_summary/3` for every user at once — for the admin view, which
  refreshes on a timer and must not run a query per user.

  Returns `%{user_id => %{conversations: n, turns: n, sandbox_minutes: f,
  sandbox_minutes_by_provider: %{provider => f}, turn_hours: f}}`; users with
  neither turns nor sandbox time in the period are absent.

  Carries two units on purpose. `sandbox_minutes` is wall-clock sandbox time —
  what a provider bills the operator, per provider, because the providers
  charge differently. `turn_hours` is time with a prompt in flight, summed
  only over the providers the operator pays for.
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
      from(e in Event,
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

    # Both sandbox figures come from the sandbox rows, not from these events.
    # Sandboxes whose owner has been deleted keep their seconds under a `nil`
    # owner in the provider report; `usage_by_user/1` drops them, since here
    # there is no user row to hang them on.
    period_start
    |> SandboxUsage.attribution(period_end)
    |> SandboxUsage.usage_by_user()
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

  # ─── Dropped events ─────────────────────────────────────────────────────────

  @doc """
  Metering events dropped on this node since it booted (`[:fountain, :usage,
  :dropped]`). A non-zero count means the period's figures rest on an
  incomplete record. Per node and since boot — the fleet-wide, durable count
  is the `fountain.usage.dropped.count` metric; this is the number that
  belongs beside the figures it undermines.
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
