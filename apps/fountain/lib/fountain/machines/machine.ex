defmodule Fountain.Machines.Machine do
  @moduledoc """
  The owner of one machine (ADR 0058).

  One process per *active* sandbox, registered in `Fountain.MachineRegistry`
  under the sandbox id and supervised by `Fountain.MachineSupervisor`, both
  Horde members so the owner is addressable from any node. It idle-stops after
  a minute with nothing asked of it, and `ensure_started/1` brings it back:
  there is a process per active machine, not one per row.

  Three verbs so far. `who_is_here/1` returns the
  `Fountain.Machines.Occupancy` struct and reads nothing else. `destroy/2` and
  `park/2` run `Fountain.Machines.Destroy.run/2` and
  `Fountain.Machines.Park.run/2` — the two protocols, lease and all — and are
  the only things here that write: the row through
  `Fountain.Machines.Lease`, the provider through `Managoat.Sandbox.destroy/1`
  and `suspend/1`, and one `sandbox.destroyed` or `sandbox.suspended` audit
  event. `ensure_up`, `attach` and `admit_turn` arrive in stages 7 and 8.

  Beside them is one pure predicate, `busy?/2` (stage 6a): whether an owner
  holds a live lease on a machine, from the row the caller already holds. It is
  the question every reader that was about to start work on a machine now asks
  first, and the answer it turns into is `:sandbox_unavailable`.

  ## What the gate chooses

  With `MACHINE_OWNER_ENABLED` on, `destroy/2` and `park/2` are calls into this
  process, so two operations on one machine queue behind one another in its
  mailbox. With it off, the protocols run inline on the caller. **Same protocol
  either way**
  — the same fence, the same lease, the same compare-and-set, the same event —
  because the thing that makes a destroy safe against a concurrent destroy is
  the lease on the row, not the mailbox in front of it. The process is an
  optimization of the contention, not the correctness. That is also why there
  is no second, older destroy path left behind the gate: there is one, and the
  flag picks where it runs.

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
  correct today, because the verb is read-only and a slightly late reading of
  who is on a machine harms nobody. It stops being correct at stage 8, when
  `attach`, `detach` and `admit_turn` come through this same door and the
  answer is what a durable decision is made on: a writer that walks past the
  owner is two owners again. The fallback has to go before those land.
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
  alias Fountain.Machines
  alias Fountain.Machines.Destroy
  alias Fountain.Machines.Lease
  alias Fountain.Machines.Occupancy
  alias Fountain.Machines.Park
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

  Takes a `Sandbox` the caller has already read, so the check costs no query,
  and the clock, so a sweep can judge a page of rows against one instant.

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
  @spec busy?(Sandbox.t() | map(), DateTime.t()) :: boolean()
  def busy?(sandbox, now \\ DateTime.utc_now()), do: Lease.live?(sandbox, now)

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

  defp refusal({:error, reason}, sandbox_id, verb) do
    if reason in travelling(verb) do
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
  # queue; `@destroy_timeout` on the client side is the ceiling on that queue.
  def handle_call({:destroy, opts}, _from, state) do
    {:reply, Destroy.run(state.sandbox_id, opts), arm_idle(state)}
  end

  # Same shape, same reason. A park occupies the owner for a checkpoint and a
  # suspend, which is longer than a destroy takes — `@park_timeout` on the
  # client side is the ceiling on that queue.
  def handle_call({:park, opts}, _from, state) do
    {:reply, Park.run(state.sandbox_id, opts), arm_idle(state)}
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
