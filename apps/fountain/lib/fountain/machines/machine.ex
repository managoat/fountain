defmodule Fountain.Machines.Machine do
  @moduledoc """
  The owner of one machine (ADR 0058).

  One process per *active* sandbox, registered in `Fountain.MachineRegistry`
  under the sandbox id and supervised by `Fountain.MachineSupervisor`, both
  Horde members so the owner is addressable from any node. It idle-stops after
  a minute with nothing asked of it, and `ensure_started/1` brings it back:
  there is a process per active machine, not one per row.

  Ten verbs so far. `who_is_here/1` returns the
  `Fountain.Machines.Occupancy` struct and reads nothing else. `destroy/2`,
  `park/2` and `ensure_up/2` run `Fountain.Machines.Destroy.run/2`,
  `Fountain.Machines.Park.run/2` and `Fountain.Machines.Resume.run/2` — three of
  the five protocols, lease and all. `provision/3`, `confirm_up/2` and
  `fail_provision/2` are the fourth, `Fountain.Machines.Provision`, which builds
  a machine, confirms one a server is reattaching to, and retires one whose
  provisioning is not going to happen. `admit_turn/3`, `end_turn/3` and the
  predicate `at_capacity?/3` are the fifth, `Fountain.Machines.Admission`
  (stage 8a): the locked turn insert with the live-lease refusal and the
  per-runtime capacity count decided under its lock, and the one door every
  turn-ending write an actor makes comes through. Between them they are
  everything here that writes: the row through `Fountain.Machines.Lease`, the
  provider through `Managoat.Sandbox.create/2`, `destroy/1`, `suspend/1` and
  `resume/1`, the turn rows through the context's locked writers, and one
  `sandbox.destroyed`, `sandbox.suspended`, `sandbox.resumed`,
  `sandbox.provisioned` or `sandbox.provision_failed` audit event. `attach`,
  `detach` and `retarget` arrive in stage 8b.

  Beside them is one predicate, `busy?/2` (stage 6a): whether an owner holds a
  live lease on a machine, from the row the caller already holds. It is the
  question every reader that was about to start work on a machine now asks
  first, and the answer it turns into is `:sandbox_unavailable`. It stopped
  being *pure* in stage 7a, when the clock it judges against became the
  database's: left to default it costs one `select statement_timestamp()`, and a
  caller with a page of rows passes `Fountain.Machines.Lease.now/0` in once.

  ## What the gate chooses

  With `MACHINE_OWNER_ENABLED` on, `destroy/2`, `park/2`, `ensure_up/2` and
  `admit_turn/3` are calls into this process, so two operations on one machine
  queue behind one another in its mailbox. With it off, the protocols run
  inline on the caller.
  **Same protocol either way**
  — the same fence, the same lease, the same compare-and-set, the same event —
  because the thing that makes a destroy safe against a concurrent destroy is
  the lease on the row, not the mailbox in front of it. The process is an
  optimization of the contention, not the correctness. That is also why there
  is no second, older destroy path left behind the gate: there is one, and the
  flag picks where it runs.

  **The provision verbs are the exception, and they say so.** `provision/3`,
  `confirm_up/2` and `fail_provision/2` run inline on their caller whichever way
  the gate is set. The first is why: its callback is the
  `ConversationServer`'s own pipeline, which builds that server's state and runs
  for minutes, and running it inside this process would both move the pipeline
  out of the server (ADR 0037, #1369) and occupy the owner past every timeout in
  this tree. The other two follow it so that one verb family has one answer.
  `Fountain.Machines.Provision`'s moduledoc argues it in full; what makes it
  sound is the paragraph above — the lease is the correctness, the mailbox is
  the optimization — and the contention a provision has is a duplicate server,
  which the lease refuses in one round trip.

  **`end_turn/3` is the other exception** (stage 8a), and for the opposite
  reason: it is not a machine operation at all. It ends a turn — a write to the
  conversation's rows under their own locks, with no provider call and no
  machine state changed — and the owner's view of admitted turns is those rows,
  read under its lease when a park or a destroy needs them. Queueing a turn's
  end behind a cotenant's minute-long park would hold a server's `terminate/2`
  or adapter-exit path in a `GenServer.call`, and a timeout there leaves the
  turn `running` with nothing left to end it. `Fountain.Machines.Admission`'s
  moduledoc argues it; the fence it applies is the same either way.

  Asking through a process for an answer available from a pure function looks
  like ceremony, and it is the point: `who_is_here/1` is the door every writer
  comes through once the writes move here, so the callers moved first, while
  moving them still changed nothing. With the gate off, `who_is_here/1` reads
  `Occupancy` directly and starts nothing at all, so the gate governs whether
  the process exists, never what the answer is.

  ## The read that walks past a busy owner

  A GenServer is serial, so a destroy occupies this process for as long as it
  takes, and a `who_is_here/1` that arrives meanwhile waits behind it. Past
  `@call_timeout` that read gives up, logs, and reads `Occupancy` directly —
  correct, because the verb is read-only and a slightly late reading of who is
  on a machine harms nobody. Stage 4 wrote here that the fallback would have to
  go before `admit_turn` landed, on the reasoning that a writer deciding on the
  struct would be two owners again. Stage 8a's admission does not decide on the
  struct: it re-reads the machine's row and counts the running turns **under
  the advisory lock, inside its own transaction**, and with the gate on it
  refuses rather than falls back when the owner cannot be reached, exactly as
  `destroy/2` does. So the fallback stays where it is, for the one verb that
  only looks; stage 8b's `attach` and `detach` are held to the same rule.
  """

  # `:transient` — an idle-stop exits `:normal` and Horde leaves it stopped,
  # which is what makes this one process per *active* machine; an abnormal
  # exit is restarted, and the replacement then holds a registry slot for a
  # full idle window although nobody asked it anything. That is the right
  # trade from stage 5 on, when the owner holds a lease it must reclaim, and
  # it is merely harmless now, when it holds nothing.
  use GenServer, restart: :transient

  require Logger

  alias Fountain.Conversations.Sandbox
  alias Fountain.Conversations.Turn
  alias Fountain.Machines
  alias Fountain.Machines.Admission
  alias Fountain.Machines.Destroy
  alias Fountain.Machines.Lease
  alias Fountain.Machines.Occupancy
  alias Fountain.Machines.Park
  alias Fountain.Machines.Provision
  alias Fountain.Machines.Resume
  alias Fountain.Repo

  # Long enough that a burst of questions about one machine — a lifecycle
  # check, a reaper pass and a park decision inside the same minute — reuses
  # one process; short enough that a machine nobody has asked about leaves no
  # process behind. Overridable per process for the tests that drive it.
  @idle_ms 60_000

  # The call is one to three indexed reads. A timeout longer than the default
  # would only ever hide a repo that is already in trouble.
  @call_timeout 15_000

  # A destroy is a provider round trip plus four short transactions, and it may
  # wait out another destroy's lease first — `Destroy.busy_wait_ms/0`, five
  # seconds. This has to sit clearly *above* that bound and clearly *below*
  # `conversation_call_timeout_ms` (30s), the ceiling a `ConversationServer`'s
  # own client gives up at. Equal to the protocol's bound, a destroy that waits
  # its full wait races this timeout and a success gets reported as a failure;
  # equal to the client's, a caller learns nothing before its own caller has
  # given up. `machine_bounds_test.exs` pins the ordering.
  @destroy_timeout 20_000

  # One consequence worth stating, because it is asymmetric and a caller feels
  # it: a destroy waits `Destroy.busy_wait_ms/0` — five seconds — for a lease
  # that a *park* may hold for up to `Park.lease_ttl_ms/0`. So a `DELETE
  # /api/sandboxes/:id` that lands on a machine mid-park answers 503
  # `sandbox_unavailable` rather than queueing behind it, and the caller tries
  # again. That is the trade `machine_bounds_test.exs` spells out — the wait
  # bounds the *caller*, who is a person, and a park that outlives it is not a
  # reason to hold a web request open. The reset front door says as much in its
  # own 503 message.
  #
  # A park is a longer operation than a destroy and sits under a different
  # ceiling. Longer, because a home checkpoint is a provider round trip with
  # `Managoat.Sandbox.Retry`'s backoff behind it and the suspend follows it.
  # A different ceiling, because neither caller is a request: the conversation
  # server's park runs inside the server itself, from its own
  # `:lifecycle_check` message, so `call_server/2`'s 30s — the bound a
  # *client* of that server waits — is not over it, and the reaper's pass has
  # no client at all. What this does have to sit between is
  # `Park.busy_wait_ms/0` below it and `Park.lease_ttl_ms/0` above it:
  # a caller that gives up before the protocol's own wait would report a
  # refusal that had not happened yet, and one that outlives the lease would
  # wait on work another owner is entitled to take over.
  # `machine_bounds_test.exs` pins the ordering.
  @park_timeout 60_000

  # A resume is one provider round trip, like a destroy, so it takes the
  # destroy's ceiling and for the same reasons: clearly above
  # `Resume.busy_wait_ms/0` (5s), so a caller never reports a refusal the
  # protocol has not reached yet, and clearly below `Resume.lease_ttl_ms/0`
  # (60s), so it never waits on work another owner is entitled to take over.
  #
  # Unlike a park, this caller **is** a request: a prompt that wakes a parked
  # conversation runs on the request process, so the number is also what a
  # person waits before the page says something. A resume slower than this is
  # not abandoned — `Machines.Renewal` keeps its lease alive and the owner
  # finishes it — so the caller is told `sandbox_unavailable` with a
  # `Retry-After`, and the retry finds the machine up. Holding an HTTP request
  # open for a Daytona machine coming back from archived storage is the
  # alternative, and it is worse.
  #
  # With the gate off there is no ceiling at all, because there is no call: the
  # protocol runs inline on the caller and returns when it returns.
  # `machine_bounds_test.exs` pins the ordering.
  @resume_timeout 20_000

  # An admission is one transaction that may first wait out a live lease —
  # `Admission.busy_wait_ms/0`, five seconds — so it takes the destroy's
  # ceiling for the destroy's reasons: clearly above the protocol's own wait,
  # so a caller never reports a refusal the protocol has not reached, and
  # clearly below `conversation_call_timeout_ms` (30s), because this caller
  # **is** a request: `TurnMachine.open/6` runs inside the server's
  # `handle_call` for the prompt, and the person who sent it is waiting on the
  # other side. There is no lease TTL to sit under, because an admission takes
  # no lease (see `Fountain.Machines.Admission`). `machine_bounds_test.exs`
  # pins the ordering.
  #
  # **It bounds the caller's wait, not the queue** — and for this verb that
  # difference is a write (round 1, protocol and behaviour reviews). A
  # `GenServer.call` that times out leaves its message in the mailbox, and the
  # owner runs it when it gets there. For a destroy or a park a late run is
  # idempotent; for a resume it is a machine brought up for nobody (see the
  # `:ensure_up` clause); for an admission it is a turn row the prompt was
  # told does not exist — a `running` turn on a machine that has since been
  # parked, which nothing ends. So the message carries the caller's deadline
  # on the database clock (the owner may be on another node, so no node's
  # monotonic clock will do) and the owner refuses an admission whose deadline
  # has passed: once before it runs the protocol, and once more inside the
  # locked insert, against the clock it read the machine's row with. What
  # that bounds is the row *read*: a commit can still land one transaction
  # tail after the deadline (no lock wait sits in that tail; milliseconds in
  # practice). Closing the tail would mean the caller's `:timeout` arm going
  # back for a turn with its own `attrs`, not another clock read.
  @admit_timeout 20_000

  # A start that loses the Horde race registers on another node, and the
  # registry is a CRDT: the winner can be invisible here for a few
  # milliseconds. Same shape and the same reason as
  # `ConversationServer.await_registered/2` (#1429, #800).
  @settle_ms 3_000
  @poll_ms 25

  # ── public api ────────────────────────────────────────────────────────────

  @doc false
  def start_link(args) do
    sandbox_id = Keyword.fetch!(args, :sandbox_id)
    GenServer.start_link(__MODULE__, args, name: via(sandbox_id))
  end

  @doc """
  How long a caller waits on the owner for a destroy.

  Public so `machine_bounds_test.exs` can pin it between
  `Destroy.busy_wait_ms/0` below it and `conversation_call_timeout_ms` above.
  """
  @spec destroy_timeout_ms() :: pos_integer()
  def destroy_timeout_ms, do: @destroy_timeout

  @doc """
  How long a caller waits on the owner for a park.

  Public so `machine_bounds_test.exs` can pin it between `Park.busy_wait_ms/0`
  below it and `Park.lease_ttl_ms/0` above it.
  """
  @spec park_timeout_ms() :: pos_integer()
  def park_timeout_ms, do: @park_timeout

  @doc """
  How long a caller waits on the owner for a resume.

  Public so `machine_bounds_test.exs` can pin it between `Resume.busy_wait_ms/0`
  below it and `Resume.lease_ttl_ms/0` above it.
  """
  @spec resume_timeout_ms() :: pos_integer()
  def resume_timeout_ms, do: @resume_timeout

  @doc """
  How long a caller waits on the owner for a turn admission.

  Public so `machine_bounds_test.exs` can pin it between
  `Admission.busy_wait_ms/0` below it and `conversation_call_timeout_ms` above.
  """
  @spec admit_timeout_ms() :: pos_integer()
  def admit_timeout_ms, do: @admit_timeout

  @doc "The cluster-wide name of the owner of `sandbox_id`."
  @spec via(String.t()) :: {:via, module(), {module(), String.t()}}
  def via(sandbox_id), do: {:via, Horde.Registry, {Fountain.MachineRegistry, sandbox_id}}

  @doc """
  The owner's pid, or `nil` when no owner is registered *as far as this node
  can see*.

  Horde's registry is a CRDT, so `nil` is not proof of absence — never decide
  anything durable on one lookup (ADR 0058; #2307 constraint 4).
  """
  @spec whereis(String.t()) :: pid() | nil
  def whereis(sandbox_id) when is_binary(sandbox_id) do
    case Horde.Registry.lookup(Fountain.MachineRegistry, sandbox_id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc """
  The owner of `sandbox_id`, started if it is not running anywhere.

  Tolerates both halves of the Horde start race: a concurrent start on this
  node or another returns `{:error, {:already_started, pid}}`, and a start
  whose winner has not propagated into this node's registry yet is waited for.
  `opts` are passed to the child, which is how a test shortens `:idle_ms`.
  """
  @spec ensure_started(String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def ensure_started(sandbox_id, opts \\ []) when is_binary(sandbox_id) do
    case whereis(sandbox_id) do
      pid when is_pid(pid) -> {:ok, pid}
      nil -> start_child(sandbox_id, opts)
    end
  end

  @doc """
  Who is on `sandbox_id`: bound conversations, whose servers are live, which
  are mid-turn and on what runtime, and when the machine last saw activity.

  Always an `Occupancy` struct. With the gate on it is served by the owner, so
  the answer and the writes that follow it will share one process; with the
  gate off, and if the owner cannot be started, it is read directly. That
  fallback is deliberate: this verb is read-only, so a machine with no process
  is not a reason to fail a caller that only wanted to look.
  """
  @spec who_is_here(String.t()) :: Occupancy.t()
  def who_is_here(sandbox_id) when is_binary(sandbox_id) do
    if Machines.enabled?(), do: ask_owner(sandbox_id, 1), else: Occupancy.load(sandbox_id)
  end

  @doc """
  Is an owner mid-operation on this machine, right now (ADR 0058 stage 6a)?

  **A live lease, and nothing else.** `Fountain.Machines.Lease.live?/2`: a
  holder, and a deadline that has not passed. That is the same question
  `Lease.claim/4` answers when it refuses a claimant, so a reader and a
  claimant cannot disagree about who owns a machine.

  The readers that ask are the three that would otherwise start work on the
  machine underneath its owner: `Wake.maybe_reuse_sandbox/1`,
  `Launch.check_attachable/4` and `Rehydrator`'s boot sweep. Each turns `true`
  into the refusal the system already has, `:sandbox_unavailable` — 503 with a
  `Retry-After: 30`, `NotReadyError` in all four SDKs, snoozed by the launch
  queue and the schedule runner. Thirty seconds is an honest number precisely
  because this is a *live* operation: one provider round trip, and the machine
  settles.

  **A stamped `transition` is deliberately not enough** (round 1, surfaces
  review). It was, in the first draft of this function, and it was wrong. A
  `transition` with no live lease is not an owner working — it is an owner that
  *died* mid-operation, and nothing resolves that row until a sweep gives up on
  it: `SandboxReaper.sweep_fenced_teardowns/0` on the hourly cron, or
  `SandboxResetReconciler` every five minutes. Treating it as busy meant every
  wake and attach onto an abandoned destroy answered 503 for between 16 and 75
  minutes, where `main` probed the provider, found the machine gone and handed
  the caller a fresh one immediately; a team schedule gave up inside that window
  (`@wait_for`, 30 minutes) and a queued start could expire in it
  (`@default_max_wait_seconds`, an hour). `sweep_fenced_teardowns/0` calls such
  a row abandoned in as many words; two readers of one row must not disagree
  about it.

  So a stamped transition on a lease-less row reads exactly as it does on
  `main`: the wake probes, the attach checks identity, the boot sweep starts a
  server. Stage 6b's park takes a lease for the length of its checkpoint and
  suspend, so a park in flight is refused here; a *stale* `parking` row left by
  a dead owner is resolved by the park protocol's own takeover, from the owner's
  side, which is where an abandoned operation belongs.

  Takes a `Sandbox` the caller has already read, so the row costs no query, and
  the clock, so a sweep can judge a page of rows against one instant.

  **The clock is the database's** (stage 7a), because that is what
  `lease_until` is now written from. Left to default, this fetches it — one
  `select statement_timestamp()` beside the row read the caller has already
  done. A caller with more than one row to judge fetches it once with
  `Fountain.Machines.Lease.now/0` and passes it, which is what the two reaper
  sweeps, the reset reconciler and the admin table do.

  **Two things it deliberately does not do.**

  It is not gated on `MACHINE_OWNER_ENABLED`. The gate chooses where a verb
  runs, never whether the protocol applies: `Destroy.run/2` takes a lease with
  the gate off, inline on its caller, so with the gate off these rows exist and
  must be refused just the same.

  It says nothing about a terminal row, and callers must decide that first. A
  finalize writes `terminated` and releases the lease as two statements, so
  `terminated` with a live lease is a real, momentary state, and it means the
  machine is gone — which is a fresh machine, not a retry. Every caller here
  checks the terminal statuses before it asks.
  """
  @spec busy?(Sandbox.t() | map(), DateTime.t() | :db) :: boolean()
  def busy?(sandbox, now \\ :db), do: Lease.live?(sandbox, now)

  @doc """
  Destroy the machine behind `sandbox_id`: `Fountain.Machines.Destroy.run/2`,
  run inside the owner when `MACHINE_OWNER_ENABLED` is on and inline on the
  caller when it is off. `opts` are the protocol's, documented there.

  **This is the door, so this is where the protocol's vocabulary becomes the
  system's.** `Destroy` answers precisely — `:machine_busy`, `:superseded`,
  `{:database, sqlstate}` — and those words are for the log and for this
  module. A caller of this function gets one of the three outcomes or an atom
  the rest of Fountain already knows, because the answer travels: a terminate
  runs on a request process, and `FountainWeb.FallbackController` renders
  whatever comes out of it. A tuple has no clause there at all (a 500), and a
  retryable refusal rendered as an unmapped 422 is worse than one rendered as
  the 503 `:sandbox_unavailable` already is.

  **And `:sandbox_unavailable` is the refusal, for good** (Jake, stage 6a).
  The ADR spoke of "one retryable refusal added to every transient-error
  vocabulary at once", and 5a wrote here that stage 6 would add it. Stage 6a
  looked at what a new word would buy and decided it was nothing: a wake or an
  attach that meets a machine mid-operation means exactly what a refused
  destroy means — come back shortly — and `:sandbox_unavailable` is already
  503 with a `Retry-After`, `NotReadyError` in all four SDKs, and snoozed by
  the launch queue and the schedule runner. A second word would have to be
  taught to five clients (#2304, written and closed unmerged) to say the same
  thing. What stage 6a did add is the vocabulary sites this one was still
  missing: `SandboxQueue.@transient_errors` and, through it,
  `TeamScheduleRun`'s snooze guard, plus `Team.Schedules.describe_error/1`.
  See `refusal/2`.

  Unlike `who_is_here/1` there is no falling back to a direct read when the
  owner cannot be reached. That verb only looked; this one writes, and a write
  that was refused a place to run has to say so rather than find another one.
  """
  @spec destroy(String.t(), keyword()) ::
          {:ok, Destroy.outcome()}
          | {:error,
             :sandbox_unavailable
             | :not_found
             | :provider_transaction_open
             | :provider_unconfirmed
             | :not_fenced}
  def destroy(sandbox_id, opts) when is_binary(sandbox_id) and is_list(opts) do
    cond do
      # Checked here, not only in the protocol. `Destroy.run/2`'s own guard is
      # process-local, so with the gate on it runs in the owner — which is
      # never inside this caller's transaction — and cannot fire. Worse than
      # useless there: the owner's `Lease.claim` would block on the
      # per-sandbox advisory lock this open transaction holds, while the
      # caller blocks in `GenServer.call` until `@destroy_timeout`.
      Repo.in_transaction?() ->
        {:error, :provider_transaction_open}

      Machines.enabled?() ->
        sandbox_id |> destroy_in_owner(opts, 1) |> refusal(sandbox_id, :destroy)

      true ->
        sandbox_id |> Destroy.run(opts) |> refusal(sandbox_id, :destroy)
    end
  end

  @doc """
  Park the machine behind `sandbox_id`: `Fountain.Machines.Park.run/2`, run
  inside the owner when `MACHINE_OWNER_ENABLED` is on and inline on the caller
  when it is off. `opts` are the protocol's, documented there.

  The door for the second verb, on the same terms as `destroy/2` above: the
  protocol answers precisely and this translates. Three of its words travel,
  because each one tells its caller to do something different and
  `:sandbox_unavailable` would tell it to do nothing:

    * `:cannot_park` — this provider has no `:suspend`, so an idle machine on
      it keeps billing. Both callers destroy instead (ADR 0017's degradation,
      which used to be decided by `Lifecycle.idle_action/1` at each site and is
      now decided once, under the lease).
    * `:suspend_failed` — the provider was asked and would not. Same
      degradation, same reason: a park call that fails leaves the machine
      billing.
    * `:machine_occupied` — somebody is on the machine. Neither caller
      degrades: a machine in use is not reclaimed at all, which is what
      `Lifecycle.busy_elsewhere?/2` has always done at the server and what the
      reaper's liveness scan has always done in the sweep.
    * `:fenced` — a reset or a teardown has been asked for, so this machine is
      going away and there is nothing to park. Both callers stop bothering with
      it rather than retrying: the fence's own owner finishes the job, and
      `SandboxReaper.sweep_fenced_teardowns/0` is the backstop if it dies.
    * `:not_expired` — the verdict the caller brought has gone stale and the
      machine is no longer past a bound. Only a caller that supplies a
      `:verdict` can receive it, and the one that does counts it apart from a
      refusal: a sweep that was wrong and was told so is constraint 1 working,
      not a machine it failed to reclaim.

  Everything else is a refusal to act on right now — contention for the lease,
  a fence, a verdict gone stale, a database fault — and reads as
  `:sandbox_unavailable`. `:superseded` is `{:ok, :already_parked}`: another
  owner holds the machine and is the one that says what happened to it, and
  from here it is parked or parking.
  """
  @spec park(String.t(), keyword()) ::
          {:ok, Park.outcome()}
          | {:error,
             :sandbox_unavailable
             | :not_found
             | :provider_transaction_open
             | :cannot_park
             | :suspend_failed
             | :machine_occupied
             | :fenced
             | :not_expired}
  def park(sandbox_id, opts) when is_binary(sandbox_id) and is_list(opts) do
    cond do
      # As in `destroy/2`: the protocol's own guard is process-local and cannot
      # fire in the owner, and an open transaction here would have the owner's
      # `Lease.claim` block on the advisory lock this caller holds.
      Repo.in_transaction?() ->
        {:error, :provider_transaction_open}

      Machines.enabled?() ->
        sandbox_id |> park_in_owner(opts, 1) |> refusal(sandbox_id, :park)

      true ->
        sandbox_id |> Park.run(opts) |> refusal(sandbox_id, :park)
    end
  end

  @doc """
  Bring the machine behind `sandbox_id` up: `Fountain.Machines.Resume.run/2`,
  run inside the owner when `MACHINE_OWNER_ENABLED` is on and inline on the
  caller when it is off. `opts` are the protocol's, documented there.

  The door for the third verb, on the same terms as `destroy/2` and `park/2`:
  the protocol answers precisely and this translates. **This one lets the most
  words through**, and each is a different thing for the waking caller to do:

    * `:sandbox_reset_pending` — a reset or a teardown has been asked for, so
      there is nothing to wake. **Translated here**, from the protocol's
      `:fenced`, and it is the one refusal of the three verbs that had to be:
      `Park`'s `:fenced` is read by a conversation server and a sweep, which
      handle it and never put it on the wire, while this one travels all the way
      out of a prompt. Unmapped it rendered as `422 {"error": "fenced"}` through
      `FallbackController`'s terminal safety net, and a schedule's `last_error`
      read `:fenced` verbatim (round 1, surfaces review). `:sandbox_reset_pending`
      is what `main` answers for the fence it did check — 409, "Fountain
      completes it, and sending it again answers sandbox_reset_pending" — and it
      is right for both fences, because a teardown escalation writes
      `reset_requested_at` too (stage 5c).
    * `:provisioning` — the machine is still being built. `main`'s word,
      unchanged, and the caller waits for the registry rather than the machine
      (#800).
    * `:sandbox_resume_failed` — the provider was asked and would not. `main`'s
      word, and the protocol's `:resume_failed` is translated to it here so the
      surfaces that already know it do not have to learn a second.
    * the admission's own refusals — `{:sandbox_quota_exceeded, _}`,
      `:fleet_full`, `:insufficient_credits` — which are the tenant's cap, the
      fleet ceiling and the credit gate, exactly as
      `Quotas.with_sandbox_reservation/3` has always answered them on this path.
      They are 429, 503 and 402, and flattening any of them to
      `:sandbox_unavailable` would tell somebody out of credit to retry.

  Everything else is a refusal to act on right now — contention for the lease, a
  database fault, an unreachable owner — and reads as `:sandbox_unavailable`.
  `:superseded` is `{:ok, :already_up}`: another owner holds the machine and is
  the one that says what happened to it, and from here it is up or coming up.

  **A resume is not attempted at all on a machine that does not need one.** A
  `ready` row is `{:ok, :already_up}` and a terminal one `{:ok, :already_terminal}`,
  both without a provider call, so a caller may ask unconditionally — which is
  what makes this `ensure_up` rather than `resume`.
  """
  @spec ensure_up(String.t(), keyword()) ::
          {:ok, Resume.outcome()}
          | {:error,
             :sandbox_unavailable
             | :not_found
             | :provider_transaction_open
             | :sandbox_reset_pending
             | :provisioning
             | :sandbox_resume_failed
             | :fleet_full
             | :insufficient_credits
             | {:sandbox_quota_exceeded, map()}}
  def ensure_up(sandbox_id, opts) when is_binary(sandbox_id) and is_list(opts) do
    cond do
      # As in `destroy/2` and `park/2`: the protocol's own guard is
      # process-local and cannot fire in the owner, and an open transaction here
      # would have the owner's `Lease.claim` block on the advisory lock this
      # caller holds while the caller blocks in `GenServer.call`.
      Repo.in_transaction?() ->
        {:error, :provider_transaction_open}

      Machines.enabled?() ->
        sandbox_id |> resume_in_owner(opts, 1) |> refusal(sandbox_id, :ensure_up)

      true ->
        sandbox_id |> Resume.run(opts) |> refusal(sandbox_id, :ensure_up)
    end
  end

  @doc """
  Build the machine behind `sandbox_id`, running `fun` as the pipeline:
  `Fountain.Machines.Provision.run/3`, inline on the caller whichever way the
  gate is set (see the moduledoc). `opts` are the protocol's, documented there.

  The door for the fourth protocol, and the one whose caller is not a request
  but a `ConversationServer` deciding whether it has a machine to work on. So
  the translation is narrower than `ensure_up/2`'s: almost every word travels,
  because each tells the server something different to do, and the two that do
  not are the two that mean *somebody else has this row*:

    * `:machine_busy` and `:superseded` become `{:ok, :claimed_elsewhere}`.
      Another server holds the machine — a Horde duplicate, or a successor that
      took over an abandoned attempt — and the honest instruction to this one is
      to stop without touching anything. It is the same answer `main` reached by
      a different route: `claim_sandbox/2` answered `:retired` and the server
      stopped `:normal`.
    * `:fenced` becomes `:sandbox_reset_pending`, the word the server's own
      arms already match on and the one `update_sandbox/2` rolled back with when
      a reset fence landed mid-provision.

  Everything else — `:configuration_changed`, the pipeline's own reason, a
  `{:database, sqlstate}` — reaches the caller as itself, because the server
  decides on it: whether to fail the conversation, and what to publish on the
  `provision` stage.
  """
  @spec provision(String.t(), Provision.pipeline(), keyword()) ::
          {:ok, :provisioned, term()}
          | {:ok, :already_terminal | :claimed_elsewhere}
          | {:ok, :already_terminal | :claimed_elsewhere, term()}
          | {:error, term()}
          | {:error, term(), term()}
  def provision(sandbox_id, fun, opts)
      when is_binary(sandbox_id) and is_function(fun, 2) and is_list(opts) do
    if Repo.in_transaction?() do
      {:error, :provider_transaction_open}
    else
      sandbox_id |> Provision.run(fun, opts) |> provision_refusal(sandbox_id)
    end
  end

  @doc """
  Confirm the machine behind `sandbox_id` is still this server's to attach to:
  `Fountain.Machines.Provision.confirm_up/2`. Inline, as `provision/3`.

  The reattach arm's half of the same door. `{:ok, :confirmed}` is a live row
  this server may attach to; `{:ok, :already_terminal}` and
  `{:error, :sandbox_reset_pending}` are the two ways retirement won while the
  provider was answering, which are exactly the two answers `main`'s
  `claim_sandbox/2` gave here. `{:ok, :claimed_elsewhere}` is the duplicate
  server again.
  """
  @spec confirm_up(String.t(), keyword()) ::
          {:ok, :confirmed | :already_terminal | :claimed_elsewhere} | {:error, term()}
  def confirm_up(sandbox_id, opts \\ []) when is_binary(sandbox_id) and is_list(opts) do
    if Repo.in_transaction?() do
      {:error, :provider_transaction_open}
    else
      sandbox_id |> Provision.confirm_up(opts) |> provision_refusal(sandbox_id)
    end
  end

  @doc """
  Retire the machine behind `sandbox_id`, whose provisioning is not going to
  happen: `Fountain.Machines.Provision.fail/2`. Inline, as `provision/3`.

  For the callers that have to fail a row they never brought under a lease — the
  server's two pre-flight failures, a start that would not start, and the
  provisioning watchdog at its deadline. `{:ok, :not_provisioning}` and
  `{:ok, :already_terminal}` both mean there was nothing to retire, which is not
  an error at any of them.

  **The watchdog's caller should read the answer rather than assume it** (#394):
  the row has to be terminal before a stuck server is killed, and a refusal here
  means it is not. A refusal is not a place to stop, either —
  `Conversations.ProvisionWatchdog` retries it and then falls back to stopping
  the server anyway, because the pass that would otherwise collect the row
  (`SandboxReaper.release_stuck_sandboxes/0`) skips rows whose server is alive,
  which is every row this refusal can be about.
  """
  @spec fail_provision(String.t(), keyword()) ::
          {:ok, :failed | :already_terminal | :not_provisioning | :claimed_elsewhere}
          | {:error, term()}
  def fail_provision(sandbox_id, opts) when is_binary(sandbox_id) and is_list(opts) do
    if Repo.in_transaction?() do
      {:error, :provider_transaction_open}
    else
      sandbox_id |> Provision.fail(opts) |> provision_refusal(sandbox_id)
    end
  end

  @doc """
  Admit a turn on the machine behind `sandbox_id`:
  `Fountain.Machines.Admission.run/3`, run inside the owner when
  `MACHINE_OWNER_ENABLED` is on and inline on the caller when it is off.
  `attrs` is the turn row; `opts` are the protocol's, documented there.

  The door for the fifth protocol, and the one whose vocabulary is almost
  entirely the caller's already. The locked insert answers in the words
  `TurnMachine.open_turn/5` and `Connection.open_autonomous_turn/5` have
  matched on since long before ADR 0058 — `:sandbox_at_capacity`,
  `:configuration_changed`, `:execution_fenced`, `:not_running`,
  `:sandbox_unavailable`, the saved-allowance and inference-source refusals,
  a changeset — and every one of them travels as itself, because each tells the
  server something different to publish. Two words are the protocol's and are
  translated here: `:machine_busy` (a live lease on the machine, already waited
  out for `Admission.busy_wait_ms/0`) and an unreachable owner both become
  `:sandbox_unavailable`, the 503 with a `Retry-After` that means "come back
  shortly" everywhere else in this module.

  Like `destroy/2` and unlike `who_is_here/1`, there is no falling back to an
  inline run when the owner cannot be reached: this verb writes, and a write
  refused a place to run says so.
  """
  @spec admit_turn(String.t(), map(), keyword()) ::
          {:ok, Turn.t()} | {:error, :sandbox_unavailable | :provider_transaction_open | term()}
  def admit_turn(sandbox_id, attrs, opts \\ [])
      when is_binary(sandbox_id) and is_map(attrs) and is_list(opts) do
    cond do
      # As in `destroy/2`: the protocol's own guard is process-local and cannot
      # fire in the owner, and an open transaction here would have the owner's
      # locked insert block on the advisory lock this caller holds while the
      # caller blocks in `GenServer.call`.
      Repo.in_transaction?() ->
        {:error, :provider_transaction_open}

      Machines.enabled?() ->
        # `:admit_timeout_ms` is a test seam for the deadline below; no call
        # site in `lib/` passes it (`machine_bounds_test.exs` scans for it).
        timeout = Keyword.get(opts, :admit_timeout_ms, @admit_timeout)
        sandbox_id |> admit_in_owner(attrs, opts, timeout, 1) |> admission_refusal(sandbox_id)

      true ->
        sandbox_id |> Admission.run(attrs, opts) |> admission_refusal(sandbox_id)
    end
  end

  @doc """
  End a turn: `Fountain.Machines.Admission.end_turn/3`, inline whichever way
  the gate is set (see the moduledoc). `ending` and `opts` are the protocol's,
  documented there; the answer is the write's own, untranslated, because none
  of its words reaches the wire — each caller logs or publishes on it itself.
  """
  @spec end_turn(Turn.t(), Admission.ending(), keyword()) ::
          {:ok, Turn.t()} | {:ok, Turn.t(), term()} | :noop | {:error, term()}
  def end_turn(%Turn{} = turn, ending, opts) when is_list(opts) do
    Admission.end_turn(turn, ending, opts)
  end

  @doc """
  Whether the machine behind `sandbox_id` is at its capacity for `runtime`,
  counting the running turns of conversations other than `conv_id` on that
  runtime: `Fountain.Machines.Admission.at_capacity?/3`.

  A read, so it is not gated — the same rule as `busy?/2`. The two doors that
  ask want a refusal to render before anything is written; the locked check
  inside `admit_turn/3` is the one that decides.
  """
  @spec at_capacity?(String.t(), String.t() | nil, String.t()) :: boolean()
  def at_capacity?(sandbox_id, conv_id, runtime),
    do: Admission.at_capacity?(sandbox_id, conv_id, runtime)

  # The admission's translation. The write's vocabulary is the caller's, so
  # almost everything travels; see `admit_turn/3`.
  defp admission_refusal({:ok, _turn} = ok, _sandbox_id), do: ok

  defp admission_refusal({:error, :machine_busy}, sandbox_id) do
    Logger.warning(
      "machine #{sandbox_id}: turn admission unavailable (an owner holds the lease); " <>
        "answering :sandbox_unavailable"
    )

    {:error, :sandbox_unavailable}
  end

  defp admission_refusal({:error, {:machine_unreachable, reason}}, sandbox_id) do
    Logger.warning(
      "machine #{sandbox_id}: turn admission unavailable (#{inspect(reason)}); " <>
        "answering :sandbox_unavailable"
    )

    {:error, :sandbox_unavailable}
  end

  # The owner found the caller's deadline passed before it could run the
  # admission. The caller was already answered `:sandbox_unavailable` by the
  # timeout; this answer reaches nobody, and is the same word for the log.
  defp admission_refusal({:error, :admission_expired}, _sandbox_id),
    do: {:error, :sandbox_unavailable}

  defp admission_refusal({:error, :transaction_open}, _sandbox_id),
    do: {:error, :provider_transaction_open}

  defp admission_refusal(other, _sandbox_id), do: other

  # The provision family's translation. Narrower than `refusal/3` because its
  # caller is a server rather than a request, and the reason usually decides
  # what that server does next. See `provision/3`.
  defp provision_refusal({:ok, _outcome} = ok, _sandbox_id), do: ok
  defp provision_refusal({:ok, _outcome, _result} = ok, _sandbox_id), do: ok

  defp provision_refusal({:error, reason}, sandbox_id)
       when reason in [:machine_busy, :superseded] do
    Logger.info(
      "machine #{sandbox_id}: provisioning is another owner's (#{inspect(reason)}); standing down"
    )

    {:ok, :claimed_elsewhere}
  end

  # The result travels with it: the pipeline reached a state its caller has to
  # unwind — a broker session, a rotated callback key — whether or not the row
  # ended up being this attempt's to write.
  defp provision_refusal({:error, reason, result}, sandbox_id)
       when reason in [:machine_busy, :superseded] do
    {:ok, outcome} = provision_refusal({:error, reason}, sandbox_id)
    {:ok, outcome, result}
  end

  defp provision_refusal({:error, :fenced}, _sandbox_id), do: {:error, :sandbox_reset_pending}

  defp provision_refusal({:error, :fenced, result}, _sandbox_id),
    do: {:error, :sandbox_reset_pending, result}

  defp provision_refusal({:error, :transaction_open}, _sandbox_id),
    do: {:error, :provider_transaction_open}

  defp provision_refusal(other, _sandbox_id), do: other

  # The protocols' answers, in the words the rest of the system uses.
  #
  # `:superseded` is not a failure to report: another owner took the machine
  # over and is the one that says what happened to it. From here the machine is
  # stopping or stopped for a destroy, parked or parking for a park — and each
  # is the same thing a caller is told when somebody else got there first,
  # because it is the same event.
  #
  # Everything not named in the verb's own list is "this machine could not be
  # reached right now", which is what `:sandbox_unavailable` already means
  # (503, `retry-after: 30`, retryable in all four SDKs). Contention, a
  # database fault out of `Lease` and an unreachable owner are all that shape.
  # The precise reason goes to the log, where an operator can find it; it does
  # not go on the wire.
  defp refusal({:ok, _outcome} = ok, _sandbox_id, _verb), do: ok

  defp refusal({:error, :superseded}, sandbox_id, verb) do
    Logger.info("machine #{sandbox_id}: #{verb} superseded; another owner finished it")
    superseded(verb)
  end

  # A caller bug, and every sibling verb's word for it.
  defp refusal({:error, :transaction_open}, _sandbox_id, _verb),
    do: {:error, :provider_transaction_open}

  # `main`'s word at every surface a wake reaches, and the two translations this
  # module does that are not flattenings.
  #
  # The protocol says `:resume_failed`, to sit beside `Park`'s `:suspend_failed`,
  # and the rest of Fountain has said `:sandbox_resume_failed` since #799.
  defp refusal({:error, :resume_failed}, _sandbox_id, :ensure_up),
    do: {:error, :sandbox_resume_failed}

  # And `:fenced`, which is a *protocol* word with no meaning outside this
  # namespace. `Park`'s may travel because both its callers handle it themselves;
  # a wake's caller is a prompt, and the answer goes on the wire. See
  # `ensure_up/2`.
  defp refusal({:error, :fenced}, _sandbox_id, :ensure_up),
    do: {:error, :sandbox_reset_pending}

  defp refusal({:error, reason}, sandbox_id, verb) do
    if travels?(verb, reason) do
      {:error, reason}
    else
      Logger.warning(
        "machine #{sandbox_id}: #{verb} unavailable (#{inspect(reason)}); " <>
          "answering :sandbox_unavailable"
      )

      {:error, :sandbox_unavailable}
    end
  end

  defp superseded(:destroy), do: {:ok, :already_terminal}
  defp superseded(:park), do: {:ok, :already_parked}
  defp superseded(:ensure_up), do: {:ok, :already_up}

  # `travelling/1` is a list of atoms, and one refusal that has to travel is not
  # one: `{:sandbox_quota_exceeded, %{count: n, limit: n}}` carries the numbers
  # the 429 body and the schedule's error string are both built from, so it
  # cannot be flattened to an atom on the way out.
  defp travels?(:ensure_up, {:sandbox_quota_exceeded, _}), do: true
  defp travels?(verb, reason), do: reason in travelling(verb)

  # The words each verb lets through, and nothing else.
  #
  # For a destroy: the fence's own refusals, which every caller of that path
  # already handled before ADR 0058 and which `FallbackController` maps.
  # `:provider_unconfirmed` and `:not_fenced` travel too, and only a caller
  # that opted into them can receive one: both answer a question the generic
  # `:sandbox_unavailable` cannot. The reset family asked for its fence to
  # survive an unconfirmed delete and has its own word for that state
  # (`:sandbox_reset_pending`, 409 at the API, "capacity remains reserved" in
  # the admin panel); flattening them here would tell an operator to retry a
  # machine and tell the reconciler its job had failed transiently, when what
  # happened is that the provider never confirmed. They are translated by the
  # reset caller, one function away, and never reach the wire.
  #
  # For a park: the three that decide what the caller does next. See `park/2`.
  defp travelling(:destroy) do
    [
      :not_found,
      :sandbox_unavailable,
      :provider_transaction_open,
      :provider_unconfirmed,
      :not_fenced
    ]
  end

  # For `ensure_up`: the fence, the two states there is nothing to resume from,
  # the provider's refusal, and the admission's three. See `ensure_up/2`.
  defp travelling(:ensure_up) do
    [
      :not_found,
      :sandbox_unavailable,
      :provider_transaction_open,
      :sandbox_reset_pending,
      :provisioning,
      :sandbox_resume_failed,
      :fleet_full,
      :insufficient_credits
    ]
  end

  defp travelling(:park) do
    [
      :not_found,
      :sandbox_unavailable,
      :provider_transaction_open,
      :cannot_park,
      :suspend_failed,
      :machine_occupied,
      :fenced,
      :not_expired
    ]
  end

  # The same gone-owner retry as `ask_owner/2`, and the same reason: the idle
  # timer fires on its own schedule and a Horde registry entry can name a
  # process that has already exited. One retry with a freshly started owner,
  # then a refusal. A `:timeout` is not retried — the owner is alive and busy,
  # and asking it twice only doubles the wait.
  defp destroy_in_owner(sandbox_id, opts, retries_left) do
    in_owner(sandbox_id, {:destroy, opts}, @destroy_timeout, :destroy, retries_left)
  end

  defp park_in_owner(sandbox_id, opts, retries_left) do
    in_owner(sandbox_id, {:park, opts}, @park_timeout, :park, retries_left)
  end

  defp resume_in_owner(sandbox_id, opts, retries_left) do
    in_owner(sandbox_id, {:ensure_up, opts}, @resume_timeout, :ensure_up, retries_left)
  end

  # The deadline is dated on the database's clock, `timeout` from now: the one
  # clock every node shares (stage 7a's reason for the lease), and the one the
  # locked insert reads in the same statement as the machine's row. One trivial
  # query per prompt with the gate on; none with it off.
  defp admit_in_owner(sandbox_id, attrs, opts, timeout, retries_left) do
    deadline = DateTime.add(Lease.now(), timeout, :millisecond)

    in_owner(
      sandbox_id,
      {:admit_turn, attrs, opts, deadline},
      timeout,
      :admit_turn,
      retries_left
    )
  end

  defp in_owner(sandbox_id, message, timeout, verb, retries_left) do
    case ensure_started(sandbox_id) do
      {:ok, pid} ->
        try do
          GenServer.call(pid, message, timeout)
        catch
          :exit, reason
          when retries_left > 0 and elem(reason, 0) in [:noproc, :normal, :shutdown] ->
            Logger.debug("machine #{sandbox_id}: owner went away before #{verb}; retrying")
            in_owner(sandbox_id, message, timeout, verb, retries_left - 1)

          :exit, reason ->
            Logger.warning("machine #{sandbox_id}: #{verb} unreachable (#{inspect(reason)})")
            {:error, {:machine_unreachable, reason}}
        end

      {:error, reason} ->
        Logger.warning("machine #{sandbox_id}: no owner to #{verb} through (#{inspect(reason)})")

        {:error, {:machine_unreachable, reason}}
    end
  end

  # The pid can be gone between the lookup and the call — the idle timer fires
  # on its own schedule, and a Horde registry entry can outlive the process it
  # names while the CRDT catches up. `GenServer.call` *exits* on that, which
  # would make a read-only verb crash its caller. So: one retry with a freshly
  # started owner, then the direct read. Whatever happens, the caller gets a
  # struct, which is what the @spec promises.
  #
  # Only a *gone* owner is retried. A `:timeout` means the owner is alive and
  # slow — almost certainly a repo that is already in trouble — and retrying
  # that would make one caller wait two `@call_timeout`s before it gave up, so
  # it falls straight through to the direct read.
  defp ask_owner(sandbox_id, retries_left) do
    case ensure_started(sandbox_id) do
      {:ok, pid} ->
        try do
          GenServer.call(pid, :who_is_here, @call_timeout)
        catch
          :exit, reason
          when retries_left > 0 and elem(reason, 0) in [:noproc, :normal, :shutdown] ->
            Logger.debug("machine #{sandbox_id}: owner went away (#{inspect(reason)}); retrying")
            ask_owner(sandbox_id, retries_left - 1)

          :exit, reason ->
            Logger.warning(
              "machine #{sandbox_id}: owner unreachable (#{inspect(reason)}); " <>
                "reading occupancy directly"
            )

            Occupancy.load(sandbox_id)
        end

      {:error, reason} ->
        Logger.warning(
          "machine #{sandbox_id}: no owner (#{inspect(reason)}); reading occupancy directly"
        )

        Occupancy.load(sandbox_id)
    end
  end

  # ── server ────────────────────────────────────────────────────────────────

  @impl true
  def init(args) do
    state = %{
      sandbox_id: Keyword.fetch!(args, :sandbox_id),
      idle_ms: Keyword.get(args, :idle_ms, @idle_ms),
      idle_token: nil
    }

    {:ok, arm_idle(state)}
  end

  @impl true
  def handle_call(:who_is_here, _from, state) do
    {:reply, Occupancy.load(state.sandbox_id), arm_idle(state)}
  end

  # Serialization, not safety: `Destroy.run/2`'s lease is what makes two
  # destroys of one machine correct, and running them one at a time here is
  # what keeps the second one from waiting out the first one's lease to find
  # out. It runs in the owner rather than in a task so the mailbox is the
  # queue; `@destroy_timeout` on the client side is the ceiling on the
  # caller's *wait* for it — a message whose caller has given up still runs
  # when the owner reaches it, and for this verb that late run is idempotent
  # (a destroy of a destroyed machine is `{:ok, :already_terminal}` to nobody).
  def handle_call({:destroy, opts}, _from, state) do
    {:reply, Destroy.run(state.sandbox_id, opts), arm_idle(state)}
  end

  # Same shape, same reason. A park occupies the owner for a checkpoint and a
  # suspend, which is longer than a destroy takes — `@park_timeout` on the
  # client side is the ceiling on the caller's wait, and a late park is a park
  # of a machine the recheck under the lease still has to find idle.
  def handle_call({:park, opts}, _from, state) do
    {:reply, Park.run(state.sandbox_id, opts), arm_idle(state)}
  end

  # Same shape, same reason, and here the serialization is the *feature* rather
  # than an optimization of it: two prompts waking one parked home arrive
  # milliseconds apart, and queueing the second behind the first is what makes
  # it find a machine that is already up instead of waiting out a lease to be
  # told so (ADR 0023 step 4).
  #
  # `@resume_timeout` bounds the caller's wait, not this queue, and a late
  # resume is **not** idempotent the way a late destroy or park is (round 2,
  # protocol review, driven): the caller was told `sandbox_unavailable` and
  # moved on, the queued resume then runs at the provider, and the machine
  # comes up `ready` for nobody — billed until `Machines.Policy`'s idle
  # verdict parks it again at the idle bound, with the clock restarted from
  # the late `last_resumed_at`. The next wake finds it up. Collected, not
  # leaked for good; but a cost, and named here rather than lent the
  # destroy's word. A deadline on this message is stage 8b's call, beside the
  # binding verbs that create state the same way.
  def handle_call({:ensure_up, opts}, _from, state) do
    {:reply, Resume.run(state.sandbox_id, opts), arm_idle(state)}
  end

  # Same shape again, and the serialization is the feature here as it is for a
  # resume: a prompt that arrives while this machine is being resumed for a
  # cotenant waits in the mailbox and then finds it up, where inline it would
  # wait out `Admission.busy_wait_ms/0` against the lease and be told
  # `sandbox_unavailable`.
  #
  # **The timeout bounds the caller's wait, not this queue**, and unlike a
  # destroy or a park a late admission is not idempotent: it is a turn row
  # for a prompt that was already told 503 (round 1). So the message carries
  # the caller's deadline on the database clock, and an admission that reaches
  # the front of the mailbox after it is refused without running — here, from
  # one read of the clock, and again inside the locked insert, which judges
  # the same deadline against the `statement_timestamp()` it read the
  # machine's row with.
  #
  # What the two checks bound, exactly (round 2, protocol review, driven): the
  # write's check refuses a *row read* past the deadline, and the commit can
  # still land up to one transaction tail after it — the parent check, the
  # allowance, the count, the insert and the parent update, with no lock wait
  # among them; milliseconds in practice. That tail is the price of the check
  # and the insert being two statements. This pre-check is not the smaller
  # half: the write's check sits after the machine's own verdicts, so an
  # expired message that finds a cotenant's lease live would answer
  # `:machine_busy` and poll the locked insert for the whole
  # `Admission.busy_wait_ms/0` on a caller that left; this one refuses it from
  # one clock read, and `admission_test.exs` pins that difference.
  #
  # The three-tuple below is the message a caller on the round-1 head sends —
  # no deadline, because it had none. An owner that crashed on it would cost a
  # cotenant's queued park (the mixed-version note in the PR); refusing is the
  # safe side, in the one word every version of the door translates.
  def handle_call({:admit_turn, _attrs, _opts}, _from, state) do
    Logger.warning(
      "machine #{state.sandbox_id}: an admission arrived without a deadline (a caller on " <>
        "the previous release); refusing without running it"
    )

    {:reply, {:error, :machine_busy}, arm_idle(state)}
  end

  def handle_call({:admit_turn, attrs, opts, %DateTime{} = deadline}, _from, state) do
    reply =
      if DateTime.compare(Lease.now(), deadline) == :gt do
        Logger.warning(
          "machine #{state.sandbox_id}: an admission reached the owner after its caller's " <>
            "deadline; refusing without running it"
        )

        {:error, :admission_expired}
      else
        Admission.run(state.sandbox_id, attrs, Keyword.put(opts, :deadline, deadline))
      end

    {:reply, reply, arm_idle(state)}
  end

  @impl true
  def handle_info({:idle, token}, %{idle_token: token} = state) do
    # Nothing durable to release. A destroy's or a park's lease is claimed and
    # released inside its own `handle_call`, and a GenServer handles one
    # message at a time, so this message is only ever reached between
    # operations — never with one in flight. `ensure_started/1` starts a replacement on the next
    # question. The standing lease of stages 6 and 7 changes that, and will
    # have to be given up here.
    {:stop, :normal, state}
  end

  # A timer this process already re-armed past. Cancelling leaves the message
  # in the mailbox when it was already sent, so the token, not the cancel, is
  # what decides.
  def handle_info({:idle, _stale}, state), do: {:noreply, state}

  defp arm_idle(state) do
    token = make_ref()
    Process.send_after(self(), {:idle, token}, state.idle_ms)
    %{state | idle_token: token}
  end

  # ── starting ──────────────────────────────────────────────────────────────

  defp start_child(sandbox_id, opts) do
    child = {__MODULE__, Keyword.put(opts, :sandbox_id, sandbox_id)}

    case Horde.DynamicSupervisor.start_child(Fountain.MachineSupervisor, child) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} when is_pid(pid) -> {:ok, pid}
      {:error, {:already_started, _}} -> await_registered(sandbox_id)
      :ignore -> await_registered(sandbox_id)
      {:error, _reason} = error -> error
    end
  end

  defp await_registered(sandbox_id) do
    deadline = System.monotonic_time(:millisecond) + @settle_ms
    do_await_registered(sandbox_id, deadline)
  end

  defp do_await_registered(sandbox_id, deadline) do
    case whereis(sandbox_id) do
      pid when is_pid(pid) ->
        {:ok, pid}

      nil ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, :registry_timeout}
        else
          Process.sleep(@poll_ms)
          do_await_registered(sandbox_id, deadline)
        end
    end
  end
end
