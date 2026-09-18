defmodule Fountain.Workers.SandboxReaper do
  @moduledoc """
  Reconciles the `sandboxes` table against what actually exists at sprites.dev.

  ## What leaks, and how

  Both destroy call sites in `ConversationServer` discard the result —
  `_ = Managoat.Sandbox.destroy(handle)` — and then mark the row `terminated` or
  `failed` regardless. So any destroy that fails for a transient reason leaves a
  sprite alive with a database row that says it is gone, and nothing ever looks
  again. This does not need a hard BEAM crash; the ordinary path is enough.

  Measured against production when this was written: 114 sprites existed at
  sprites.dev, 7 of them with a terminal sandbox row. The rest of the drift is
  historical (102 sprites with no row at all, from the pre-rename `aod-*` era)
  and 443 rows whose sprite is already gone.

  The other half is quota. `Fountain.Quotas` counts `pending`, `starting` and
  `ready` toward a tenant's concurrent-sandbox cap, deliberately — a sprite
  bills from the moment provisioning starts. A row stuck in `pending` because
  the BEAM died mid-provision therefore consumes cap forever, and a
  default-limit tenant with a few of those cannot start a conversation at all,
  with no self-serve way out.

  ## Three passes, in descending order of confidence

  1. **Release stuck rows.** `pending`/`starting` past the grace period with no
     live `ConversationServer` become `failed`. This frees quota and is safe:
     the row already cannot be used for anything. A sibling runs with it:
     `ready` rows past a lifetime bound are parked or expired. A third, the
     destroys that were asked for and then abandoned, has a five-minute run of
     its own (`sweep_fenced_teardowns/0`, ADR 0058 stage 9b).

  2. **Destroy sprites we know are dead.** A sandbox row in a terminal state
     whose sprite still exists at sprites.dev. Unambiguously ours,
     unambiguously finished.

  3. **Count sprites we do not recognise, and touch nothing.** Reported as a
     log line and a telemetry measurement.

  Pass 3 is deliberately inert. A sprite with no row is not proof of a leak: the
  same `SPRITES_TOKEN` may be in a developer's shell or a staging instance, and
  a sprite created seconds ago may simply not have committed its row yet.
  Production currently holds a `jake-*` sprite that is exactly this case.
  Destroying by absence-of-evidence would eventually delete someone's live work,
  and unlike a missed sprite that mistake cannot be undone. Cleaning up the
  legacy `aod-*` sprites is a one-off an operator can do by hand, having looked
  at the list.
  """

  # `unique:` since ADR 0058 stage 6b, matching `SandboxResetReconciler`'s
  # (deleted in stage 9b). Oban keys it on the args too, so the hourly run and
  # the five-minute teardown run are unique apart.
  # Contention used to be rare here — the sweeps wrote rows nobody else wanted
  # — and it is ordinary now that every park and every expiry asks the
  # machine's owner and can be made to wait for a lease. A run that spends its
  # attempt budget on busy waits can outlast the hour between crons, and two
  # reapers sweeping the same fleet would spend their whole time queueing
  # behind each other's leases. At most one incomplete job at a time.
  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [period: :infinity, states: :incomplete]

  import Ecto.Query

  require Logger

  alias Fountain.Conversations
  alias Fountain.Conversations.{Lifecycle, Sandbox, Termination}
  alias Fountain.Machines.Destroy
  alias Fountain.Machines.Lease
  alias Fountain.Machines.Machine
  alias Fountain.Machines.Occupancy
  alias Fountain.Repo

  # Long enough to clear the slowest legitimate provision: package installs get
  # 300s per command and a clone gets 600s, and several can run in sequence.
  # Being late to release a stuck row costs a little quota; being early kills a
  # sandbox that was still starting.
  @stuck_after_minutes 60

  # A cap per run, so a large backlog drains over several hours instead of
  # firing hundreds of destroy calls at sprites.dev in one burst.
  #
  # It is the budget for the *whole run*, not for pass 2 alone (ADR 0058
  # stage 5b). It used to be pass 2's, because pass 2 made every provider
  # destroy the reaper made: pass 1 only wrote rows terminal and left the
  # machines to be collected. Now an expiry destroys its machine in the call,
  # so an uncapped pass 1 would fire one destroy per abandoned row and the
  # constraint written here would be gone — reachable on stock configuration,
  # because `idle_sweep/1` expires whenever an explicit suspend fails, so a
  # provider suspend outage would put the entire idle backlog through the
  # destroy path in one hourly pass. Pass 1 spends from this first and pass 2
  # gets the remainder; a row that finds it spent is left for the next run,
  # which is the draining this number is for.
  #
  # "The remainder" can be nothing, and that is a real ordering decision rather
  # than an accident: 30 abandoned rows and 5 terminal rows whose sprites are
  # still at the provider means 25 destroys in pass 1 and none in pass 2, and
  # the 5 leaked sprites keep billing invisibly — their rows already read as
  # finished, so no other pass looks at them. Before ADR 0058 stage 5b the two
  # populations shared one `Enum.take/2` here; now pass 1 has strict priority.
  # That is the right way round — a live-status row with no server holds a
  # quota slot *and* bills, where a terminal row only bills — and the starvation
  # is bounded by the same backlog that causes it.
  @destroy_limit 25

  @doc false
  # Overridable the same way `owner_attempt_limit/0` is, and for the same
  # reason: `sandbox_reaper_test.exs` drives the budget with two rows instead of
  # twenty-six, which is the only way to see one run's budget being *shared*
  # between the expiries and the teardown driver (ADR 0058 stage 9a). Nothing
  # in `lib/` sets it.
  # `|| @destroy_limit` rather than a default argument: the test helper that
  # sets this restores it by writing `nil` back, which `Application.get_env/3`
  # hands straight through as a value.
  def destroy_limit, do: Application.get_env(:fountain, :reaper_destroy_limit) || @destroy_limit

  # The trickle `pass_two_budget/1` guarantees pass 2 when pass 1 saturates.
  # Small on purpose: it is an anti-starvation floor, not a second budget.
  @pass_two_floor 5

  # How many machines one run may *ask an owner about* — parks and expiries
  # together (ADR 0058 stage 6b; the 5b round-3 note that named this).
  #
  # `@destroy_limit` bounds provider destroys and deliberately does not charge
  # a refusal, because the refusal that matters is decided before any provider
  # call. That was the right trade while contention was rare, and it leaves the
  # *attempt* count unbounded: since stage 6b every idle park goes through the
  # owner too, so a fleet with two hundred contended machines would spend
  # `Park.busy_wait_ms/0` on each one and turn an hourly sweep into a
  # seventeen-minute one, holding a `:maintenance` slot for the whole of it.
  #
  # A hundred is a sweep that finishes inside eight minutes even if every
  # single attempt waits out its full five seconds, which is a shape only an
  # outage produces. Machines over the cap are deferred exactly as a spent
  # destroy budget defers them: nothing is written, the row is unchanged, and
  # the next run sees it again.
  #
  # Overridable so `sandbox_reaper_park_test.exs` can drive the cap with two
  # rows instead of a hundred and one. Nothing in `lib/` sets it.
  @owner_attempt_limit 100

  @doc false
  def owner_attempt_limit,
    do: Application.get_env(:fountain, :reaper_owner_attempt_limit, @owner_attempt_limit)

  @terminal_statuses ~w(terminated failed)
  @active_statuses ~w(pending starting)

  # The durable transition of ADR 0058 stage 9a, and the reason a reset fence
  # stamps with it. Every pass here reads the first; `sweep_fenced_teardowns/0`
  # is the only one that reads the second, to leave a reset to its own
  # reconciler.
  @destroying "destroying"
  @reset_reason "reset"

  # A row whose server died mid-wake looks identical to an abandoned one until
  # the new server registers in Horde — whose registry is an async CRDT, so
  # `Lifecycle.any_server_alive?/1` can briefly miss a live server on another
  # node. Two database facts get this grace before a row counts as unheld:
  # `updated_at`, which the wake path touches when it flips
  # `suspended -> ready`, and — since ADR 0058 stage 6a — `woken_at`, which
  # `Conversations.register_server/2` commits under the per-sandbox advisory
  # lock *before* it asks Horde for anything. `updated_at` only covers a wake
  # that changed the row; `woken_at` covers a wake that found the row already
  # `ready` and started a server on it, which is the case the registry lag
  # actually bites (#2307 constraint 4). Fifteen minutes is far longer than
  # propagation takes, and it is also the window a marker whose caller died
  # before its `start_child` ages out over.
  # The same fifteen minutes `Fountain.Machines.Occupancy.recently_woken?/2`
  # applies to the marker in Elixir; `park_test.exs` pins that the two agree,
  # because a park that refuses on a marker the sweep ignored (or the reverse)
  # would have the two halves of one rule disagreeing about one row.
  @abandoned_grace_minutes Occupancy.woken_grace_minutes()

  @doc false
  def abandoned_grace_minutes, do: @abandoned_grace_minutes

  # The five-minute run: pass 1c alone (ADR 0058 stage 9b). See
  # `sweep_fenced_teardowns/0` for why it has a cron entry of its own.
  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"pass" => "teardowns"}}) do
    {reconciled, refused} = sweep_fenced_teardowns()

    Logger.info("reaper: teardowns reconciled=#{reconciled} refused=#{refused}")

    # Its own event rather than the hourly run's, because the two runs are
    # different jobs on different clocks: a sum over `[:fountain, :reaper,
    # :run]` would otherwise read an hourly gauge twelve times an hour.
    # `reconciled` counts abandoned destroys this pass finished, which is a
    # defect upstream rather than routine reclamation; `refused` counts the
    # ones an owner would not take, which are machines still standing.
    :telemetry.execute(
      [:fountain, :reaper, :teardowns],
      %{reconciled: reconciled, refused: refused},
      %{}
    )

    :ok
  end

  def perform(_job) do
    released = release_stuck_sandboxes()
    {parked, expired, refused, skipped} = sweep_abandoned_sandboxes()

    listings = list_by_provider()
    ok_listings = for {p, {:ok, names}} <- listings, into: %{}, do: {p, names}
    # One budget of provider destroys for the whole run, spent by pass 1 first
    # (ADR 0058 stage 5b). See `@destroy_limit` and `pass_two_budget/1`.
    destroyed = destroy_dead_sprites(ok_listings, pass_two_budget(expired))
    untracked = report_untracked(ok_listings)

    live = ok_listings |> Map.values() |> Enum.map(&MapSet.size/1) |> Enum.sum()

    Logger.info(
      "reaper: released=#{released} parked=#{parked} expired=#{expired} " <>
        "refused=#{refused} skipped=#{skipped} " <>
        "destroyed=#{destroyed} untracked=#{untracked} live=#{live}"
    )

    result =
      case for {p, {:error, reason}} <- listings, do: {p, reason} do
        [] ->
          :ok

        [{provider, reason} | _] = failures ->
          # Every pass that could run already did — per-provider isolation
          # means one backend's listing failure does not stop another's
          # destroys. Returning an error lets Oban retry the rest.
          Enum.each(failures, fn {p, r} ->
            Logger.warning("reaper: could not list #{p} sandboxes: #{inspect(r)}")
          end)

          _ = provider
          {:error, reason}
      end

    # `parked` is its own measurement: parks are reversible bookkeeping, and
    # folding them into `expired` would silently change what that metric means.
    # (`reconciled`, the abandoned teardowns, was measured here until stage 9b
    # moved that pass to a run of its own; it is `[:fountain, :reaper,
    # :teardowns]` now.)
    #
    # `skipped` is the one added in stage 6b, and it exists to keep `refused`
    # honest. Since the park revalidates under the machine's lease, the sweep
    # now has a whole class of outcomes that are constraint 1 *working*: a
    # machine somebody started using between the scan and the claim, one that
    # is no longer past a bound, one being reset or torn down, one whose
    # abandoned park was cleared. None of those is a machine the reaper failed
    # to reclaim, and counting them in `refused` — a gauge whose whole job is
    # to say "these machines are still there and something is wrong" — would
    # make an ordinary busy fleet look like an outage.
    #
    # `refused` is its own for both reasons at once (ADR 0058 stage 5b). An
    # expiry now destroys the machine through its owner and that can be
    # refused, so `expired` had to stop meaning "rows the sweep decided to
    # expire" and go back to meaning "machines actually reclaimed" — it is a
    # finance-board gauge ("rows expired by the reaper"), and counting
    # still-billing machines in it would report healthy reclamation through an
    # outage that reclaims nothing. What is left over goes here, where a
    # non-zero value says the machines are still there.
    :telemetry.execute(
      [:fountain, :reaper, :run],
      %{
        released: released,
        parked: parked,
        expired: expired,
        refused: refused,
        skipped: skipped
      },
      %{}
    )

    result
  end

  # What is left of the run's budget for pass 2, with a floor under it.
  #
  # Pass 1 has priority (`@destroy_limit` says why), and a backlog big enough
  # to saturate it would otherwise leave pass 2 exactly nothing, run after run,
  # for as long as the backlog lasts. The rows pass 2 collects are already
  # terminal, so no other pass looks at them and nobody would notice: their
  # machines would bill until the backlog cleared. The floor keeps that pass
  # making progress at a trickle whatever pass 1 is doing.
  #
  # It means a saturated run makes at most `@destroy_limit + @pass_two_floor`
  # provider calls rather than `@destroy_limit` — 30 rather than 25. That is the
  # intended reading: the number is a drain rate that keeps a backlog from
  # arriving at the provider all at once, not a hard ceiling, and starving a
  # whole pass indefinitely is the worse failure. (Stage 9a made it 35 with a
  # second floor for pass 1c's driver; stage 9b gave that pass a run of its own
  # and took both the floor and the sharing away.)
  defp pass_two_budget(spent), do: max(@pass_two_floor, destroy_limit() - spent)

  # ── pass 1: rows stuck mid-provision ──────────────────────────────────────

  @doc false
  def release_stuck_sandboxes do
    now = DateTime.utc_now()
    cutoff = DateTime.add(now, -@stuck_after_minutes * 60, :second)

    Sandbox
    |> where(
      [s],
      s.status in ^@active_statuses and s.updated_at < ^cutoff
    )
    # Not a machine somebody has asked to be destroyed: the `destroying` stamp
    # (stage 9a; 9b stopped reading the `reset_requested_at` column beside it).
    # A fenced row belongs to `sweep_fenced_teardowns/0`'s driver, which
    # finishes the destroy the fence asked for, where this pass would write
    # `failed` over it and leave the stamp and the sprite behind.
    |> where(^not_destroying())
    # The wake-registration marker, on its own grace (ADR 0058 stage 6a). Not
    # this pass's 60-minute cutoff: the marker answers "did somebody start a
    # server here that the registry has not published yet", and the answer goes
    # stale in seconds, so it gets the same fifteen minutes the abandoned sweep
    # gives it. A row that has been `pending` for an hour and was woken two
    # minutes ago is a row a wake is holding, however long the provision has
    # taken.
    |> where([s], ^woken_grace(now))
    |> Repo.all()
    |> Repo.preload(:conversations)
    |> Enum.reject(&Lifecycle.any_server_alive?/1)
    |> Enum.count(fn sandbox ->
      was = sandbox.status

      # Not matched with `{:ok, _} =`: a sweep over failure leftovers that
      # crashes on one refused row stops the pass for every row after it
      # (#2329, the rule ADR 0058 records). A row the write refuses — retired
      # under it, fenced since the scan — is logged and left for the next pass.
      case Conversations.update_sandbox(sandbox, %{
             status: "failed",
             terminated_at: DateTime.utc_now() |> DateTime.truncate(:second)
           }) do
        {:ok, _} ->
          Logger.info(
            "reaper: released stuck sandbox #{sandbox.id} (#{sandbox.machine_name}) " <>
              "after #{@stuck_after_minutes}m in #{sandbox.status}"
          )

          record_reap(sandbox, "sandbox.released_stuck", %{
            "previous_status" => was,
            "stuck_after_minutes" => @stuck_after_minutes
          })

          true

        {:error, reason} ->
          Logger.warning(
            "reaper: could not release stuck sandbox #{sandbox.id} " <>
              "(#{sandbox.machine_name}): #{inspect(reason)}; left for the next pass"
          )

          false
      end
    end)
  end

  # The durable-intent half of "is this machine already spoken for", as a
  # composable condition, so the two liveness passes ask it in exactly the same
  # words — the shape stage 6a gave the marker below, for the reason it gave
  # it: two readings of one rule drift.
  defp not_destroying do
    dynamic([s], is_nil(s.transition) or s.transition != ^@destroying)
  end

  # The marker half of "is anybody holding this row", as a composable
  # condition, so the two liveness passes ask it in exactly the same words.
  # `nil` is never woken — every row on the way in, and every row whose wake
  # predates stage 6a's migration.
  defp woken_grace(now) do
    cutoff = DateTime.add(now, -@abandoned_grace_minutes * 60, :second)
    dynamic([s], is_nil(s.woken_at) or s.woken_at < ^cutoff)
  end

  # A live ConversationServer means provisioning is still in flight somewhere in
  # the cluster, however long it has taken. Horde's registry is cluster-wide, so
  # this is not just a local check — `Lifecycle.any_server_alive?/1` is the one
  # scan for it (#2255 decision 2), shared with `Termination.reap_sandbox/1`,
  # which used to scan for the same thing itself.
  # A sandbox the tenant did not stop, ending for a reason only the reaper
  # knows. Attributed to the worker so "my agent's sandbox vanished" has an
  # answer in the tenant's own trail rather than only in the server log —
  # `admin.sandbox.reaped` covered the admin-clicked path and nothing covered
  # this one (#551).
  defp record_reap(%Sandbox{} = sandbox, action, metadata) do
    Fountain.Audit.record(%{
      user_id: sandbox.user_id,
      action: action,
      resource_type: "sandbox",
      resource_id: sandbox.id,
      actor: "system:sandbox_reaper",
      metadata:
        metadata
        |> Map.put("sprite_name", sandbox.machine_name)
        |> Map.put("provider", sandbox.provider)
    })
  end

  # ── pass 1b: ready sandboxes nobody is holding ────────────────────────────

  @doc """
  Sweeps `ready` sandboxes with no live server past a lifetime bound: past the
  idle bound they are parked to `suspended` (the sprite stays, scaled to zero,
  and the next prompt reattaches — decisions/0017); past the max-lifetime
  ceiling they are destroyed through the machine's owner, sprite and all
  (ADR 0058 stage 5b; it used to be the row here and the sprite on pass 2).

  This is the half of #167 that the ConversationServer cannot do. The server
  enforces its own bounds while it is alive, but a sandbox whose server
  died — a crash, a node that left the cluster, a deploy that happened to land
  between the rehydrator's scan and a reattach — has nothing watching it. The
  83-day-old sandbox in production was exactly that: `ready`, no server, alive
  since 2026-05-10.

  `suspended` rows deliberately match no pass: that is the durable resting
  state, aged out by nothing (decisions/0017).

  Activity includes turn insertion, start, completion and the last wake rather
  than `sandboxes.updated_at` or `conversations.updated_at`, both of which get
  touched by bookkeeping the user had nothing to do with — the rehydrator moves
  `conversations.updated_at` on every boot, which would make an abandoned
  conversation look freshly active after each deploy.

  Returns `{parked, expired, refused, skipped}` — machines parked, machines
  reclaimed, machines the owner could not reach, and machines it deliberately
  left alone. The third is separate because `expired` is a finance-board gauge
  and must keep meaning "reclaimed"; the fourth because the third is a defect
  gauge and must keep meaning "still there, and wrong". See `perform/1`'s
  telemetry comment (ADR 0058 stages 5b and 6b).
  """
  def sweep_abandoned_sandboxes do
    idle = Lifecycle.idle_timeout_seconds()
    max_lifetime = Lifecycle.max_lifetime_seconds()

    if is_nil(idle) and is_nil(max_lifetime) do
      {0, 0, 0, 0}
    else
      now = DateTime.utc_now()
      grace_cutoff = DateTime.add(now, -@abandoned_grace_minutes * 60, :second)

      # The lease clock is the database's since stage 7a — `lease_until` is
      # written from that clock in SQL, so judging it against this node's
      # `DateTime.utc_now()` compared two clocks. Fetched once for the page, so
      # every row gets one verdict; `now` above goes on judging the grace
      # windows against the same wall clock the columns they read (`updated_at`,
      # `woken_at`) are written from.
      lease_now = Lease.now()

      candidates =
        Sandbox
        |> where(
          [s],
          s.status == "ready" and s.updated_at < ^grace_cutoff
        )
        # And not a machine on its way out, in the words that outlive the
        # column beside them (stage 9a). Idle-parking or expiring a fenced
        # machine would be this sweep deciding the end of a machine whose end
        # somebody else already decided.
        |> where(^not_destroying())
        # And the wake-registration marker on the same grace (ADR 0058 stage
        # 6a). This is the pass the registry lag actually bites: a wake that
        # finds a `ready` row and starts a server on it writes no status, so
        # `updated_at` alone says nothing happened, and a reaper on another
        # node can still read the registry as empty. See `@abandoned_grace_minutes`.
        |> where([s], ^woken_grace(now))
        |> Repo.all()
        |> Repo.preload(:conversations)
        |> Enum.reject(&Lifecycle.any_server_alive?/1)

      # A machine whose owner holds a live lease is mid-operation, and asking
      # it would mean waiting out `Park.busy_wait_ms/0` — five seconds — for an
      # answer already on the row. `sweep_fenced_teardowns/0` has read the
      # lease this way since 5a; since 6b, when a park takes one on every
      # sweep, this pass had to as well, or a busy fleet would spend most of
      # its run asleep. It is not a correctness check — the claim is, and it
      # re-reads everything — it is the cost of asking.
      #
      # Counted rather than dropped. `skipped` means "decided to act, then
      # deliberately left the machine alone", and this is exactly that one step
      # earlier; a machine that appears in no counter at all is one an operator
      # reading the summary cannot account for.
      {held, free} = Enum.split_with(candidates, &Lease.live?(&1, lease_now))

      Enum.each(held, fn sandbox ->
        Logger.info(
          "reaper: left sandbox #{sandbox.id} (#{sandbox.machine_name}) to its owner, " <>
            "which holds the lease until #{inspect(sandbox.lease_until)}"
        )
      end)

      {parked, expired, refused, skipped, _destroys_left, _attempts_left} =
        Enum.reduce(
          Enum.map(free, &{&1, check_bounds(&1, now)}),
          {0, 0, 0, length(held), destroy_limit(), owner_attempt_limit()},
          &sweep_verdict/2
        )

      {parked, expired, refused, skipped}
    end
  end

  # One verdict, against the run's remaining destroy budget.
  #
  # `expired` counts machines this sweep actually reclaimed and `refused` the
  # ones it could not, because since ADR 0058 stage 5b `expire/3` goes through
  # the machine's owner and the owner can say no. Counting the verdict instead
  # of the outcome — which is what this did when `expire/2` could not fail —
  # reports a still-running, still-billing machine as expired.
  #
  # **A refusal does not spend the budget**, and that asymmetry is deliberate.
  # The budget exists to bound calls to the provider, and the refusal that
  # matters in practice — `:machine_busy`, another owner holding the lease —
  # is decided before the fence and makes no call at all. Charging it anyway
  # meant a run of 25 refusals left pass 2 with nothing, so an outage that
  # reclaimed no machines *also* stopped the leftover-sprite pass collecting
  # the ones already known dead, and those keep billing with no other pass
  # looking at them. A refusal from the *finalize* does follow a provider call,
  # so this can undercount by that much; over-counting a handful of calls
  # during an outage is the better error than locking out the pass that cleans
  # up after one.
  #
  # The run's *attempt* budget is spent by every verdict that reaches an owner,
  # whatever the owner says, because what it bounds is the waiting rather than
  # the writing. See `@owner_attempt_limit`.
  defp sweep_verdict({sandbox, {:expired, :idle}}, {p, e, r, s, left, attempts})
       when attempts > 0 do
    case idle_sweep(sandbox, left) do
      :parked -> {p + 1, e, r, s, left, attempts - 1}
      :expired -> {p, e + 1, r, s, left - 1, attempts - 1}
      :refused -> {p, e, r + 1, s, left, attempts - 1}
      :skipped -> {p, e, r, s + 1, left, attempts - 1}
      :deferred -> {p, e, r, s, left, attempts - 1}
    end
  end

  defp sweep_verdict({sandbox, {:expired, :max_lifetime}}, {p, e, r, s, left, attempts})
       when left > 0 and attempts > 0 do
    case expire(sandbox, :max_lifetime, "past max lifetime") do
      :expired -> {p, e + 1, r, s, left - 1, attempts - 1}
      :refused -> {p, e, r + 1, s, left, attempts - 1}
    end
  end

  defp sweep_verdict({sandbox, {:expired, _bound}}, acc) do
    defer(sandbox, acc)
    acc
  end

  defp sweep_verdict({_sandbox, :ok}, acc), do: acc

  # The run has spent one of its two budgets. The row keeps its live status and
  # no fence, so the next run sees it unchanged and deals with it then — which
  # is exactly what a budget is for. Counted as neither expired nor refused:
  # nothing was attempted and nothing went wrong.
  defp defer(%Sandbox{} = sandbox, {_p, _e, _r, _s, _left, attempts}) do
    spent =
      if attempts > 0,
        do: "its #{destroy_limit()} provider destroys",
        else: "its #{owner_attempt_limit()} owner attempts"

    Logger.info(
      "reaper: deferred sandbox #{sandbox.id} (#{sandbox.machine_name}) — " <>
        "this run has spent #{spent}"
    )

    :deferred
  end

  # Same clock as ConversationServer.sandbox_clock_start/1: the max-lifetime
  # ceiling measures a continuous run, restarting on a wake from `suspended`.
  #
  # The activity fold is `Occupancy.last_activity_at/1` since ADR 0058 stage
  # 6b, where it used to be a copy of it here. `Machines.Park` re-runs this
  # verdict under the machine's lease before it parks anything (#2307
  # constraint 1), and a recheck that asks a subtly different question from the
  # one the scan asked would refuse parks the scan was right about. One fold.
  defp check_bounds(sandbox, now) do
    Lifecycle.check(
      Lifecycle.clock_start(sandbox),
      Occupancy.last_activity_at(sandbox),
      false,
      now
    )
  end

  # Idle with no server: park through the machine's owner (ADR 0058 stage 6b),
  # which re-reads everything this scan decided on — the status, both fences,
  # the provider's `:suspend` capability, who is on the machine, and this
  # verdict — under the machine's lease, then checkpoints, suspends and writes
  # the row. The sweep no longer suspends anything or writes anything itself;
  # what is left here is the scan, the budget and the counters.
  #
  # The two degradations are unchanged and now come back as answers rather than
  # being decided here: a provider that cannot park and a suspend call that
  # failed both expire the machine instead, because an unparked sandbox keeps
  # billing (decisions/0017).
  defp idle_sweep(sandbox, destroys_left) do
    case Machine.park(sandbox.id,
           actor: "system:sandbox_reaper",
           reason: :idle,
           # No `requesting_conversation_id`: the reaper is on nobody's behalf,
           # so *any* live server on the machine refuses this park — which is
           # the liveness rule this sweep has always had, now applied under the
           # lease instead of before it.
           #
           # No `notify` either: an abandoned machine's conversations were
           # never told it had been parked, and a park is reversible — the next
           # prompt wakes it through the ordinary reattach path.
           verdict: {:expired, :idle}
         ) do
      {:ok, :parked} ->
        Logger.info(
          "reaper: parked idle sandbox #{sandbox.id} (#{sandbox.machine_name}) — " <>
            "ready with no live server past the idle bound"
        )

        :parked

      # The machine ended up parked, just not by this call — another owner got
      # there first. Counted, because `parked` is a gauge of machines at rest.
      {:ok, :already_parked} ->
        :parked

      # An abandoned park cleared off a machine that is still running, or a row
      # somebody else finished. Nothing was reclaimed and nothing was refused;
      # the next pass looks again at a row that now says what it means.
      {:ok, outcome} when outcome in [:recovered, :already_terminal] ->
        Logger.info(
          "reaper: idle sandbox #{sandbox.id} (#{sandbox.machine_name}) settled as #{outcome}"
        )

        :skipped

      {:error, :cannot_park} ->
        expire_within(sandbox, destroys_left, "idle on a provider without suspend")

      {:error, :suspend_failed} ->
        expire_within(sandbox, destroys_left, "idle; suspend call failed")

      # A reset or a teardown landed between this scan's `where` clause and the
      # lease. Somebody else owns the end of this machine, and
      # `sweep_fenced_teardowns/0` is already the backstop for a fence whose
      # owner dies, so this is neither a reclamation nor a failure to report.
      {:error, :fenced} ->
        :skipped

      # Constraint 1 doing its job: somebody started using this machine, or it
      # is no longer past a bound, between this sweep's scan and the claim. The
      # sweep was wrong and the owner said so — that is not a machine it failed
      # to reclaim, so it does not go on the defect gauge.
      {:error, refusal} when refusal in [:machine_occupied, :not_expired] ->
        Logger.info(
          "reaper: left idle sandbox #{sandbox.id} (#{sandbox.machine_name}) alone: " <>
            "#{refusal}"
        )

        :skipped

      {:error, refusal} ->
        Logger.warning(
          "reaper: could not park idle sandbox #{sandbox.id} " <>
            "(#{sandbox.machine_name}): #{inspect(refusal)}"
        )

        :refused
    end
  end

  # Both of these arms destroy a machine at the provider, so both spend from
  # the run's budget — the suspend-failure one especially, since a provider
  # whose suspend is down sends every idle row here at once.
  defp expire_within(sandbox, destroys_left, reason) when destroys_left > 0,
    do: expire(sandbox, :idle, reason)

  defp expire_within(sandbox, _spent, _reason) do
    Logger.info(
      "reaper: deferred expiry of sandbox #{sandbox.id} (#{sandbox.machine_name}) — " <>
        "this run has spent its #{destroy_limit()} provider destroys"
    )

    :deferred
  end

  # A machine past a lifetime bound with nobody holding it. Since ADR 0058
  # stage 5b this goes through the machine's owner rather than writing the row
  # itself, so the provider machine dies **in this call** instead of on pass 2
  # of the same run. Pass 2 is still the safety net and still sees this row:
  # it lists terminal rows whose sprite is still at the provider, and a machine
  # this destroy reached is no longer in that listing, so there is no second
  # provider call for it.
  #
  # `terminating_conversation_id: nil`, which is the whole reason this sweep
  # can do anything at all. An abandoned `ready` row usually still has
  # conversations bound to it — that is what makes it abandoned rather than
  # empty — and a conversation id here would make the fence answer
  # `:sandbox_kept` on every one of them, on a machine with no server, past its
  # ceiling, that nothing else would ever expire. It would bill forever.
  #
  # Two events, deliberately. `sandbox.expired` is the reaper's own record of
  # *why* the machine was taken away — the bound it crossed, in the tenant's
  # trail where "my agent's sandbox vanished" gets an answer (#551) — and
  # `sandbox.destroyed` from the protocol is the record that it *was*. Kept on
  # the same success-only rule the rest of this worker follows: a refusal
  # records nothing, because nothing happened to the tenant's machine.
  #
  # A refusal is logged and the sweep carries on. These are machines the fleet
  # has already lost track of; one that cannot be reached right now must not
  # stop the other passes, and `sweep_fenced_teardowns/0` finishes a row whose
  # fence committed and whose destroy did not.
  defp expire(sandbox, reason_atom, reason) do
    # ownership: `sandbox` came from this worker's own fleet-wide scan; the
    # reaper is a system sweep with no tenant of its own (`contributing/server.md`).
    case Termination._unsafe_destroy_machine(sandbox.id,
           actor: "system:sandbox_reaper",
           destroy_reason: reason_atom,
           reason: "sandbox_expired",
           terminating_conversation_id: nil
         ) do
      {:ok, outcome} ->
        Logger.info(
          "reaper: expired abandoned sandbox #{sandbox.id} (#{sandbox.machine_name}) — " <>
            "ready with no live server, #{reason} (#{outcome})"
        )

        record_reap(sandbox, "sandbox.expired", %{"reason" => reason})

        # The conversation is deliberately left alone. It stays resumable, and
        # the next prompt provisions a fresh sandbox (the runtime session on
        # the destroyed disk is lost — the price of the ceiling, see
        # decisions/0017).
        :expired

      {:error, refusal} ->
        Logger.warning(
          "reaper: could not expire abandoned sandbox #{sandbox.id} " <>
            "(#{sandbox.machine_name}): #{inspect(refusal)}"
        )

        :refused
    end
  end

  # ── pass 1c: destroys that were asked for and then abandoned ──────────────

  # A destroy is asked for before it is done. The fence — a teardown's
  # (`Lifecycle.fence_sandbox_for_teardown/2`) or a reset's
  # (`Conversations.reset_sandbox/2`) — commits `transition: "destroying"` in
  # its own transaction, before any provider I/O, and the machine's owner
  # finishes the destroy after it. Anything in between can lose: the provider
  # call raises or never confirms, the owner's node dies, an account deletion
  # halts mid-fence.
  #
  # What is left is a live row stamped `destroying` with no owner working on
  # it. Every reader refuses it (ADR 0058 stage 9a: `destroying` is the one
  # durable transition), `Quotas` counts it against the tenant cap and the
  # fleet ceiling, and the machine bills. This pass is the only thing that
  # finishes it, and it never *starts* a destroy: the stamp is the request, so
  # a row only reaches here because a caller already decided this machine was
  # to go away.
  #
  # **One driver since stage 9b, on its own five-minute run** (`perform/1`'s
  # `"teardowns"` clause, `config/config.exs`). Until then there were two:
  # this pass, hourly and sharing the run's destroy budget with the expiries,
  # and `SandboxResetReconciler`, every five minutes and unbudgeted, for the
  # persistent homes a reset or a forced teardown had fenced. Stage 9a's
  # review found that the hourly pass was safe only because the reconciler
  # reached the persistent homes, so folding the reconciler into the hourly
  # pass would have made an abandoned reset, or a forced teardown whose caller
  # died, wait up to an hour and a quarter instead of five minutes. The pass
  # moved to the reconciler's clock instead, took its rows, and stopped
  # sharing a budget. Its cap is `@owner_attempts_per_sweep` — the attempts
  # one run may make, whatever the owners answer — and the `:maintenance`
  # queue runs one job at a time, so a backlog drains one machine at a time
  # rather than arriving at the provider at once.
  #
  # **Two kinds of row, told apart by the stamp's reason.**
  #
  #   * A **reset** (`transition_reason: "reset"`) is retried at once and
  #     through the reset's own door, `Conversations.retry_pending_sandbox_reset/2`,
  #     which is what `SandboxResetReconciler` called: a reset stays retryable
  #     by design until a provider *confirms* the machine is gone, and its
  #     completion tells the conversations on the home something a reclaim
  #     does not (their transcript survives; the next prompt builds a fresh
  #     machine). No grace window and no liveness scan, as the reconciler had
  #     none: `reset_sandbox/2` refuses a machine with a turn running, and the
  #     servers on a reset home are told through their own cast.
  #   * **Anything else** is a teardown, finished through the owner after
  #     `@fenced_teardown_grace_minutes` and only once no server holds the
  #     machine, exactly as this pass has since stage 9a.
  @fenced_teardown_grace_minutes 15

  # How many machines one run of this pass may ask an owner about, whatever
  # the owner says. `@owner_attempt_limit`'s argument: a refusal costs
  # `Destroy.busy_wait_ms/0`, so without this a fleet of contended fences would
  # spend the whole of a `:maintenance` slot refusing. With no destroy budget
  # since stage 9b, it is also the cap on provider calls per run.
  @owner_attempts_per_sweep 100

  @doc false
  # Overridable like `owner_attempt_limit/0` and `destroy_limit/0`, so the cap
  # can be driven with two rows instead of a hundred and one. Nothing in `lib/`
  # sets it.
  def owner_attempts_per_sweep,
    do: Application.get_env(:fountain, :reaper_sweep_attempt_limit) || @owner_attempts_per_sweep

  @doc """
  Drives to completion the destroys that were asked for and then abandoned.

  A live row stamped `destroying` is refused by every reader and holds its
  quota slot for as long as it stands, so this is the only thing that can free
  it. A row whose machine lease is live is skipped: an owner is working on it,
  and this pass would be finishing a destroy that has not failed. An expired
  lease, or none, is the abandonment this pass is for.

  A reset is retried through `Conversations.retry_pending_sandbox_reset/2`,
  at once, on a provider this deployment has credentials for. A teardown is
  finished by **asking the machine's owner**
  (`Termination._unsafe_destroy_machine/2`), which claims a lease, continues
  from the stamp, destroys at the provider and finalizes under its epoch — and
  only after the grace window, measured from the stamp, and once no server
  holds the machine.

  Returns `{reconciled, refused}` — destroys driven to terminal, and rows that
  were refused or could not be confirmed. See `perform/1`.
  """
  def sweep_fenced_teardowns do
    now = DateTime.utc_now()
    cutoff = DateTime.add(now, -@fenced_teardown_grace_minutes * 60, :second)

    # The lease clock is the database's since stage 7a; the grace window is
    # judged against the wall clock `updated_at` was written from. One fetch
    # for the whole sweep, so a page is one verdict.
    lease_now = Lease.now()

    Sandbox
    |> where([s], s.status not in ^@terminal_statuses and s.transition == ^@destroying)
    # The grace window runs from the row's last write, which for a stamped row
    # is the stamp: every reader refuses a `destroying` row, and a
    # `cas_update/4` moves `updated_at` with a state change and deliberately not
    # with a renewal, so nothing writes it again until the destroy finishes.
    # A reset has no window, as `SandboxResetReconciler` had none.
    |> where([s], s.transition_reason == ^@reset_reason or s.updated_at < ^cutoff)
    # Oldest stamp first, and deterministically. With a cap on attempts the
    # *order* of a sweep is part of its behaviour — with more rows than
    # attempts, whichever rows come last are deferred to the next run — and an
    # unordered scan would pick a different set each time. `id` breaks ties so
    # two stamps committed in one transaction have an order at all.
    |> order_by([s], asc: s.updated_at, asc: s.id)
    # A machine whose owner holds a live lease is not an abandoned destroy; it
    # is one in flight (ADR 0058). Asked in Elixir, through `Lease.live?/2`,
    # rather than as a `where` of its own: stage 6a folded the copies of this
    # question into that one predicate, and a SQL rendering beside it would
    # drift from what `Lease.claim/4` actually decides on.
    |> Repo.all()
    |> Repo.preload(:conversations)
    # `or` short-circuits, so a row a lease is holding costs no registry scan,
    # and a reset costs none at all.
    |> Enum.reject(fn sandbox ->
      Lease.live?(sandbox, lease_now) or
        (not reset?(sandbox) and Lifecycle.any_server_alive?(sandbox))
    end)
    |> Enum.reduce({0, 0, owner_attempts_per_sweep()}, &drive_teardown/2)
    |> then(fn {reconciled, refused, _attempts} -> {reconciled, refused} end)
  end

  defp reset?(%Sandbox{transition_reason: reason}), do: reason == @reset_reason

  # One verdict, against this run's attempt cap. Every answer charges an
  # attempt, whatever it was.
  defp drive_teardown(sandbox, {reconciled, refused, attempts}) when attempts > 0 do
    case finish(sandbox) do
      :ok -> {reconciled + 1, refused, attempts - 1}
      :refused -> {reconciled, refused + 1, attempts - 1}
      :noop -> {reconciled, refused, attempts - 1}
    end
  end

  # The cap is spent. The row keeps its stamp, so the next run sees it
  # unchanged — which is what a cap is for, and why this is counted as neither:
  # nothing was attempted and nothing went wrong.
  defp drive_teardown(%Sandbox{} = sandbox, acc) do
    Logger.info(
      "reaper: deferred the abandoned destroy of sandbox #{sandbox.id} " <>
        "(#{sandbox.machine_name}) — this run has spent its " <>
        "#{owner_attempts_per_sweep()} owner attempts"
    )

    acc
  end

  defp finish(%Sandbox{} = sandbox) do
    if reset?(sandbox), do: finish_reset(sandbox), else: finish_teardown(sandbox)
  end

  # `SandboxResetReconciler`'s per-sandbox job, moved here whole: the reset's
  # own door, which re-reads the row scoped to its tenant, refuses a live lease
  # as `:sandbox_unavailable`, probes and destroys through the owner, and on a
  # confirmed destroy records `sandbox.reset` and tells the conversations on
  # the home. A provider this deployment has no credentials for is skipped
  # rather than asked; the reconciler snoozed the job for the same reason, and
  # the next run is the retry.
  defp finish_reset(%Sandbox{} = sandbox) do
    if Fountain.SandboxProviders.enabled?(Conversations.sandbox_provider_atom(sandbox)) do
      # ownership: `sandbox` came from this worker's own fleet-wide scan; the
      # door re-reads it by `(id, user_id)` from the row itself.
      case Conversations.retry_pending_sandbox_reset(sandbox, actor: "system:sandbox_reaper") do
        {:ok, %Sandbox{}} ->
          :ok

        {:ok, _skipped} ->
          :noop

        {:error, reason} ->
          Logger.warning(
            "reaper: abandoned reset of sandbox #{sandbox.id} (#{sandbox.machine_name}) " <>
              "is still unconfirmed: #{inspect(reason)}; left for the next pass"
          )

          :refused
      end
    else
      :noop
    end
  end

  # Ask the machine's owner to finish what the fence started (ADR 0058 stage
  # 9a). `Machines.Destroy` claims a lease, re-reads the row, continues from
  # the `destroying` stamp, destroys at the provider and finalizes by
  # compare-and-set, and `sandbox.destroyed` records who did it.
  #
  # `terminating_conversation_id: nil`, for `expire/3`'s reason and more
  # plainly: an abandoned teardown is a machine somebody already decided was to
  # go, and a conversation id here would answer `:sandbox_kept` on every row
  # that still has one bound.
  #
  # The call has **no deadline**, where 8a's `ensure_up` and 8b's attach and
  # detach carry one. A late destroy is idempotent (stage 5a), and there is no
  # caller to be late for — this is a cron sweep, and the next run would do the
  # same thing.
  #
  # A refusal is logged and the sweep carries on, and a raise cannot reach
  # `perform/1` from here: these rows are already the leftovers of a failure,
  # and one bad row must not block machine cleanup for the whole fleet.
  defp finish_teardown(%Sandbox{} = sandbox) do
    # ownership: `sandbox` came from this worker's own fleet-wide scan; the
    # reaper is a system sweep with no tenant of its own (`contributing/server.md`).
    case Termination._unsafe_destroy_machine(sandbox.id,
           actor: "system:sandbox_reaper",
           destroy_reason: destroy_reason(sandbox),
           reason: "teardown_reconciled",
           terminating_conversation_id: nil
         ) do
      {:ok, :destroyed} ->
        report_finished_teardown(sandbox)

      # Somebody else finished this row between the scan and the claim. Nothing
      # was reclaimed by this pass and nothing was refused, so it goes on
      # neither gauge — `idle_sweep/2`'s reading of the same outcome.
      {:ok, outcome} ->
        Logger.info(
          "reaper: abandoned teardown of sandbox #{sandbox.id} " <>
            "(#{sandbox.machine_name}) settled as #{outcome}"
        )

        :noop

      {:error, reason} ->
        Logger.error(
          "reaper: could not finish abandoned teardown of sandbox #{sandbox.id} " <>
            "(#{sandbox.machine_name}): #{inspect(reason)}; left for the next pass"
        )

        :refused
    end
  end

  # The reason the fence recorded, handed back to the protocol so that the row
  # it writes and the `sandbox.destroyed` it records say what the caller who
  # asked for this teardown said — rather than a word this sweep invented for a
  # decision it did not make. `Machines.Destroy` owns that vocabulary and the
  # conversion (`reason_from_string/1`), a total match over a closed set.
  defp destroy_reason(%Sandbox{transition_reason: reason}),
    do: Destroy.reason_from_string(reason)

  defp report_finished_teardown(sandbox) do
    was = sandbox.status

    Logger.warning(
      "reaper: finished abandoned teardown of sandbox #{sandbox.id} " <>
        "(#{sandbox.machine_name}) — stamped at #{inspect(sandbox.updated_at)}, " <>
        "still #{was} #{@fenced_teardown_grace_minutes}m later"
    )

    # Two events, as `expire/3` has two and for its reason: `sandbox.destroyed`
    # from the protocol is the record that the machine *was* destroyed, and
    # this one is the reaper's own record of **why** it was this pass that did
    # it — a fence whose owner never came back, which is a defect upstream and
    # the thing an operator reading the trail needs to see.
    #
    # The conversations are left alone for the same reason `expire/3` leaves
    # them: reclaiming a machine is not deleting the thread that ran on it.
    record_reap(sandbox, "sandbox.teardown_reconciled", %{
      "previous_status" => was,
      "transition_reason" => sandbox.transition_reason,
      "grace_minutes" => @fenced_teardown_grace_minutes
    })

    :ok
  end

  # ── pass 2: terminal rows whose sprite is still there ─────────────────────

  defp destroy_dead_sprites(_live_by_provider, budget) when budget <= 0, do: 0

  defp destroy_dead_sprites(live_by_provider, budget) do
    Sandbox
    |> where([s], s.status in ^@terminal_statuses)
    |> select([s], {s.id, s.machine_name, s.provider})
    |> Repo.all()
    |> Enum.filter(fn {_id, name, provider} ->
      case Map.fetch(live_by_provider, provider_atom(provider)) do
        # Rows on a provider whose listing failed (or that is disabled) are
        # skipped, not destroyed — the next run with credentials converges.
        {:ok, live_names} -> MapSet.member?(live_names, name)
        :error -> false
      end
    end)
    |> Enum.take(budget)
    |> Enum.count(fn {id, name, provider} -> destroy(id, name, provider_atom(provider)) end)
  end

  defp provider_atom(provider), do: Conversations.sandbox_provider_atom(%{provider: provider})

  defp destroy(sandbox_id, machine_name, provider) do
    # build_handle/2 is pure — we already know the sandbox exists (it came
    # out of the listing), so there is nothing to look up first.
    case Managoat.Sandbox.destroy(Managoat.Sandbox.build_handle(provider, machine_name)) do
      :ok ->
        Logger.info("reaper: destroyed leaked sprite #{machine_name} (sandbox #{sandbox_id})")
        true

      {:error, reason} ->
        # Left for the next run rather than retried here; the row stays terminal
        # either way, so nothing is lost by being slow about it.
        Logger.warning("reaper: destroy failed for #{machine_name}: #{inspect(reason)}")
        false
    end
  end

  # ── pass 3: sprites with no row — counted, never touched ──────────────────

  @doc false
  def report_untracked(live_by_provider) do
    Enum.reduce(live_by_provider, 0, fn {provider, live_names}, total ->
      known =
        Sandbox
        |> where([s], s.provider == ^Atom.to_string(provider))
        |> select([s], s.machine_name)
        |> Repo.all()
        |> MapSet.new()

      untracked = MapSet.difference(live_names, known)
      count = MapSet.size(untracked)

      if count > 0 do
        sample = untracked |> Enum.sort() |> Enum.take(10) |> Enum.join(", ")

        Logger.info(
          "reaper: #{count} #{provider} sandbox(es) have no sandbox row and were " <>
            "left alone (sample: #{sample})"
        )
      end

      :telemetry.execute([:fountain, :reaper, :untracked], %{count: count}, %{
        provider: provider
      })

      total + count
    end)
  end

  # ── sprites.dev ───────────────────────────────────────────────────────────

  # One listing per provider, isolated: one backend being down must not stop
  # another's reconciliation. Sprites is always attempted (the historical
  # default may hold rows even when its credential was pulled); other
  # providers only when enabled. Pagination is the adapter's problem — a
  # first-page-only listing looks complete, which for a function that decides
  # what to delete is the worst possible shape of wrong, so adapters return
  # {:error, :truncated} rather than a partial view.
  defp list_by_provider do
    [:sprites | Fountain.SandboxProviders.enabled_providers()]
    |> Enum.uniq()
    |> Map.new(fn provider -> {provider, safe_list(provider)} end)
  end

  defp safe_list(provider) do
    Managoat.Sandbox.list_all_names(provider)
  rescue
    e -> {:error, e}
  end
end
