defmodule Fountain.Machines.Lease do
  @moduledoc """
  The durable half of a machine's ownership (ADR 0058).

  A process alone cannot be the owner of a sandbox: two instances of it exist
  across a rolling deploy, and registry propagation is asynchronous, so "no
  live server here" is not evidence of absence. The source of truth is
  therefore a lease on the `sandboxes` row. `lease_epoch` is a monotonic
  integer that is never reused; a claimant takes the next one under the
  per-sandbox advisory lock, and every write the holder then makes is a
  compare-and-set on that epoch. A write from a superseded epoch matches zero
  rows and tells its caller `:stale` or `:lost`, which is how a partitioned
  node that completes a provider call it started makes no visible change.

  An epoch on its own is not a lease. `lease_epoch` defaults to `0` on every
  row, `release/2` keeps the epoch it surrendered, and neither of those is a
  lease anybody holds — so `renew/4`, `release/2` and `cas_update/3` all match
  on the holder columns as well as the epoch, and refuse an epoch below `1`
  before they query at all. Without that, a caller that never claimed could
  renew a lease into existence and make a machine unclaimable for a whole TTL.

  Takeover is by expiry, with one early door (stage 8b). `take_over/4` still
  serializes on the sandbox lock, still re-reads the row `FOR UPDATE`, and
  still refuses while `lease_until` is in the future — unless the holder's
  `lease_node` is not a connected node **and** the lease has run down below
  `absent_node_headroom_ms/0`, *half* a renew interval of the shortest TTL.

  Half, and not a whole one, because of where a live renewer actually sits. It
  renews every third of its TTL (`Machines.Renewal`), so it stands at two
  thirds of the TTL with every renewal made, at **one third — one whole renew
  interval — with a single renewal missed**, and at nothing with two missed in
  a row. One renew interval is therefore a line a live, renewing holder
  *touches*, not one it stays above: with the headroom set there, one slow
  renewal plus a few milliseconds of latency evicted a holder that was alive,
  renewing and mid-operation, forty seconds before its lease was due (round 1,
  protocol review, driven with a real renewer and one faulted renewal). At half
  an interval a holder may miss one renewal outright and keep its machine.

  **The bound that makes that true is the renewer's, not this constant's**
  (round 3). `Machines.Renewal` schedules each attempt from the slot it was due
  in rather than from the moment the last one returned, so an attempt that
  fails — however slowly, as long as it returns inside its own slot — costs the
  cadence nothing, and a single miss still leaves one whole interval. Before
  that, a failing attempt's own duration came out of this headroom as well: a
  12 s stall at TTL 60, well inside `DBConnection`'s ordinary timeout, left 8 s
  and the holder was taken while alive and still reporting `:held`. What is left
  is the honest residue — a *single* attempt overrunning its slot by more than
  this headroom, which is 30 s at TTL 60, measured to the next attempt
  *starting*, so the true margin is tighter by what that attempt then costs —
  and two missed renewals in a row have expired the lease anyway. Below the line it is a node that died with the
  lease, and every other owner was waiting out the rest of its TTL for
  nothing. A node name on its own decides nothing (#2307 constraint 4): a
  partitioned holder that is alive is still renewing, and its lease stays above
  the line. A lease is surrendered early only by `release/2`, and even that
  keeps the epoch.

  **The clock is the database's** (stage 7a). It used to be the claiming
  node's: `lease_until` was written from one BEAM node's `DateTime.utc_now()`
  and compared against another's, which is N clocks rather than one. Skew was
  never a correctness hole — an early takeover is what the compare-and-set
  already makes safe, and a late one only delays recovery — but a renew timer
  makes the question sharper, because a holder that renews on a fast clock and
  a reaper that judges on a slow one disagree about a *live* operation rather
  than an abandoned one. So `claim/4`, `take_over/4` and `renew/4` now compute
  `lease_until` in SQL, and every liveness read compares against the same
  database's clock. There is one clock, and no node's drift can shorten or
  lengthen a lease anybody else can see.

  **`statement_timestamp()`, not `now()`**, and the difference matters. Postgres'
  `now()` is `transaction_timestamp()`: it is frozen for the whole of an
  enclosing transaction, so a claim and a takeover made inside one would be
  dated from the same instant however far apart they ran, and a lease could
  never expire while its reader sat in a transaction that started before it was
  written. `statement_timestamp()` advances between statements and is stable
  within one, which is exactly a lease's unit of time. A caller that wants one
  instant for a page of rows gets it by fetching `now/0` once and passing it,
  which is what the sweeps do, rather than by relying on a transaction to hold
  the clock still.

  **And `AT TIME ZONE 'UTC'` on every write and every in-SQL comparison**, which
  is not decoration (round 1, behaviour review). `lease_until` is
  `timestamp without time zone`, as every timestamp column in this schema is —
  Ecto's `:utc_datetime_usec` — while `statement_timestamp()` is a
  `timestamptz`. Assigning one to the other casts through the **session's**
  `TimeZone`, so a connection running under, say, `America/New_York` would write
  a deadline four hours behind the UTC instants Elixir compares it against:
  every live lease reads dead, `busy?/2` answers false for every operation in
  flight, and `claim/4` refuses nobody. `statement_timestamp() AT TIME ZONE 'UTC'`
  is a `timestamp` holding the UTC wall time whatever the session says, which is
  what the column means everywhere else.

  The column stays `timestamp` rather than becoming `timestamptz`. Making one
  column of `sandboxes` differ from every other would be its own trap, and a
  migration in the middle of an open stack is the version collision #2344's
  stage 3 already had to check for — where the cast is a one-expression fix that
  a test pins under a hostile `TimeZone`.

  The `now` argument each of those functions still takes is the test seam and
  nothing more. `:db` — the default, and what every caller in `lib/` passes by
  omission — means "the database's clock". A `DateTime` means "judge and date
  from this instant instead", which is how a test reaches an expired lease
  without sleeping for a minute. Production never passes one.

  Every function here is one short statement or transaction, and refuses to run
  inside an enclosing one (`{:error, :transaction_open}`) unless the caller says
  the nesting is deliberate — one caller does, and `cas_update/4`'s `nest:`
  option is where that is argued. The guard is the same one
  `Fountain.Conversations.Lifecycle.fence_sandbox_for_teardown/2` uses.
  Nesting would join the caller's
  transaction through a savepoint and hold a transaction-scoped advisory lock
  until the outer commit, which is exactly the "short transaction" this module
  promises not to be. Provider I/O happens in the owner, between these calls,
  never inside one. The one exception is `cas_update/3`'s *refusal* path, which
  runs a second read to tell `:stale` from `:retired`; the write it explains has
  already failed by then, so the two are not wrapped together and the diagnosis
  is a fresh look at the row rather than the state the write saw.

  Nothing user-facing happens here, so nothing here is audited: a lease is
  control-plane bookkeeping, and the events an operation owes — `sandbox.destroyed`
  and its siblings — are recorded by the owner's verbs.

  The write half has four callers, and they are the four protocols: `Destroy`
  since stage 5a, `Park` since 6b, `Resume` since 7a and `Provision` since 7b. Each claims a lease around one operation,
  stamps the transition, does its provider I/O outside every lock, finalizes
  with `cas_update/3` and releases. A park additionally writes `provider_meta`
  mid-transition, through the same primitive and the same epoch — see
  `@writable`.

  The read half has more callers, and `live?/2` is all of them. Until stage 6a
  there were three separate readings of "is an owner working on this machine",
  two of them SQL `where` clauses and one an Elixir predicate, and they had
  already drifted — the SQL pair tested `lease_until` alone where `claim/4`
  decides on the holder columns too. They are now one function:
  `Workers.SandboxReaper.sweep_fenced_teardowns/0` (5a),
  `Workers.SandboxResetReconciler`'s sweep and
  `Conversations.retry_pending_sandbox_reset/2` (5c), and — new in 6a — the
  three readers that refuse a wake, an attach or a rehydrate onto a machine
  mid-operation, through `Machines.Machine.busy?/2`. They read the columns;
  they never write one.

  Stage 7a added the third write caller, `Resume`, and gave all three a renew
  timer: `Machines.Renewal` calls `renew/4` from a process of its own while the
  provider call runs, so a lease bounds an operation that is *making progress*
  rather than one that started less than a TTL ago. The lease is still
  per-operation — an idle machine holds none, which is what keeps stage 6a's
  "busy means a live lease" true.
  """

  import Ecto.Query

  alias Fountain.Conversations
  alias Fountain.Conversations.Sandbox
  alias Fountain.Repo

  require Logger

  @typedoc "A lease generation. Monotonic per sandbox; never reused."
  @type epoch :: non_neg_integer()

  @typedoc "Why a claim was refused: someone else holds a lease that has not expired."
  @type held :: {:held, String.t(), DateTime.t()}

  # How far a lease may have run down before a holder that is not a connected
  # node is taken over early. **Half** a renew interval of the shortest TTL the
  # protocols use (60s / `Renewal.divisor/0` / 2): a live renewer of that TTL
  # sits at one whole interval with a single renewal missed, so a headroom of
  # one interval carries no margin at all and takes the machine off a holder
  # whose next renewal is milliseconds late (round 1). Half of it tolerates one
  # missed renewal outright — and, since round 3 made `Renewal` schedule from
  # the slot rather than from the last return, a failing attempt of any length
  # that still returns inside its own slot — while giving back the other fifty
  # seconds of a dead node's TTL. The residue is a single attempt overrunning
  # its slot by more than this much. A holder of a longer TTL sits higher
  # still. `machine_bounds_test.exs` pins it against every protocol's TTL.
  @absent_node_headroom_ms 10_000

  # The only columns a machine's owner may write through `cas_update/3`.
  # `lease_*` are absent on purpose — a lease changes hands through the
  # functions below, under the lock, and never as a side effect of a state
  # write.
  #
  # `provider_meta` joined them in stage 6b. It is not machine *state* the way
  # the others are, but it is written in the middle of a transition and by the
  # owner that holds it: `HomeCheckpoint.on_park/2` records the checkpoint it
  # just took while the row says `parking`, and that write has to be invisible
  # if the park has been superseded, for the same reason the finalize does —
  # a checkpoint id belonging to an operation that no longer owns the machine
  # would be read back by a reset as the state to roll to.
  #
  # `build_fingerprint` and `applied_skills` joined them in stage 7b, for the
  # same reason and at the other end of the same argument. They are the record
  # of *what the disk was built from* — the environment digest a later reapply
  # compares against, and the skills the machine has mounted — and the provision
  # writes them in the one statement that makes the machine `ready`. A superseded
  # provision must not leave them behind: a fingerprint describing a build
  # another owner threw away is exactly the reading
  # `Reapply.needs_rebuild?/2` would trust and be wrong about.
  @writable ~w(status transition transition_reason terminated_at last_resumed_at provider_meta
               build_fingerprint applied_skills)a

  # Where a sandbox stops. Kept in step with `@billable_terminal` in
  # `Fountain.Conversations`, whose `prevent_sandbox_revival/1` this mirrors.
  @terminal_statuses ~w(terminated failed)

  @doc """
  Is somebody holding this machine right now?

  **The one definition, for readers inside this namespace and out.** Stage 6a
  replaced three copies of it — `SandboxReaper.sweep_fenced_teardowns/0`'s and
  `SandboxResetReconciler`'s `where` clauses, both written in SQL, and
  `Conversations.machine_lease_live?/1`, written in Elixir — with this. Three
  renderings of one rule is three chances to disagree about what an unheld row
  looks like, and the SQL pair had already dropped the `lease_node` half that
  `claim/4` decides on.

  Takes a `Sandbox` (or any map carrying `:lease_node` and `:lease_until`, so a
  query may `select` the two columns rather than the row) and the clock to
  judge against. Both halves matter: a `lease_until` with no `lease_node` would
  refuse a claim and name the holder as `nil`, which tells an operator a machine
  is held by nothing. `held_by/2` makes that state unreachable; this makes it
  unreadable as "held" even so.

  **The clock is the database's** (stage 7a), and `:db` — the default — fetches
  it. `lease_until` is written from that clock in SQL, so judging it
  against a BEAM node's `DateTime.utc_now()` compared two clocks; there is one
  now. The fetch is one trivial round trip, and a caller that is about to read
  or has just read the row pays it on the same connection.

  A sweep judging a page of rows passes `now/0` once rather than letting each
  row fetch its own, which is both cheaper and the thing that makes a page one
  verdict. A caller already inside a transaction gets that for free: `now()` is
  `transaction_timestamp()`, so the row it read `FOR UPDATE` and the instant it
  judges against come from the same moment.

  A `DateTime` may be passed instead, and only tests do: see the moduledoc's
  note on the seam.
  """
  @spec live?(Sandbox.t() | map(), DateTime.t() | :db) :: boolean()
  def live?(sandbox, now \\ :db)

  def live?(%{lease_node: node, lease_until: until}, now)
      when is_binary(node) and not is_nil(until),
      do: DateTime.compare(until, at(now)) == :gt

  # Both keys, always, and a `FunctionClauseError` for a map carrying neither
  # (round 1, locks review). The first draft matched `%{lease_node: nil}` and
  # `%{lease_until: nil}` in turn, so a map *missing* `:lease_node` fell through
  # to the deadline clause and read as held on the deadline alone — the exact
  # drift this function was written to remove, back as a map-shape hazard, and
  # reachable: `SandboxResetReconciler`'s sweep hand-writes its `select` map, so
  # a `select` that forgot the holder would have called every fenced row held
  # with every test still green.
  def live?(%{lease_node: _, lease_until: _}, _now), do: false

  @doc """
  The database's clock, for a caller that judges more than one row against it.

  One `select statement_timestamp()`. A sweep fetches it once and hands it to
  `live?/2` for every row in the page; `Machine.busy?/2` lets it default and
  pays for the one row it is asking about.

  `statement_timestamp()` rather than `now()` — and the docstring said `now()`
  until stage 7b, describing the one thing this function is careful not to do:
  `now()` is `transaction_timestamp()` and freezes for a whole transaction, so a
  lease could never expire while its reader sat in one that started before it
  was written. See the moduledoc.
  """
  @spec now() :: DateTime.t()
  def now do
    %Postgrex.Result{rows: [[%DateTime{} = now]]} = Repo.query!("SELECT statement_timestamp()")
    now
  rescue
    # Every other entry point here turns a database fault into
    # `{:error, {:database, sqlstate}}` rather than an exception, and this one
    # cannot: its callers are predicates — `live?/2`, and through it
    # `Machine.busy?/2` — and a predicate has nowhere to put an error tuple.
    # Raising instead would unwind a wake, an attach or a boot sweep out of a
    # function whose whole job is to answer true or false (round 1, protocol
    # review).
    #
    # So the fallback is the clock this module used until stage 7a. That is not
    # a silent revert: a caller that cannot reach the database is about to fail
    # its next query anyway, with a value-shaped error of its own, and in the
    # meantime the two clocks are within a few milliseconds of each other on any
    # host that is not already broken. What the database's clock buys is that
    # *every node agrees*, and one node briefly disagreeing during an outage is
    # the pre-7a arrangement, which was safe.
    error in [Postgrex.Error, DBConnection.ConnectionError] ->
      Logger.warning(
        "machine lease clock unreachable (#{inspect(sqlstate(error))}); " <>
          "judging liveness on this node's clock until it comes back"
      )

      DateTime.utc_now()
  end

  # `:db` is the default every caller in `lib/` uses; a `DateTime` is the test
  # seam. Nothing else is accepted, so a caller that passes `nil` by accident
  # gets a `FunctionClauseError` here rather than a lease that never expires.
  defp at(:db), do: now()
  defp at(%DateTime{} = now), do: now

  @doc """
  The remaining lease under which a holder that is not a connected node is
  taken over before `lease_until`. See the moduledoc, and
  `machine_bounds_test.exs` for the pin.
  """
  @spec absent_node_headroom_ms() :: pos_integer()
  def absent_node_headroom_ms, do: @absent_node_headroom_ms

  @doc """
  Take the lease on `sandbox_id` for `node`, for `ttl_ms` from `now`.

  Serializes on the per-sandbox advisory lock, re-reads the row `FOR UPDATE`,
  and refuses with `{:error, {:held, node, until}}` when the current lease has
  not expired. The verdict is made on the locked read, never on a struct the
  caller brought: a pre-lock reading is stale by construction.

  On success the epoch advances by exactly one and is returned. The holder
  quotes it on every subsequent write.

  Expiry is decided, and the new `lease_until` written, on the database's clock
  (`:db`, the default) in the same short transaction — so the instant the old
  lease is judged against and the instant the new one is dated from are the
  same one, and no BEAM node's drift reaches the column. A `DateTime` is the
  test seam.
  """
  @spec claim(Ecto.UUID.t(), String.t(), pos_integer(), DateTime.t() | :db) ::
          {:ok, epoch()}
          | {:error,
             :not_found | :lost | :transaction_open | {:invalid, :sandbox_id} | held() | term()}
  def claim(sandbox_id, node, ttl_ms, now \\ :db)
      when is_binary(sandbox_id) and is_binary(node) and is_integer(ttl_ms) and ttl_ms > 0 do
    guarded(sandbox_id, fn -> do_claim(:claim, sandbox_id, node, ttl_ms, now) end)
  end

  @doc """
  Take a lease whose holder is gone.

  Identical to `claim/4` in every respect but its log line — deliberately, and
  said here so no later reader mistakes it for a stronger primitive. There is
  no way to evict a live holder: recovery after a crash or a partition is that
  the lease expires, a new claimant takes a new epoch under the lock, and the
  old holder's in-flight writes then fail their compare-and-set. A TTL that has
  not run out is not a hand-over, and this function will not make one.
  """
  @spec take_over(Ecto.UUID.t(), String.t(), pos_integer(), DateTime.t() | :db) ::
          {:ok, epoch()}
          | {:error,
             :not_found | :lost | :transaction_open | {:invalid, :sandbox_id} | held() | term()}
  def take_over(sandbox_id, node, ttl_ms, now \\ :db)
      when is_binary(sandbox_id) and is_binary(node) and is_integer(ttl_ms) and ttl_ms > 0 do
    guarded(sandbox_id, fn -> do_claim(:take_over, sandbox_id, node, ttl_ms, now) end)
  end

  @doc """
  Extend the lease held at `epoch` to `ttl_ms` past `now`.

  One `update_all` guarded by the epoch *and the holder columns* — no lock and
  no read beyond that. `{:error, :lost}` covers every way this caller is not
  the holder: the lease was taken over, it was released (`release/2` keeps the
  epoch, so the epoch alone would still match and this would re-arm the lease
  it just gave up), it was never claimed, or the row is gone. Either way the
  caller no longer owns the machine and must stop.

  It does **not** extend a lease into existence. A row nobody has claimed has
  `lease_node` and `lease_until` nil at epoch 0, and stays that way.

  The new deadline is `statement_timestamp() + ttl` on the database's clock,
  like a claim's.
  `Fountain.Machines.Renewal` is the caller: it runs this on a timer, from a
  process of its own, while a protocol's provider call is in flight, and treats
  `{:error, :lost}` as the takeover it is.
  """
  @spec renew(Ecto.UUID.t(), epoch(), pos_integer(), DateTime.t() | :db) ::
          :ok | {:error, :lost | :transaction_open | {:invalid, :sandbox_id} | term()}
  def renew(sandbox_id, epoch, ttl_ms, now \\ :db)
      when is_binary(sandbox_id) and is_integer(epoch) and is_integer(ttl_ms) and ttl_ms > 0 do
    guarded(sandbox_id, fn ->
      if taken_epoch?(epoch) do
        case sandbox_id |> held_by(epoch) |> set_deadline(now, ttl_ms) |> Repo.update_all([]) do
          {1, _} -> :ok
          {0, _} -> {:error, :lost}
        end
      else
        {:error, :lost}
      end
    end)
  end

  @doc """
  Give the lease up.

  Clears `lease_node` and `lease_until` and keeps `lease_epoch` where it is:
  epochs are monotonic and never reused, so the next claimant still gets a
  strictly higher one and this holder's outstanding writes still fail. Guarded
  on the holder columns too, so releasing twice is `{:error, :lost}` rather
  than a second success — after the first, this caller is no longer the holder,
  and saying otherwise is what let a late `renew/4` undo it.
  """
  @spec release(Ecto.UUID.t(), epoch()) ::
          :ok | {:error, :lost | :transaction_open | {:invalid, :sandbox_id} | term()}
  def release(sandbox_id, epoch) when is_binary(sandbox_id) and is_integer(epoch) do
    guarded(sandbox_id, fn ->
      if taken_epoch?(epoch) do
        case Repo.update_all(held_by(sandbox_id, epoch),
               set: [lease_node: nil, lease_until: nil]
             ) do
          {1, _} -> :ok
          {0, _} -> {:error, :lost}
        end
      else
        {:error, :lost}
      end
    end)
  end

  @doc """
  Write machine state, if and only if `epoch` is still the lease.

  The one write primitive the owner uses. One `update_all` matching on the
  epoch *and the holder columns*, returning the row it wrote; zero rows is
  `:stale`, which is the whole protocol in one word — a superseded owner
  changes nothing and learns so. A lease that was released, or an epoch no
  claim ever handed out, is `:stale` for the same reason: neither is held.

  `attrs` is a plain map or a keyword list — **a struct is refused**
  (`{:error, {:invalid, :attrs}}`) even though it is a map, because nothing an
  owner writes is built by handing this function a schema. It may name only
  #{inspect(@writable)}, with atom keys, each at most
  once. `status` must be a member of `Sandbox.statuses/0` and `transition` of
  `Sandbox.transitions/0` (`nil` clears it, which is how a transition
  finalizes); anything else is `{:error, {:invalid, field}}` and the row is
  untouched. That is **membership, not legality** — whether a particular
  transition is allowed from a particular state belongs to `Machines.Policy`
  in a later stage, and nothing here decides it. The one exception is
  retirement: a terminal row is never written back to a live status, the same
  refusal `Conversations.update_sandbox/2` gets from
  `prevent_sandbox_revival/1`, reported as `{:error, :retired}` so the owner
  does not mistake it for a takeover.

  **`:stale` beats `:retired`.** A superseded epoch is `:stale` even on a
  retired row; `:retired` means you *are* the holder and the row is terminal. A
  caller that no longer owns the machine has no business being told the row's
  status, and the diagnosis reads through the same held-lease predicate the
  write did, so it falls to `:stale` before the status is ever consulted.

  **`destroying` survives a write that would clear it** (stage 9a). On a row
  that is not yet terminal, a write naming `transition` as anything but
  `"destroying"` leaves the stamp and its reason exactly where they are, and
  returns the row saying so — the caller's other columns land, the intent does
  not move. That is what makes `destroying` the one *durable* transition: every
  other stamp is an abandoned operation a later owner clears, and this one is a
  request that outlives the owner that was serving it. Three writes pass
  through: a re-stamp of `destroying` itself, a write that retires the row
  (which is the destroy finishing), and any write to a row that is *already*
  terminal, where the stamp is leftovers rather than intent. See
  `preserve_destroying/2`.

  A write that moves the status to `terminated` or `failed` stamps
  `terminated_at` when the row has none, mirroring
  `Conversations.stamp_terminated_at/1` — see `stamp_terminated_at/2` below for
  why that matters and where it is deliberately narrower.

  Deliberately takes no advisory lock: a single guarded `update_all` is already
  atomic, and the serialization this needs was done when the epoch was taken.

  **`nest: true` permits an enclosing transaction**, which every other function
  here refuses, and there are two callers. `Machines.Resume`'s admission runs
  this inside `Quotas.with_sandbox_reservation/3`'s transaction so that the
  `resuming` stamp and the quota count that authorised it commit together.
  `Machines.Provision.fail/2` runs it beside its caller's own write, so that
  `Launch.fail_initial_start/2` fails a conversation and its machine in one
  commit or neither — which `main` did under the per-sandbox advisory lock, and
  which the machine's row leaving that lock's reach would otherwise have cost. The
  moduledoc's reason for the guard does not reach this function — it is about
  holding `pg_advisory_xact_lock(4316, …)` until an outer commit, and this takes
  no advisory lock — and the *other* thing nesting does, joining the caller's
  transaction so a rollback undoes the write, is exactly what a reservation
  wants: a refused quota must leave no stamp behind. It is opt-in rather than
  the default because everywhere else an enclosing transaction is the mistake
  the guard exists to catch, and the option makes a reviewer look at the one
  place it is not.

  Two consequences a caller passing it owns. The diagnosis of a zero-row write
  runs a second read *inside* that transaction, so it sees the transaction's own
  uncommitted rows — which is right here, since the only writer of this row in
  this transaction is this call. And an error out of the nested `Repo.update_all`
  aborts the enclosing transaction, so the caller must treat any `{:error, _}`
  from here as fatal to the whole reservation rather than something to continue
  from; `Resume` does, by returning it and letting `with_sandbox_reservation/3`
  roll back.

  It does not consult `lease_until`, and that is the contract, not an
  omission: an expired lease nobody has taken over is still held by its owner,
  and that owner finishing the work it started is what should happen. What the
  CAS buys is that the moment a takeover has happened, the old holder's write
  is invisible — the ADR's answer to a partitioned node completing a provider
  call. Nothing here refuses a write for a lapsed clock alone — `renew/4` does
  not either — so a holder that wants to stop early keeps that deadline itself.
  """
  @spec cas_update(Ecto.UUID.t(), epoch(), map() | keyword(), keyword()) ::
          {:ok, Sandbox.t()}
          | {:error,
             :stale | :retired | :fenced | :transaction_open | {:invalid, atom()} | term()}
  def cas_update(sandbox_id, epoch, attrs, opts \\ [])
      when is_binary(sandbox_id) and is_integer(epoch) and is_list(opts) do
    guarded(sandbox_id, Keyword.get(opts, :nest, false), fn ->
      if taken_epoch?(epoch) do
        with {:ok, sets} <- cast_attrs(attrs) do
          # `updated_at` moves with a state change but not with a renewal: a
          # lease heartbeat every few seconds would otherwise make the column
          # mean nothing to anyone reading the table.
          sets = Keyword.put(sets, :updated_at, DateTime.utc_now() |> DateTime.truncate(:second))

          {query, sets} =
            sandbox_id
            |> held_by(epoch)
            |> refuse_revival(sets)
            |> refuse_fenced(Keyword.get(opts, :refuse_fenced, false))
            |> stamp_terminated_at(sets)
            |> select([s], s)
            |> preserve_destroying(sets)

          case Repo.update_all(query, set: sets) do
            {1, [sandbox]} -> {:ok, sandbox}
            {0, _} -> {:error, zero_row_reason(sandbox_id, epoch, opts)}
          end
        end
      else
        {:error, :stale}
      end
    end)
  end

  defp do_claim(kind, sandbox_id, node, ttl_ms, now) do
    Conversations.with_sandbox_lock(sandbox_id, fn ->
      # The clock rides along with the locked read rather than being fetched
      # separately — one round trip instead of two, and the instant the old
      # lease is judged against is read in the same breath as the row. With an
      # injected clock the seam wins and the column is unused.
      current =
        Repo.one(
          from s in Sandbox,
            where: s.id == ^sandbox_id,
            select: %{
              epoch: s.lease_epoch,
              lease_node: s.lease_node,
              lease_until: s.lease_until,
              # Read into Elixir rather than assigned to the column, so this one
              # stays a `timestamptz`: Postgrex decodes it to a `DateTime` in
              # UTC, which is what `lease_until` loads as. The `AT TIME ZONE`
              # cast belongs on the write and on in-SQL comparisons, not here.
              db_now: fragment("statement_timestamp()")
            },
            lock: "FOR UPDATE"
        )

      judged = current && judged_at(now, current)

      cond do
        is_nil(current) ->
          {:error, :not_found}

        # Through `live?/2`, deliberately: a claimant and a reader deciding
        # "is this machine held" by two different renderings of one rule is
        # what stage 6a removed, and inlining the comparison here would put it
        # back. The early door (stage 8b) is judged only on a lease `live?/2`
        # would refuse, so a reader and a claimant still agree about every row
        # that is not one a dead node left behind.
        live?(current, judged) and not abandoned_by_node?(current, judged) ->
          {:error, {:held, current.lease_node, current.lease_until}}

        true ->
          epoch = current.epoch + 1

          # The one place a bare `(id, lease_epoch)` predicate is right: the
          # row is unheld by definition — that is what is being claimed — and
          # the advisory lock plus this `FOR UPDATE` already decided who wins,
          # so `held_by/2`'s holder columns would refuse every first claim.
          # Guarded on the epoch the locked read saw all the same, because
          # answering `:lost` beats a `MatchError` unwinding out of the
          # transaction (#2329).
          claimed =
            from(s in Sandbox, where: s.id == ^sandbox_id and s.lease_epoch == ^current.epoch)
            |> update(set: [lease_epoch: ^epoch, lease_node: ^node])
            |> set_deadline(now, ttl_ms)

          case Repo.update_all(claimed, []) do
            {1, _} ->
              log_claim(kind, sandbox_id, node, epoch, current, judged)
              {:ok, epoch}

            {0, _} ->
              {:error, :lost}
          end
      end
    end)
  end

  # The early door. Both halves are required, and the order is the cheap one
  # first: a holder that *is* a connected node is never judged on its
  # remaining lease, whatever it is.
  defp abandoned_by_node?(%{lease_node: holder, lease_until: until}, now) do
    holder not in connected_nodes() and
      DateTime.diff(until, now, :millisecond) < @absent_node_headroom_ms
  end

  # This node and the ones it is connected to, in the string form `lease_node`
  # is written in. `Node.list/0` is this node's view and converges
  # asynchronously, which is why a name absent from it is only half the rule.
  defp connected_nodes, do: Enum.map([node() | Node.list()], &to_string/1)

  # The clock a claim judges the standing lease against: the one the database
  # handed back with the locked row, or the one a test injected.
  defp judged_at(:db, %{db_now: db_now}), do: db_now
  defp judged_at(%DateTime{} = now, _current), do: now

  # `lease_until` on the database's clock. `integer * interval '1 millisecond'`
  # rather than `make_interval` so the parameter stays an integer the driver
  # sends as one, and rather than a formatted string so no locale or rounding
  # sits between the TTL and the column. `AT TIME ZONE 'UTC'` because the column
  # is `timestamp without time zone` and the function is a `timestamptz` — see
  # the moduledoc for what the session's `TimeZone` does without it.
  defp set_deadline(query, :db, ttl_ms) do
    update(query,
      set: [
        lease_until:
          fragment(
            "(statement_timestamp() AT TIME ZONE 'UTC') + ? * interval '1 millisecond'",
            ^ttl_ms
          )
      ]
    )
  end

  defp set_deadline(query, %DateTime{} = now, ttl_ms),
    do: update(query, set: [lease_until: ^DateTime.add(now, ttl_ms, :millisecond)])

  defp log_claim(:take_over, sandbox_id, node, epoch, %{lease_node: previous}, _judged) do
    Logger.info(
      "machine lease taken over on sandbox #{sandbox_id} by #{node} at epoch #{epoch}; " <>
        "previous holder #{previous || "none"} had expired"
    )
  end

  # A claim that took a lease still in the future says so, at warning: it is
  # the one place a claim wins before `lease_until`, it means a node died with
  # the machine, and an operator reading the log for a machine that changed
  # hands early should find why without turning the level down.
  defp log_claim(:claim, sandbox_id, node, epoch, current, judged) do
    if live?(current, judged) do
      Logger.warning(
        "machine lease on sandbox #{sandbox_id} taken by #{node} at epoch #{epoch} before " <>
          "its expiry (#{inspect(current.lease_until)}): previous holder " <>
          "#{current.lease_node} is not a connected node and had stopped renewing"
      )
    end

    :ok
  end

  # A lease that is really held, at exactly this epoch. The epoch alone is not
  # enough, twice over: `lease_epoch` defaults to 0 on every row, so an
  # epoch-only match makes the lease nobody took quotable by anybody; and
  # `release/2` keeps the epoch on purpose, so it would leave a surrendered
  # lease re-armable by a `renew/4` that lands after it. Requiring the holder
  # columns closes both, and `taken_epoch?/1` refuses 0 before the query.
  defp held_by(sandbox_id, epoch) do
    from s in Sandbox,
      where:
        s.id == ^sandbox_id and s.lease_epoch == ^epoch and
          not is_nil(s.lease_node) and not is_nil(s.lease_until)
  end

  # `do_claim/5` hands out 1 first, so anything below it is not an epoch a
  # claim ever produced — it is the column default wearing an epoch's clothes.
  defp taken_epoch?(epoch), do: epoch >= 1

  # Mirrors `Fountain.Conversations.prevent_sandbox_revival/1`: holding the
  # lease is not permission to un-retire a row. Terminal-to-terminal still goes
  # through and a write that never names a status is not a revival, so the two
  # refusals agree exactly.
  defp refuse_revival(query, sets) do
    case Keyword.get(sets, :status) do
      nil -> query
      status when status in @terminal_statuses -> query
      _live -> from(s in query, where: s.status not in @terminal_statuses)
    end
  end

  # Mirrors `Fountain.Conversations.stamp_terminated_at/1`, the second of
  # `Conversations.update_sandbox/2`'s two guards and the one with a billing
  # consequence:
  # `Billing.SandboxUsage` reads `terminated_at` as the end of the billed
  # interval, and of the writers of a terminal status the ones that *fail* a
  # machine never pass a timestamp — which once left every failed sandbox
  # reading as still running. `cas_update/3` is another such writer.
  # `COALESCE` in the database rather than a read here keeps the write one
  # statement and keeps a caller's own timestamp, so this only fills a gap.
  #
  # Narrower than the original on purpose. `stamp_terminated_at/1` works off
  # `get_field/2`, which falls back to the *stored* status, so it also repairs
  # a status-free write to an already-terminal row. This fires only on the
  # transition into a terminal status, which is the case with the hazard; a
  # write that never names a status leaves the column alone.
  defp stamp_terminated_at(query, sets) do
    if Keyword.get(sets, :status) in @terminal_statuses and
         not Keyword.has_key?(sets, :terminated_at) do
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      from(s in query, update: [set: [terminated_at: coalesce(s.terminated_at, ^now)]])
    else
      query
    end
  end

  # `destroying` is the one transition a write may not take off a live row
  # (ADR 0058 stage 9a). Every other stamp is abandonable: a reader that finds
  # `parking` or `resuming` with no live lease is looking at an owner that
  # died, and three sites clear it on sight so the machine can be used again.
  # `destroying` is the opposite statement — somebody asked for this machine to
  # go away, and an owner dying halfway through does not withdraw the request —
  # which is what lets stage 9b drop `reset_requested_at` and
  # `teardown_requested_at` and leave the intent on this column alone.
  #
  # Enforced here rather than only at the callers because the write that would
  # lose it is not a clearing write at all. `Machines.Park`'s finalize writes
  # `status: "suspended", transition: nil` on a row it stamped `parking`, and a
  # teardown fence committing *during* the suspend — the fence takes the
  # advisory lock, the park holds only its lease — lands on that row between the
  # stamp and the finalize. Under 9a the fence columns catch it; under 9b they
  # are gone, and nothing but this would. So the park still finalizes (the
  # machine really is suspended and the row must say so) and the stamp rides
  # through, for the driver to finish.
  #
  # **Three writes deliberately pass.** A write that names `transition:
  # "destroying"` is a re-stamp, which is how a second destroy records its own
  # reason. A write that moves the row to a terminal status is the destroy
  # finishing, and clearing the stamp there is the finalize. And a stamp on a
  # row that is *already* terminal is not intent but leftovers —
  # `Destroy.clear_stale_transition/2`'s tidying after
  # `SandboxReaper.finish_teardown/1` wrote a row terminal without an epoch —
  # so the guard reads the row's status, not only the write's.
  #
  # The columns leave `sets` when it fires, because Ecto raises on a field set
  # twice; `stamp_terminated_at/2` avoids the same collision by checking the
  # caller did not name the column at all.
  @destroying "destroying"

  defp preserve_destroying(query, sets) do
    if preserving?(sets) do
      query =
        from(s in query,
          update: [
            set: [
              transition:
                fragment(
                  "CASE WHEN ? = ? AND ? NOT IN ('terminated', 'failed') THEN ? ELSE ? END",
                  s.transition,
                  ^@destroying,
                  s.status,
                  s.transition,
                  type(^Keyword.get(sets, :transition), :string)
                )
            ]
          ]
        )

      {preserve_reason(query, sets), Keyword.drop(sets, [:transition, :transition_reason])}
    else
      {query, sets}
    end
  end

  # **Only when the caller named it.** A write that names `transition` alone —
  # `Resume.stamp/2` is the one today — used to leave `transition_reason`
  # untouched, because `update_all` writes the columns it is given and no
  # others. The first draft of `preserve_destroying/2` moved *both* columns into
  # `CASE` fragments unconditionally, so the reason's `ELSE` branch was a `nil`
  # nobody had asked for: a stamp that named one column silently erased the
  # other (protocol review, promoted to a blocker). The guard is the caller's
  # own key, so this preserves a stamp without inventing a write.
  defp preserve_reason(query, sets) do
    if Keyword.has_key?(sets, :transition_reason) do
      from(s in query,
        update: [
          set: [
            transition_reason:
              fragment(
                "CASE WHEN ? = ? AND ? NOT IN ('terminated', 'failed') THEN ? ELSE ? END",
                s.transition,
                ^@destroying,
                s.status,
                s.transition_reason,
                type(^Keyword.get(sets, :transition_reason), :string)
              )
          ]
        ]
      )
    else
      query
    end
  end

  # A write is at risk of losing the stamp when it names `transition` as
  # something other than `destroying` and does not retire the row. A write that
  # names neither column touches neither, and a write that names only
  # `transition_reason` cannot orphan a stamp it is not moving.
  defp preserving?(sets) do
    Keyword.has_key?(sets, :transition) and
      Keyword.get(sets, :transition) != @destroying and
      Keyword.get(sets, :status) not in @terminal_statuses
  end

  # **`refuse_fenced: true`** additionally requires both fence columns to be
  # null **and no `destroying` stamp** (the stamp since stage 9a, so the check
  # survives the columns), and it is opt-in for the same reason `nest:` is:
  # everywhere else the fence is not this write's business.
  #
  # `Destroy` writes a terminal status onto a row it has just fenced, and
  # `Park`'s finalize is allowed to land on a fence that arrived mid-operation
  # (stage 6b decided that). What cannot be allowed is the third case, and it
  # arrived with stage 7b: a *provision* finishing onto a row somebody asked to
  # be reset while the machine was being built. `Conversations.update_sandbox/2`
  # refuses exactly that — it rolls back with `:sandbox_reset_pending` unless the
  # write is terminal — and it was the only thing refusing it, so a bracket that
  # wrote `ready` through `cas_update/4` without this would have handed a
  # conversation a machine the reset reconciler was about to delete.
  #
  # **Both fence columns, where `update_sandbox/2` read only the reset one**
  # (round 1, behaviour review). That is wider than the thing it replaces, and
  # deliberately: a `ready` finalize landing on a *teardown*-fenced row hands a
  # conversation a machine somebody has asked to be destroyed, which
  # `SandboxReaper.sweep_fenced_teardowns/0` then finishes underneath it.
  # `Provision.admissible/1` refuses on either fence for the same reason, so the
  # two ends of the bracket agree about what a fence means.
  defp refuse_fenced(query, false), do: query

  defp refuse_fenced(query, true) do
    from s in query,
      where:
        is_nil(s.reset_requested_at) and is_nil(s.teardown_requested_at) and
          (is_nil(s.transition) or s.transition != ^@destroying)
  end

  # Only on the refusal path, so the write itself stays one statement. Without
  # it a revival and a takeover are the same zero rows, and an owner told
  # `:stale` would go looking for a successor that never existed.
  #
  # The order is the order the write applies them, so the reason names the
  # first thing that refused: not the holder, then retired, then fenced.
  defp zero_row_reason(sandbox_id, epoch, opts) do
    case Repo.one(
           from s in held_by(sandbox_id, epoch),
             select: map(s, [:status, :reset_requested_at, :teardown_requested_at, :transition])
         ) do
      nil ->
        :stale

      %{status: status} when status in @terminal_statuses ->
        :retired

      row ->
        if Keyword.get(opts, :refuse_fenced, false) and fenced?(row),
          do: :fenced,
          else: :stale
    end
  end

  # The three things `refuse_fenced/2` requires to be absent, read back in the
  # same words so the diagnosis and the write cannot disagree about what a
  # fence is.
  defp fenced?(row) do
    not is_nil(row.reset_requested_at) or not is_nil(row.teardown_requested_at) or
      row.transition == @destroying
  end

  # A struct is a map, so `is_map/1` and the `@spec` both let one through, and
  # `Enum.reduce_while/3` then raises `Protocol.UndefinedError` on it. Refused
  # like every other caller bug rather than raised, and said in the docstring.
  defp cast_attrs(attrs) when is_struct(attrs), do: {:error, {:invalid, :attrs}}

  defp cast_attrs(attrs) when not is_map(attrs) and not is_list(attrs),
    do: {:error, {:invalid, :attrs}}

  defp cast_attrs(attrs) when attrs == %{} or attrs == [], do: {:error, {:invalid, :attrs}}

  defp cast_attrs(attrs) do
    Enum.reduce_while(attrs, {:ok, []}, fn {field, value}, {:ok, sets} ->
      # A keyword list can name the same column twice, which reaches Ecto as
      # two `SET` clauses and raises `Ecto.QueryError` mid-transaction. It is a
      # caller's bug either way, so it is refused here like any other bad attr.
      with {:ok, casted} <- cast_attr(field, value),
           false <- List.keymember?(sets, field, 0) do
        {:cont, {:ok, [{field, casted} | sets]}}
      else
        _ -> {:halt, {:error, {:invalid, field}}}
      end
    end)
  end

  defp cast_attr(:status, value) do
    if value in Sandbox.statuses(), do: {:ok, value}, else: :error
  end

  defp cast_attr(:transition, nil), do: {:ok, nil}

  defp cast_attr(:transition, value) do
    if value in Sandbox.transitions(), do: {:ok, value}, else: :error
  end

  defp cast_attr(field, value) when field in @writable,
    do: Ecto.Type.cast(Sandbox.__schema__(:type, field), value)

  # Every key that is not a writable column, including a string one: an owner's
  # write is built in code, not forwarded from a caller's map.
  defp cast_attr(_field, _value), do: :error

  # The three things every entry point checks before it touches the database,
  # and the one it catches after.
  #
  # A database fault is an answer, not a crash: Ecto rolls the transaction back
  # on the way out — releasing the transaction-scoped advisory lock with it —
  # and the caller gets a reason rather than an exception to handle at every
  # call site (#2309's `57014` is the shape this is written for). The rescue
  # covers faults the database raises, server-side and connection alike, and
  # nothing else: a malformed `attrs` or a `sandbox_id` that is not a UUID
  # would reach Ecto as `Ecto.QueryError` or `Ecto.Query.CastError`, and those
  # are caller bugs, refused up front instead of dressed up as database faults.
  defp guarded(sandbox_id, fun), do: guarded(sandbox_id, false, fun)

  defp guarded(sandbox_id, nest?, fun) do
    cond do
      not nest? and Repo.in_transaction?() ->
        {:error, :transaction_open}

      # `is_binary/1` on the public functions admits any string; the `@spec`
      # says `Ecto.UUID.t()` and the query would raise on anything else. The
      # length test is not redundant: `Ecto.UUID.cast/1` also accepts the raw
      # 16-byte form, which is not what a `:binary_id` column is queried with
      # and which reaches Ecto as an `Ecto.Query.CastError` — the one thing
      # this check exists to prevent.
      byte_size(sandbox_id) != 36 or Ecto.UUID.cast(sandbox_id) == :error ->
        {:error, {:invalid, :sandbox_id}}

      true ->
        try do
          fun.()
        rescue
          error in [Postgrex.Error, DBConnection.ConnectionError] ->
            {:error, {:database, sqlstate(error)}}
        end
    end
  end

  defp sqlstate(%Postgrex.Error{postgres: %{code: code}}), do: code
  defp sqlstate(%DBConnection.ConnectionError{}), do: :connection_error
  defp sqlstate(_error), do: :unknown
end
