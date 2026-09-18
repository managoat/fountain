defmodule Fountain.Machines.Reads do
  @moduledoc """
  Read admission: how a sandbox-files read takes part in the machine's
  ownership protocol (ADR 0039, ADR 0058, #2394).

  `Fountain.SandboxFiles` runs four fixed scripts on a machine through
  `Managoat.Sandbox.exec/4`. Until this module it decided whether it could on
  the struct its caller handed in — `status: "ready"` as of whenever the
  controller fetched the row — and then called the provider with nothing
  between that reading and the exec. A park or a destroy committing in that gap
  was not seen: the read ran against a machine being suspended or deleted, and
  on a provider whose exec wakes a suspended machine it woke it (#1715).

  A read is short, it leaves the database, and it must not be what keeps a
  machine from being reclaimed. Those three together decide the shape.

  ## Admission

  `run/3` admits a read in one short transaction under the per-sandbox advisory
  lock (4316), the lock `Lease.claim/4` takes, and decides from the row read
  under it — never from the caller's struct, which is stale by construction
  (#2307 constraint 1):

    * a row that is not `ready` is refused `{:sandbox_not_ready, status}`, the
      word the API has always used — `suspended` is never woken for a read;
    * a row with **any** `transition` stamp is refused `:sandbox_unavailable`.
      `destroying` is durable intent and refused whatever its lease says (stage
      9a). A lapsed `parking` or `resuming` stamp is refused too, which is
      stricter than turn admission: a park that died after its suspend leaves a
      `ready` row over a suspended machine, and a read there is exactly the
      wake this refuses. The next park or sweep clears it;
    * a **live lease** is refused `:sandbox_unavailable` — an owner is mid-
      operation, and between its claim and its stamp the lease is all there is.

  An admitted read inserts a `sandbox_reads` row whose `expires_at` is the
  database's clock plus `window_ms/0`, in the same transaction, and commits.
  The lock is released before the provider is called: ADR 0058 keeps provider
  I/O out of every transaction and every advisory lock.

  ## The two orders

  They are the same pair `Machines.Admission` argues for turns, read from the
  read's end. A park or destroy whose claim committed first has a live lease on
  the row, and the admission that waited on 4316 behind it reads that lease and
  refuses — the read never reaches the provider. A read admitted first has
  committed its row before the claim could take the lock, so the operation sees
  it: `drain/2`, which `Park` and `Destroy` call inside their lease renewal and
  before any provider call, waits until every unexpired read on the machine
  has been released or has run out.

  No new read can be admitted while the drain waits, because the drain runs
  under the operation's live lease. So the wait is bounded by the longest
  window already admitted — `window_ms/0` — and a client polling the files API
  cannot hold a machine awake: it gets `503 sandbox_unavailable` for the length
  of the operation instead.

  ## The window, and what bounds it

  The window is only a promise if the read is really off the provider by the
  time it ends. `Managoat.Sandbox.exec/4`'s `:timeout` bounds how long the
  adapter *collects* output, not its synchronous startup (`ExecDeadline`'s own
  note), so it is not enough on its own. `run/3` therefore runs the caller's
  function in a task under `Fountain.TaskSupervisor` and kills it at a hard
  cutoff `@margin_ms` before the window ends — armed on the task through the
  timer server, so it fires whether or not the caller is still alive — measured on the monotonic clock
  from *before* the admission, so the local cutoff always falls before the
  database expiry the drain compares against. A read that reaches the cutoff
  answers `{:sandbox_unreachable, :read_window_closed}`, the 503 an unreachable
  provider already gets.

  A read whose admission has already used up its budget — a caller descheduled
  between the commit and the exec — does not start: `{:error, :sandbox_unavailable}`
  without a provider call. Nothing is queued anywhere; the admission runs in the
  caller, so a caller that has given up has nothing left to run later.

  **Release** is `after`, so a read that returns, fails or raises deletes its
  row at once. A caller that is killed outright never runs it, and its row
  expires: the drain waits out at most one window for it, and the next
  admission on the machine deletes it.

  ## What this does not promise

  Fountain does not begin a park's or a destroy's provider work while an
  admitted read's window is open, and it does not start a read on a machine an
  operation holds or has stamped. What happens *at the provider* after the
  local cutoff — a remote script still running after its connection was cut —
  is the provider's, and so is whether a provider suspends a machine by itself
  and then wakes it for an exec. That decision is #2395's, under #1715.

  ## Why inline, not in the owner

  The same reason `Admission.end_turn/3` runs inline. Routing admission through
  `Machines.Machine` would queue a read behind a park's minute-long checkpoint
  only to refuse it afterwards, and the owner's mailbox would carry messages
  whose callers had long since gone. The advisory lock and the lease are the
  correctness; the owner's serialisation buys a read nothing.
  """

  import Ecto.Query, only: [from: 2]

  alias Fountain.Conversations
  alias Fountain.Conversations.Sandbox
  alias Fountain.Machines.Lease
  alias Fountain.Repo

  require Logger

  # How long an admitted read may be at the provider. Above the files API's
  # 30 s exec timeout by the margin below plus room for the admission itself.
  # `machine_bounds_test.exs` pins it between that timeout and the lease TTLs
  # of the two operations that drain it.
  @window_ms 40_000

  # How far before the window's end the local cutoff falls. The window is
  # dated by the database when the row is inserted and the cutoff by this node
  # from before the admission, so the two are already ordered; the margin is
  # for the kill itself and for a drain polling on its own interval.
  @margin_ms 5_000

  # How often a drain re-reads the table.
  @poll_ms 100

  @doc """
  Admit a read on `sandbox_id`, run `fun` inside its window, and release it.

  `fun` receives the sandbox row as the admission read it — so the handle is
  built from the machine that was checked, not from the caller's struct — and
  the milliseconds it has left, which is at most `window_ms/0 - @margin_ms`. It
  runs in a task and is killed if it has not returned by then.

  Answers what `fun` answers, or a refusal: `{:sandbox_not_ready, status}`,
  `:sandbox_unavailable`, `:not_found`, or
  `{:sandbox_unreachable, :read_window_closed}` for a read cut off at the end
  of its window. `:window_ms` is a test seam; no call site passes it.
  """
  @spec run(Ecto.UUID.t(), (Sandbox.t(), pos_integer() -> result), keyword()) ::
          result | {:error, term()}
        when result: term()
  def run(sandbox_id, fun, opts \\ [])
      when is_binary(sandbox_id) and is_function(fun, 2) and is_list(opts) do
    window = Keyword.get(opts, :window_ms, @window_ms)
    cutoff = System.monotonic_time(:millisecond) + window - margin_ms(window)

    if Repo.in_transaction?() do
      # The admission's commit is what makes a read visible to a drain; inside
      # a caller's transaction it would not be, until that caller committed.
      {:error, :transaction_open}
    else
      with {:ok, {read_id, sandbox}} <- admit(sandbox_id, window) do
        try do
          case cutoff - System.monotonic_time(:millisecond) do
            budget when budget > 0 -> bounded(sandbox, budget, fun)
            _spent -> {:error, :sandbox_unavailable}
          end
        after
          release(read_id)
        end
      end
    end
  end

  @doc """
  Wait until no admitted read on `sandbox_id` is inside its window.

  For `Park` and `Destroy`, from inside their lease renewal and before their
  provider call. Returns `:ok`; it never refuses, because reclamation must not
  be defeated by reads. The wait is bounded by the window: every read that can
  still be counted was admitted before the caller's claim, and none can be
  admitted while the caller's lease is live. `:read_window_ms` shortens that
  bound for a test.

  A database fault is read as "reads may be in flight" and waited out to the
  bound, rather than as "none": the conservative answer costs time, the other
  costs the guarantee.
  """
  @spec drain(Ecto.UUID.t(), keyword()) :: :ok
  def drain(sandbox_id, opts \\ []) when is_binary(sandbox_id) and is_list(opts) do
    bound = Keyword.get(opts, :read_window_ms, @window_ms) + @poll_ms
    started = System.monotonic_time(:millisecond)
    do_drain(sandbox_id, started, started + bound)
  end

  @doc "How long an admitted read may hold its machine. See the moduledoc."
  @spec window_ms() :: pos_integer()
  def window_ms, do: @window_ms

  @doc "How long before the window's end a read is cut off."
  @spec margin_ms() :: pos_integer()
  def margin_ms, do: @margin_ms

  @doc """
  How many reads on `sandbox_id` are inside their window right now, on the
  database's clock. The drain's question, public for the suite.
  """
  @spec in_flight(Ecto.UUID.t()) :: non_neg_integer()
  def in_flight(sandbox_id) when is_binary(sandbox_id) do
    %Postgrex.Result{rows: [[count]]} =
      Repo.query!(
        "SELECT count(*) FROM sandbox_reads WHERE sandbox_id = $1 " <>
          "AND expires_at > (statement_timestamp() AT TIME ZONE 'UTC')",
        [Ecto.UUID.dump!(sandbox_id)]
      )

    count
  end

  # ── admission ─────────────────────────────────────────────────────────────

  defp admit(sandbox_id, window) do
    Conversations.with_sandbox_lock(sandbox_id, fn ->
      row =
        Repo.one(
          from s in Sandbox,
            where: s.id == ^sandbox_id,
            # Selected with the row so the lease is judged on the clock of the
            # statement that read it — `Lease.live?/2`'s one clock.
            select: {s, fragment("statement_timestamp()")}
        )

      case row do
        nil -> {:error, :not_found}
        {sandbox, db_now} -> admissible(sandbox, db_now, window)
      end
    end)
  end

  defp admissible(%Sandbox{status: status}, _db_now, _window) when status != "ready",
    do: {:error, {:sandbox_not_ready, status}}

  defp admissible(%Sandbox{transition: transition} = sandbox, _db_now, _window)
       when not is_nil(transition) do
    Logger.info("sandbox files: read refused on #{sandbox.id}, row stamped #{transition}")
    {:error, :sandbox_unavailable}
  end

  defp admissible(%Sandbox{} = sandbox, db_now, window) do
    if Lease.live?(sandbox, db_now) do
      Logger.info(
        "sandbox files: read refused on #{sandbox.id}, lease held by #{sandbox.lease_node}"
      )

      {:error, :sandbox_unavailable}
    else
      {:ok, {insert(sandbox.id, window), sandbox}}
    end
  end

  # The row, and the leftovers of any caller that was killed before it could
  # release: those have expired, so no drain is waiting on them, and this is
  # the one place that meets them.
  defp insert(sandbox_id, window) do
    id = Ecto.UUID.dump!(sandbox_id)

    Repo.query!(
      "DELETE FROM sandbox_reads WHERE sandbox_id = $1 " <>
        "AND expires_at <= (statement_timestamp() AT TIME ZONE 'UTC')",
      [id]
    )

    %Postgrex.Result{rows: [[read_id]]} =
      Repo.query!(
        "INSERT INTO sandbox_reads (id, sandbox_id, expires_at) VALUES (gen_random_uuid(), $1, " <>
          "(statement_timestamp() AT TIME ZONE 'UTC') + $2 * interval '1 millisecond') RETURNING id",
        [id, window]
      )

    read_id
  end

  # ── the window ────────────────────────────────────────────────────────────

  # `async_nolink` so a raise in `fun` comes back as a value this process can
  # re-raise *after* its `after` has released the row, rather than as a link
  # signal that kills the caller before it can.
  #
  # Unlinked also means the task outlives a caller that is killed, and that
  # caller's `yield` was the cutoff. So the cutoff is armed on the task itself
  # as well, through the timer server, which kills it at the same instant
  # whether or not anybody is still waiting for its answer: a dead caller's
  # read is off the provider before its window ends, like a live one's.
  defp bounded(sandbox, budget, fun) do
    task = Task.Supervisor.async_nolink(Fountain.TaskSupervisor, fn -> fun.(sandbox, budget) end)
    {:ok, timer} = :timer.kill_after(budget, task.pid)

    try do
      await(task, sandbox, budget)
    after
      :timer.cancel(timer)
    end
  end

  defp await(task, sandbox, budget) do
    case Task.yield(task, budget) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} ->
        result

      # The timer and the `yield` share one deadline, so the timer can win by a
      # hair; its kill is the cutoff, not a crash.
      {:exit, :killed} ->
        cut_off(sandbox, budget)

      {:exit, reason} ->
        exit(reason)

      nil ->
        cut_off(sandbox, budget)
    end
  end

  defp cut_off(sandbox, budget) do
    Logger.warning(
      "sandbox files: read on #{sandbox.id} cut off at the end of its window (#{budget} ms)"
    )

    {:error, {:sandbox_unreachable, :read_window_closed}}
  end

  # Best effort: a release that fails leaves a row that expires on its own, and
  # the read it belonged to has already finished.
  defp release(read_id) do
    Repo.query!("DELETE FROM sandbox_reads WHERE id = $1", [read_id])
    :ok
  rescue
    error in [Postgrex.Error, DBConnection.ConnectionError] ->
      Logger.warning("sandbox files: read release failed, it will expire: #{inspect(error)}")
      :ok
  end

  # A window too short to hold the margin — only a test's — keeps a fifth of
  # itself as margin instead.
  defp margin_ms(window) when window > 2 * @margin_ms, do: @margin_ms
  defp margin_ms(window), do: div(window, 5)

  # ── the drain ─────────────────────────────────────────────────────────────

  defp do_drain(sandbox_id, started, deadline) do
    pending =
      try do
        in_flight(sandbox_id)
      rescue
        error in [Postgrex.Error, DBConnection.ConnectionError] ->
          Logger.warning("machine #{sandbox_id}: read drain could not count: #{inspect(error)}")
          :unknown
      end

    cond do
      pending == 0 ->
        waited = System.monotonic_time(:millisecond) - started

        if waited >= @poll_ms,
          do: Logger.info("machine #{sandbox_id}: waited #{waited} ms for reads to finish")

        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        Logger.warning(
          "machine #{sandbox_id}: reads still counted past their window (#{inspect(pending)}); " <>
            "proceeding"
        )

        :ok

      true ->
        Process.sleep(@poll_ms)
        do_drain(sandbox_id, started, deadline)
    end
  end
end
