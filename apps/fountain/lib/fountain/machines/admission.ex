defmodule Fountain.Machines.Admission do
  @moduledoc """
  One turn-admission protocol for one machine (ADR 0058, stage 8a).

  A turn is the unit of work a machine does for a conversation, and admitting
  one is the owner's decision: ADR 0058's verb table gives `admit_turn` and
  `end_turn` to the owner as the replacement for the locked turn insert, the
  capacity check, and the "is anyone mid-turn" question every reclaim asks.
  This module is that protocol. `Fountain.Machines.Machine.admit_turn/3` and
  `Fountain.Machines.Machine.end_turn/3` are its doors, and — as the lexical pin
  in `direct_writes_test.exs` asserts, beside the row-write ratchet it is the
  turn-row half of — nothing outside `lib/fountain/machines/` calls the
  context's turn-admitting or turn-ending writes any more.

  ## Admission

  The locked insert `Fountain.Conversations._unsafe_create_turn_on_sandbox/3`
  is still the write, and it is still one transaction under the per-sandbox
  advisory lock (4316): the inference-source lock, the parent `FOR UPDATE`,
  the revision, the saved allowance, the capacity count, the turn row and the
  parent's `running` status all commit together, as they did on `main`. What
  stage 8a adds is decided **under that lock**, from the machine's row read in
  the same transaction, because a verdict taken before the lock is stale by
  construction (#2307 constraint 1):

    * **A live lease refuses the turn.** An owner mid-operation on this machine
      — a park at the provider, a resume, a destroy, a provision — holds a
      lease (`Fountain.Machines.Lease.live?/2`), and a turn admitted underneath
      it would run against a machine that is being suspended or rebuilt. That
      is stage 6a's rule ("busy means a live lease") applied to the one writer
      that had not been asking. A lapsed lease, and a stamped `transition`
      whose lease has lapsed, refuse nothing: that is an owner that died, and
      the row is judged by its status, exactly as every reader since 6a judges
      it. The protocol waits `busy_wait_ms/0` for a live lease to clear before
      it refuses, polling the write, because the common holder is a cotenant's
      resume that finishes in a second or two and the second prompt wants the
      machine it is bringing up, not a 503. The holder can also be a *park*
      that finishes inside the wait, and then the turn is admitted onto a
      `suspended` machine: a `suspended` row with no lease is admissible here
      exactly as it was on `main`, and it is the caller's wake — which runs
      before every prompt and resumes a parked machine through `ensure_up/2`
      — that is expected to bring it back, not this write. Refusing on status
      here would refuse the reattach path's own first turn; left as `main`
      had it, and named rather than hidden.
    * **Either fence refuses the turn.** `main` refused a reset fence; a
      teardown fence let the turn through, and the machine was destroyed
      underneath it by whatever finished the fence. Both are durable statements
      that the machine is going away, and `Resume`, `Park` and `Provision` all
      refuse on either; admission now agrees with them.
    * **Capacity is counted per runtime.** `Fountain.RuntimeDispatch.concurrency/1`
      is a property of a *runtime* — `opencode` and `gemini` take one turn at a
      time, `claude` and `codex` as many as arrive — and `main` counted every
      running turn on the machine against the asker's bound whatever runtime
      it ran on, so a `claude` turn on a shared home consumed the one `opencode`
      slot (#1089 blocker 4). The count is now over running turns of
      conversations on the **same runtime**, and the bound is read from the
      conversation row under the lock rather than passed in by the caller.

  ### Why this protocol takes no lease of its own

  `Destroy`, `Park`, `Resume` and `Provision` each claim a lease because each
  has a provider round trip between the decision and the write, and the lease
  is what makes that gap safe. An admission has no gap: it is one transaction,
  and the advisory lock inside it is already the serialisation every other
  writer of this row takes — `Lease.claim/4` takes 4316 too, so a claim and an
  admission cannot interleave, and each sees the other's committed state. What
  a lease would add is two row writes and an epoch bump on the machine per
  prompt, which is the cost regression the stage 7a review found in
  `ensure_up/2`'s first draft and removed. It would also make
  `Machine.busy?/2` answer true for the milliseconds of every prompt, so an
  attach landing in that window would be refused where `main` admitted it.
  The lease is the right tool for an operation that leaves the database; this
  one never does.

  The consequence worth stating plainly: with the gate on, an admission runs in
  the owner process and queues behind a park, a resume or a destroy of the same
  machine in its mailbox — which is the serialisation ADR 0023 step 4 asked for
  ("two prompts waking one machine resume it once; the second waits"). With the
  gate off it runs inline, and the live-lease refusal is what stands in for the
  queue. Same protocol either way; the gate picks where it runs.

  ### The two refusals are each other's symmetric case

  A live lease refuses an admission here; an admitted turn refuses a park in
  `Fountain.Machines.Park` (stage 6b, `:machine_occupied`). They are one rule
  read from its two ends, and both are needed because each covers the order the
  other cannot. A park that has claimed its lease and then reads the turns sees
  every turn admitted before its claim, because the admission held 4316 until
  its commit and the claim waited on it — so the park refuses on a turn that is
  already there. An admission that arrives *after* the claim sees the lease the
  claim wrote, under the same lock — so it refuses on an operation that has
  already started. Neither side decides on a reading taken before it held the
  lock (#2307 constraint 1), and `admission_test.exs` drives both orders on real
  connections with `pg_blocking_pids`: the #2286 race, which needed exactly this
  pair and had only half of it.

  ## `end_turn`

  Every turn-ending write an actor makes comes through `end_turn/3`: the
  completion (`Fountain.Conversations._unsafe_complete_turn/4`, which is also
  how a spawn that never started fails its turn), the two-phase interrupt's
  first half (`Fountain.Conversations.Interruption._unsafe_interrupt_turn/2`)
  and the recovery of a turn nothing is driving any more
  (`Fountain.Conversations._unsafe_orphan_turn/3`, from a server's `terminate/2`,
  the reattach path's give-up, a wake's dead-interrupt reconcile, and the
  `AutonomousTurnReaper`). The writes themselves stay in the context, where the
  locks they take are; what moves here is the door and the one predicate they
  all check, `bound?/2`.

  `end_turn/3` runs **inline whichever way the gate is set**, and that is a
  deliberate deviation from the other verbs, argued here rather than left to
  be found. A turn ending is a write to the conversation's rows, not an
  operation on the machine: it calls no provider, changes no machine state, and
  the owner's refcount of admitted turns is the rows themselves, which it reads
  under its own lease when it needs them. Routing it through the owner process
  would buy no serialisation that the row locks do not already provide, and it
  would cost something real: a turn that ends while a cotenant's park holds the
  owner for a minute would wait in its mailbox, on a server's `terminate/2` or
  its adapter-exit path, and a `GenServer.call` that times out there leaves the
  turn `running` with nothing left to end it. `Provision` set the precedent —
  "the lease is the correctness, the mailbox is the optimisation" — and here
  there is no lease to be the correctness of, only a fence.

  **And it takes no sandbox advisory lock either.** The two pull against each
  other — a write that must not queue behind a cotenant's park cannot wait on
  the lock that park's claim took — so it is worth saying what the locks the
  writes *do* take protect, and why 4316 adds nothing. `_unsafe_end_actor_turn/5`
  and `_unsafe_recover_turn/3` lock the parent `FOR UPDATE`, then the journal,
  then the turn, and every decision they make — the binding, the terminal
  status, `latest_turn?/2`, the journal's own arbitration — is read under those
  locks; a reassignment, a termination or a successor's admission landing at the
  same moment waits on the parent row and then sees, or is seen. What 4316
  would add is serialisation against the *machine's* operations, and a turn
  ending needs none: the dangerous direction for a park is a turn that
  **starts** after its occupancy read, which admission holds the lock for; a
  turn that **ends** after that read only makes the park's refusal more
  conservative than it had to be, and the next tick asks again. A turn ending
  under a destroy or a resume is the same — the row it writes is not the one
  those operations write. When the owner ends turns itself (stage 8b), that
  write will run under the owner's lease because the owner already holds it,
  not because this one needed it.

  ## The fence, and why the epoch is not it yet

  ADR 0058's stage 8 row says "the epoch is the fence" for the actor's ending
  writes. Stage 8a does not do that, and the reason belongs here because the
  next stage will meet it again.

  Every ending write an actor makes carries the sandbox its server was bound to
  at `init/1` — `state.sandbox_id`, set once and never reassigned — and the
  context compares it, under the parent's `FOR UPDATE`, to the sandbox the
  conversation is bound to **now**. `bound?/2` is that comparison. A server
  whose conversation has been rebound to a replacement machine while it was
  away therefore writes nothing (`:noop`, or `{:error, :ownership_changed}` on
  the recovery path), and a successor on the replacement is the one that ends
  the predecessor's turn. That is the #1767 fence, and it is the right
  authority: the conversation's *current binding* decides who may end its
  turns, whichever machine a given turn was admitted on.

  (For a *bounded* turn a per-turn machine record already exists and already
  refuses: `ExecutionGuard.cleanup_binding?/1` compares the journal's recorded
  sandbox to the parent's current binding, so counterexample 3's successor
  write is refused today for a turn with a `TurnExecution` row. Execution
  limits ship inert, so every production turn takes the no-journal path — the
  rule below is about that path, and the journal's is not hypothetical.)

  The machine's lease epoch cannot stand in for it, on three reachable paths:

    1. On a shared home a cotenant's resume or park moves the epoch while this
       conversation's turn is legitimately running, so the actor's own ending
       write would compare a stale epoch and be refused, and the turn stranded.
    2. The ceiling park, and a park over a running turn whose server is dead
       (stage 6b's rule), both proceed and move the epoch — and the recovery of
       that turn, from `terminate/2` or the reattach path's give-up, is exactly
       the write that then has to succeed.
    3. A turn stamped at admission with the machine it was admitted on fares no
       better: a wake that builds a fresh machine and a successor that reattaches
       on it must orphan the predecessor's turn, which was admitted elsewhere,
       and `AutonomousTurnReaper` never collects it because a server is
       registered. A turn-level record would refuse the one write that closes
       it.

  What makes the epoch usable as a fence is the owner ending the turns it
  operates over — so that a stale actor's write always finds a turn already
  ended — and stage 8b built that half as `end_turns_on/3`: a destroy ends
  every running turn bound to the machine at its finalize (the machine is
  gone, and no turn on it can continue), and a ceiling park ends the one turn
  it cuts, the requester's own. A park over a turn nothing is driving still
  leaves it alone, by stage 6b's rule — a turn parked on a person's permission
  whose server has died is theirs to answer — so the reattaching server's
  give-up on counterexample 2 is still a write that lands, and the binding is
  still the fence. `bound?/2` compares exactly what it did.

  ## Vocabulary

  `run/3` answers `{:ok, turn}` or the write's own refusal: `:sandbox_at_capacity`,
  `:configuration_changed`, `:execution_fenced`, `:not_running`,
  `:inference_source_changed`, `:sandbox_unavailable` (a terminal or fenced
  machine, or a conversation that is not bound to it), the saved-allowance and
  inference-source refusals, or an `Ecto.Changeset`. Every one of those is a
  word the callers already handled on `main`. New here are `:machine_busy` (a
  live lease, waited out) and `:transaction_open` (the caller's bug), which the
  door translates.
  """

  import Ecto.Query

  alias Fountain.Conversations
  alias Fountain.Conversations.{Conversation, Interruption, Turn}
  alias Fountain.Repo

  require Logger

  # How long a *waiter* waits for a live lease on the machine to clear before
  # the admission is refused. `Destroy`'s, `Park`'s and `Resume`'s number, and
  # here it is measured against the same thing: a person behind a prompt. The
  # common holder is a cotenant's resume, which settles in a second or two; a
  # park's checkpoint or a provision does not, and five seconds is long enough
  # to tell the two apart.
  @busy_wait_ms 5_000

  # How often the wait re-asks. Each ask is the whole locked write, so this is
  # deliberately not tighter.
  @poll_ms 250

  @endings ~w(completed failed interrupted)

  @typedoc """
  What `end_turn/3` is being asked to do. `{:finish, status, extra}` is the
  completion writer (`extra` may carry `:exit_code`); `:mark_interrupted` is
  the two-phase interrupt's first half, which leaves the parent `running` until
  the peer has stopped; `{:orphan, why}` is the recovery of a turn nothing is
  driving.
  """
  @type ending :: {:finish, String.t(), keyword()} | :mark_interrupted | {:orphan, String.t()}

  @doc """
  Admit a turn on the machine behind `sandbox_id`.

  `attrs` is the turn row to insert, as `Fountain.Conversations.Turn.changeset/2`
  takes it; it must carry `:conversation_id`. Options:

    * `:revision` — the conversation's `configuration_revision` as the caller
      read it, or nil for a caller with none; a mismatch is
      `{:error, :configuration_changed}` (#1565).
    * `:busy_wait_ms` — the bound above. Tests shorten it; no call site does.
    * `:deadline` — a `DateTime` on the database clock after which the caller
      is no longer waiting for the answer. Set by `Machine.admit_turn/3` on
      the in-owner path only; the locked insert refuses the turn
      (`{:error, :admission_expired}`) when the clock it read the machine's row
      with is past it. The bound is the row read: a commit can land one
      transaction tail after the deadline, milliseconds with no lock wait.
  """
  @spec run(Ecto.UUID.t(), map(), keyword()) :: {:ok, Turn.t()} | {:error, term()}
  def run(sandbox_id, attrs, opts \\ [])
      when is_binary(sandbox_id) and is_map(attrs) and is_list(opts) do
    if Repo.in_transaction?() do
      {:error, :transaction_open}
    else
      wait_until =
        System.monotonic_time(:millisecond) + Keyword.get(opts, :busy_wait_ms, @busy_wait_ms)

      write_opts = Keyword.take(opts, [:deadline])
      admit(sandbox_id, attrs, Keyword.get(opts, :revision), write_opts, wait_until)
    end
  end

  # The write, and the one refusal that is waited out rather than returned. A
  # live lease is an operation in flight, and the lease's own bound is what
  # says how long that can be; the wait here is the caller's, not the holder's
  # (`machine_bounds_test.exs`). Every other refusal is final for this prompt,
  # and the door logs the one that is returned — not here as well.
  defp admit(sandbox_id, attrs, revision, write_opts, wait_until) do
    case Conversations._unsafe_create_turn_on_sandbox(attrs, sandbox_id, revision, write_opts) do
      {:error, :machine_busy} ->
        if System.monotonic_time(:millisecond) + @poll_ms < wait_until do
          Process.sleep(@poll_ms)
          admit(sandbox_id, attrs, revision, write_opts, wait_until)
        else
          {:error, :machine_busy}
        end

      other ->
        other
    end
  end

  @doc """
  How long `run/3` waits for a live lease to clear before refusing.

  Public so `machine_bounds_test.exs` can pin it against the owner's call
  timeout above it.
  """
  @spec busy_wait_ms() :: pos_integer()
  def busy_wait_ms, do: @busy_wait_ms

  @doc """
  Whether the machine behind `sandbox_id` cannot take a turn from `conv_id` on
  `runtime` right now, because other conversations **on that runtime** already
  fill its capacity. Always false for a runtime with no bound.

  An unlocked read for the two doors that want a refusal to render before any
  write is attempted — the attach door, when the attach carries a prompt, and
  the prompt door — so a person gets `sandbox_at_capacity` rather than an `:ok`
  followed by a refused stage. The locked check is inside `run/3`, and the two
  ask the same question of the same rows. `nil` for `conv_id` counts every
  conversation on the machine, which is what an attach that has no conversation
  yet needs.
  """
  @spec at_capacity?(Ecto.UUID.t(), Ecto.UUID.t() | nil, String.t()) :: boolean()
  def at_capacity?(sandbox_id, conv_id, runtime)
      when is_binary(sandbox_id) and (is_binary(conv_id) or is_nil(conv_id)) and
             is_binary(runtime) do
    case Fountain.RuntimeDispatch.concurrency(runtime) do
      :unbounded ->
        false

      capacity ->
        Conversations._unsafe_running_turns_elsewhere(sandbox_id, conv_id, runtime) >= capacity
    end
  end

  @doc """
  End a turn: the door for every turn-ending write an actor makes. See the
  moduledoc for the three endings and for why this runs inline.

  `opts[:sandbox_id]` is the actor's binding — `state.sandbox_id`, or the
  sandbox a wake probed — and the context compares it to the conversation's
  current binding under the parent lock (`bound?/2`). It is **required** for
  `{:finish, _, _}` and `:mark_interrupted`: those are an actor's writes, and a
  caller that forgets it would silently write a turn it may no longer own. For
  `{:orphan, _}` it may be absent, which is how the system reaper says it
  recovers on nobody's behalf; an explicit `nil` there is an expectation of
  "no sandbox" and fences like any other value.

  The answer is the write's own: `{:ok, turn}` / `:noop` / `{:error, reason}`
  for the first two, `{:ok, turn, conversation}` / `:noop` / `{:error, reason}`
  for a recovery. `:noop` is the fence refusing, or a turn another actor already
  ended; `{:error, :ownership_changed}` is the recovery path's spelling of the
  same refusal, kept because its callers log it by name.
  """
  @spec end_turn(Turn.t(), ending(), keyword()) ::
          {:ok, Turn.t()} | {:ok, Turn.t(), Conversation.t()} | :noop | {:error, term()}
  def end_turn(%Turn{} = turn, {:finish, status, extra}, opts)
      when status in @endings and is_list(extra) and is_list(opts) do
    Conversations._unsafe_complete_turn(turn, Keyword.fetch!(opts, :sandbox_id), status, extra)
  end

  def end_turn(%Turn{} = turn, :mark_interrupted, opts) when is_list(opts) do
    Interruption._unsafe_interrupt_turn(turn, Keyword.fetch!(opts, :sandbox_id))
  end

  def end_turn(%Turn{} = turn, {:orphan, why}, opts) when is_binary(why) and is_list(opts) do
    Conversations._unsafe_orphan_turn(turn, why, opts)
  end

  @doc """
  End the running turns on the machine behind `sandbox_id`, on the owner's
  behalf (ADR 0058 stage 8b): the recovery of each, through `end_turn/3` with
  the machine as the binding, so a bound conversation's turn is closed and a
  rebound one's is left to its new machine.

  `why` is the reason the turn's stage event and audit row carry
  (`"machine_destroyed"`, `"machine_parked"`). Options: `:only` narrows the
  ending to one conversation's turn — the ceiling park's requester — and
  `:actor` is the operation's, for the `conversation.turn.orphaned` event.

  Best effort per turn and deliberately so: this runs after a finalize has
  committed, and a turn that could not be ended — already ended by its actor,
  rebound, a raise out of the journal — is logged and the next one tried. It
  never unwinds the operation that called it.
  """
  @spec end_turns_on(Ecto.UUID.t(), String.t(), keyword()) :: :ok
  def end_turns_on(sandbox_id, why, opts \\ [])
      when is_binary(sandbox_id) and is_binary(why) and is_list(opts) do
    query =
      from t in Turn,
        join: c in Conversation,
        on: c.id == t.conversation_id,
        where: c.sandbox_id == ^sandbox_id and t.status == "running",
        select: t

    query =
      case Keyword.get(opts, :only) do
        nil -> query
        conv_id -> where(query, [t, c], c.id == ^conv_id)
      end

    end_opts =
      [sandbox_id: sandbox_id]
      |> Keyword.merge(Keyword.take(opts, [:actor]))

    query
    |> Repo.all()
    |> Enum.each(fn turn ->
      try do
        case end_turn(turn, {:orphan, why}, end_opts) do
          {:ok, _turn, _conv} ->
            Logger.info("machine #{sandbox_id}: ended turn #{turn.id} (#{why})")

          other ->
            Logger.info(
              "machine #{sandbox_id}: turn #{turn.id} was not this owner's to end " <>
                "(#{inspect(other)})"
            )
        end
      rescue
        error ->
          Logger.warning(
            "machine #{sandbox_id}: ending turn #{turn.id} raised: " <>
              Exception.format(:error, error, __STACKTRACE__)
          )
      end
    end)

    :ok
  end

  @doc """
  May an actor bound to `sandbox_id` end this conversation's turns?

  The one definition of the binding fence, read by
  `Fountain.Conversations.ExecutionGuard` under the parent's `FOR UPDATE` on
  both of its ending paths. True when the conversation is bound to the actor's
  sandbox **now** — a `nil` on both sides is a conversation with no machine and
  an actor that expects none, and matches. See the moduledoc for why this is
  the binding and not the lease epoch.
  """
  @spec bound?(Conversation.t() | %{sandbox_id: term()}, Ecto.UUID.t() | nil) :: boolean()
  def bound?(%{sandbox_id: current}, sandbox_id), do: current == sandbox_id
end
