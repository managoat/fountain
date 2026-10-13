defmodule Fountain.Quotas do
  @moduledoc """
  The fleet ceiling: the most live sandboxes the deployment runs at once
  (`SANDBOX_FLEET_CEILING`, default 20 — the Sprites plan's limit).

  `with_sandbox_reservation/2` checks it under a global lock and refuses with
  `:fleet_full` when every slot is in use, whoever holds them. There is no
  per-account cap and no queue: a self-hosted deployment's accounts share one
  provider bill by choice, and a refused start is retried by its caller (ADR
  0042, as amended 2026-10-13).

  ## What counts

  A sandbox counts while it is compute: `pending`, `starting` and `ready`.
  `pending` and `starting` count because a sprite is being paid for from the
  moment provisioning begins, and counting only `ready` would let a burst of
  concurrent starts sail past the ceiling before any of them settle. `suspended`
  deliberately does NOT count — a parked sprite is scaled to zero and costs
  ~nothing (decisions/0017) — which means this set is narrower than the admin
  sandbox view's "anything non-terminal": the admin table will list a suspended
  sandbox that the counter ignores. Waking one re-runs the ceiling check
  (`Fountain.Machines.Resume`). Unconfirmed resets also count,
  even on parked machines, and cannot use the replacement exclusion.

  **A machine being woken counts from the moment it is admitted** (ADR 0058
  stage 7a): a row stamped `transition: "resuming"` under a *live* lease is
  compute that has been paid for and is on its way up, and it counts even while
  its status still says `suspended`. That stamp is written inside
  `with_sandbox_reservation/2`'s own transaction, which is what makes the
  reservation a reservation rather than a read — without it, two wakes of two
  parked machines would each pass a check the other was invisible to and both
  come up past a ceiling with room for one.

  The live-lease half is what keeps it honest in the other direction. A resume
  whose owner died leaves the stamp behind, and counting *that* would hold a
  slot until some later sweep cleared it. A lease that has expired is
  an abandoned operation for the next owner to take over — stage 6a's rule,
  applied here — so the slot comes back when the lease does. The clock is the
  database's (stage 7a), the same one `lease_until` is written from.

  **A machine being destroyed counts until its row is terminal** (stage 9a),
  and this one takes no lease reading at all. `transition: "destroying"` is
  durable intent rather than an operation in flight: an owner that died between
  the fence and the finalize left a machine that is still at the provider and
  still billing, and the driver that ends it runs on a cron. So the slot is held
  for as long as the row is. `reset_requested_at` did the same for a reset
  until stage 9b, which stopped reading it: both fences write this stamp.
  """

  import Ecto.Query

  alias Fountain.Conversations.Sandbox
  alias Fountain.Repo

  @active_statuses ~w(pending starting ready)

  @doc """
  Number of `user_id`'s sandboxes that hold a fleet slot.

  Pass `exclude: sandbox_id` to leave a specific sandbox out, as
  `check_fleet_ceiling/1` does.
  """
  @spec active_sandbox_count(binary(), keyword()) :: non_neg_integer()
  def active_sandbox_count(user_id, opts \\ []) when is_binary(user_id) do
    query =
      from s in active_sandboxes(),
        where: s.user_id == ^user_id,
        select: count(s.id)

    query =
      case Keyword.get(opts, :exclude) do
        nil ->
          query

        excluded ->
          from s in query,
            where: s.id != ^excluded or s.transition == "destroying"
      end

    Repo.one(query) || 0
  end

  @doc """
  Active-sandbox counts for every user with at least one, in a single query —
  for the admin view, which refreshes on a timer and must not run a count per
  row (the same contract as `Fountain.Usage.usage_summaries/2`).

  Returns `%{user_id => count}`; users with no active sandboxes are absent.
  """
  @spec active_sandbox_counts() :: %{optional(binary()) => non_neg_integer()}
  def active_sandbox_counts do
    from(s in active_sandboxes(),
      group_by: s.user_id,
      select: {s.user_id, count(s.id)}
    )
    |> Repo.all()
    |> Map.new()
  end

  @doc "Live sandboxes across every tenant, against the fleet ceiling."
  @spec fleet_count() :: non_neg_integer()
  def fleet_count do
    Repo.one(from(s in active_sandboxes(), select: count(s.id))) || 0
  end

  # A teardown holds its slot until deletion is confirmed, including one
  # requested while parked. Replacement exclusions cannot spend that slot.
  #
  # The second arm is ADR 0058 stage 9a's `destroying` stamp, which both fences
  # write; until stage 9b an arm beside it read `reset_requested_at`, the same
  # statement on a column 9b stopped reading. A machine wearing the stamp goes
  # on holding its slot until the row is terminal. **No lease condition**, which
  # is the difference from the `resuming` arm below and the whole of the stage:
  # a resume whose owner died is an abandoned operation and gives the slot back
  # when its lease lapses, where a destroy whose owner died is an *unfinished*
  # one — the machine is still at the provider and still billing, and
  # `SandboxReaper.sweep_fenced_teardowns/0`'s driver is what ends it. Counting
  # it as free would let a start take a slot two machines are using.
  #
  # The last arm is ADR 0058 stage 7a's resume reservation, and it is the one
  # rendering of `Machines.Lease.live?/2` that had to be written in SQL: this is
  # a `count(*)` under an advisory lock, and pulling every candidate row into
  # Elixir to fold a predicate over it would turn a counter into a scan. The two
  # halves are the same two `live?/2` decides on — a holder, and a deadline that
  # has not passed — and `quotas_test.exs` pins them against it so the copy
  # cannot drift the way stage 6a's three copies had. `statement_timestamp()`
  # for the reason `Lease`'s moduledoc gives — `now()` freezes for the whole of
  # the reservation's transaction, and this count runs inside one — and
  # `AT TIME ZONE 'UTC'` for the other reason it gives: `lease_until` is
  # `timestamp without time zone`, so comparing it against a bare `timestamptz`
  # casts through the session's `TimeZone`, and a machine on its way up would
  # stop counting on any connection not running in UTC.
  defp active_sandboxes do
    from s in Sandbox,
      where:
        s.status in @active_statuses or
          (s.transition == "destroying" and s.status not in ["terminated", "failed"]) or
          (s.transition == "resuming" and not is_nil(s.lease_node) and
             s.lease_until > fragment("statement_timestamp() AT TIME ZONE 'UTC'"))
  end

  @doc "The fleet ceiling in force."
  @spec fleet_ceiling() :: non_neg_integer()
  def fleet_ceiling do
    :fountain |> Application.get_env(:sandboxes, []) |> Keyword.get(:fleet_ceiling, 20)
  end

  @doc """
  Check the deployment against the fleet ceiling. `:ok`, or
  `{:error, :fleet_full}` — every provider slot is in use, whoever holds them.
  """
  @spec check_fleet_ceiling(keyword()) :: :ok | {:error, :fleet_full}
  def check_fleet_ceiling(opts \\ []) do
    ceiling = fleet_ceiling()

    count =
      case Keyword.get(opts, :exclude) do
        nil ->
          fleet_count()

        excluded ->
          Repo.one(
            from(s in active_sandboxes(),
              where: s.id != ^excluded or s.transition == "destroying",
              select: count(s.id)
            )
          ) || 0
      end

    if count < ceiling, do: :ok, else: {:error, :fleet_full}
  end

  # Advisory-lock key for sandbox reservations: one for the whole fleet, so
  # the ceiling is counted by one reservation at a time.
  @lock_namespace 4315
  @fleet_lock_key 0

  @doc """
  Check the fleet ceiling and run `fun` (which must create the sandbox row)
  atomically, under a Postgres advisory lock.

  A check alone is check-then-insert: concurrent starts at the last slot could
  each read "room" before any row landed, and each go on to provision a paid
  machine (#330). The lock serializes check and insert, so the second start
  re-counts after the first has committed.

  `opts` takes `exclude: sandbox_id` (see `check_fleet_ceiling/1`). `fun` must
  return `{:ok, value}` or `{:error, reason}`; any error — the ceiling's or
  `fun`'s — rolls the whole reservation back.
  """
  @spec with_sandbox_reservation(keyword(), (-> {:ok, term()} | {:error, term()})) ::
          {:ok, term()} | {:error, term()}
  def with_sandbox_reservation(opts \\ [], fun) when is_list(opts) do
    Repo.transaction(fn ->
      Repo.query!("SELECT pg_advisory_xact_lock($1, $2)", [@lock_namespace, @fleet_lock_key])

      with :ok <- check_fleet_ceiling(opts),
           {:ok, value} <- fun.() do
        value
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc "Sandbox statuses that hold a fleet slot."
  def active_statuses, do: @active_statuses
end
