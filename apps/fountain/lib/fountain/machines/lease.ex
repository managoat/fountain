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

  Takeover is by expiry and nothing else. A TTL on its own is not a hand-over:
  `take_over/4` still serializes on the sandbox lock, still re-reads the row
  `FOR UPDATE`, and still refuses while `lease_until` is in the future. A lease
  is surrendered early only by `release/2`, and even that keeps the epoch.

  The clock is the claiming node's, not the database's: `lease_until` is
  written from one BEAM node's `DateTime.utc_now()` and compared against
  another's. Skew is not a correctness hole — early takeover is what the
  compare-and-set already makes safe, and late takeover only delays recovery —
  but it is N clocks rather than one. Moving to `fragment("now()")` is a
  decision for the process that owns the renew timer (stage 7), not for this
  module, which has no timer of its own.

  Every function here is one short statement or transaction, and refuses to run
  inside an enclosing one (`{:error, :transaction_open}`), the same guard
  `Fountain.Conversations.Lifecycle.fence_sandbox_for_teardown/2` and
  `Fountain.Conversations.SandboxIdentity` use. Nesting would join the caller's
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

  `Fountain.Machines.Destroy` is the only caller of the write half, since stage
  5a: it claims a lease around one destroy, stamps the transition and finalizes
  with `cas_update/3`, and releases.

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
  they never write one. `park` and `ensure_up` bring the standing lease and the
  renew timer in stages 6b and 7.
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

  # The only columns a machine's owner may write through `cas_update/3`.
  # `lease_*` are absent on purpose — a lease changes hands through the
  # functions below, under the lock, and never as a side effect of a state
  # write.
  @writable ~w(status transition transition_reason terminated_at last_resumed_at)a

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

  **The clock is the caller's `now`, a BEAM node's.** That is the clock
  `claim/4` writes `lease_until` with, so comparing against another node's is
  the skew this module's moduledoc already accounts for: early is safe because
  of the compare-and-set, late only delays recovery. Passing `now` in rather
  than taking it here is what lets a sweep judge every row in one pass against
  one instant. Moving the whole module to `fragment("now()")` belongs with the
  renew timer (stage 7), not here.
  """
  @spec live?(Sandbox.t() | map(), DateTime.t()) :: boolean()
  def live?(sandbox, now \\ DateTime.utc_now())

  def live?(%{lease_node: node, lease_until: until}, now)
      when is_binary(node) and not is_nil(until),
      do: DateTime.compare(until, now) == :gt

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
  Take the lease on `sandbox_id` for `node`, for `ttl_ms` from `now`.

  Serializes on the per-sandbox advisory lock, re-reads the row `FOR UPDATE`,
  and refuses with `{:error, {:held, node, until}}` when the current lease has
  not expired. The verdict is made on the locked read, never on a struct the
  caller brought: a pre-lock reading is stale by construction.

  On success the epoch advances by exactly one and is returned. The holder
  quotes it on every subsequent write.
  """
  @spec claim(Ecto.UUID.t(), String.t(), pos_integer(), DateTime.t()) ::
          {:ok, epoch()}
          | {:error,
             :not_found | :lost | :transaction_open | {:invalid, :sandbox_id} | held() | term()}
  def claim(sandbox_id, node, ttl_ms, now \\ DateTime.utc_now())
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
  @spec take_over(Ecto.UUID.t(), String.t(), pos_integer(), DateTime.t()) ::
          {:ok, epoch()}
          | {:error,
             :not_found | :lost | :transaction_open | {:invalid, :sandbox_id} | held() | term()}
  def take_over(sandbox_id, node, ttl_ms, now \\ DateTime.utc_now())
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
  """
  @spec renew(Ecto.UUID.t(), epoch(), pos_integer(), DateTime.t()) ::
          :ok | {:error, :lost | :transaction_open | {:invalid, :sandbox_id} | term()}
  def renew(sandbox_id, epoch, ttl_ms, now \\ DateTime.utc_now())
      when is_binary(sandbox_id) and is_integer(epoch) and is_integer(ttl_ms) and ttl_ms > 0 do
    guarded(sandbox_id, fn ->
      if taken_epoch?(epoch) do
        until = DateTime.add(now, ttl_ms, :millisecond)

        case Repo.update_all(held_by(sandbox_id, epoch), set: [lease_until: until]) do
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

  A write that moves the status to `terminated` or `failed` stamps
  `terminated_at` when the row has none, mirroring
  `Conversations.stamp_terminated_at/1` — see `stamp_terminated_at/2` below for
  why that matters and where it is deliberately narrower.

  Deliberately takes no advisory lock: a single guarded `update_all` is already
  atomic, and the serialization this needs was done when the epoch was taken.

  It does not consult `lease_until`, and that is the contract, not an
  omission: an expired lease nobody has taken over is still held by its owner,
  and that owner finishing the work it started is what should happen. What the
  CAS buys is that the moment a takeover has happened, the old holder's write
  is invisible — the ADR's answer to a partitioned node completing a provider
  call. Nothing here refuses a write for a lapsed clock alone — `renew/4` does
  not either — so a holder that wants to stop early keeps that deadline itself.
  """
  @spec cas_update(Ecto.UUID.t(), epoch(), map() | keyword()) ::
          {:ok, Sandbox.t()}
          | {:error, :stale | :retired | :transaction_open | {:invalid, atom()} | term()}
  def cas_update(sandbox_id, epoch, attrs) when is_binary(sandbox_id) and is_integer(epoch) do
    guarded(sandbox_id, fn ->
      if taken_epoch?(epoch) do
        with {:ok, sets} <- cast_attrs(attrs) do
          # `updated_at` moves with a state change but not with a renewal: a
          # lease heartbeat every few seconds would otherwise make the column
          # mean nothing to anyone reading the table.
          sets = Keyword.put(sets, :updated_at, DateTime.utc_now() |> DateTime.truncate(:second))

          query =
            sandbox_id
            |> held_by(epoch)
            |> refuse_revival(sets)
            |> stamp_terminated_at(sets)
            |> select([s], s)

          case Repo.update_all(query, set: sets) do
            {1, [sandbox]} -> {:ok, sandbox}
            {0, _} -> {:error, zero_row_reason(sandbox_id, epoch)}
          end
        end
      else
        {:error, :stale}
      end
    end)
  end

  defp do_claim(kind, sandbox_id, node, ttl_ms, now) do
    Conversations.with_sandbox_lock(sandbox_id, fn ->
      current =
        Repo.one(
          from s in Sandbox,
            where: s.id == ^sandbox_id,
            select: %{
              epoch: s.lease_epoch,
              lease_node: s.lease_node,
              lease_until: s.lease_until
            },
            lock: "FOR UPDATE"
        )

      cond do
        is_nil(current) ->
          {:error, :not_found}

        live?(current, now) ->
          {:error, {:held, current.lease_node, current.lease_until}}

        true ->
          epoch = current.epoch + 1
          until = DateTime.add(now, ttl_ms, :millisecond)

          # The one place a bare `(id, lease_epoch)` predicate is right: the
          # row is unheld by definition — that is what is being claimed — and
          # the advisory lock plus this `FOR UPDATE` already decided who wins,
          # so `held_by/2`'s holder columns would refuse every first claim.
          # Guarded on the epoch the locked read saw all the same, because
          # answering `:lost` beats a `MatchError` unwinding out of the
          # transaction (#2329).
          case Repo.update_all(
                 from(s in Sandbox,
                   where: s.id == ^sandbox_id and s.lease_epoch == ^current.epoch
                 ),
                 set: [lease_epoch: epoch, lease_node: node, lease_until: until]
               ) do
            {1, _} ->
              log_claim(kind, sandbox_id, node, epoch, current)
              {:ok, epoch}

            {0, _} ->
              {:error, :lost}
          end
      end
    end)
  end

  defp log_claim(:take_over, sandbox_id, node, epoch, %{lease_node: previous}) do
    Logger.info(
      "machine lease taken over on sandbox #{sandbox_id} by #{node} at epoch #{epoch}; " <>
        "previous holder #{previous || "none"} had expired"
    )
  end

  defp log_claim(:claim, _sandbox_id, _node, _epoch, _current), do: :ok

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

  # Only on the refusal path, so the write itself stays one statement. Without
  # it a revival and a takeover are the same zero rows, and an owner told
  # `:stale` would go looking for a successor that never existed.
  defp zero_row_reason(sandbox_id, epoch) do
    case Repo.one(from s in held_by(sandbox_id, epoch), select: s.status) do
      status when status in @terminal_statuses -> :retired
      _ -> :stale
    end
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
  defp guarded(sandbox_id, fun) do
    cond do
      Repo.in_transaction?() ->
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
