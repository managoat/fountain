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

  Takeover is by expiry and nothing else. A TTL on its own is not a hand-over:
  `take_over/4` still serializes on the sandbox lock, still re-reads the row
  `FOR UPDATE`, and still refuses while `lease_until` is in the future. A lease
  is surrendered early only by `release/2`, and even that keeps the epoch.

  Every function here is one short transaction and refuses to run inside an
  enclosing one (`{:error, :transaction_open}`), the same guard
  `Fountain.Conversations.Lifecycle.fence_sandbox_for_teardown/2` and
  `Fountain.Conversations.SandboxIdentity` use. Nesting would join the caller's
  transaction through a savepoint and hold a transaction-scoped advisory lock
  until the outer commit, which is exactly the "short transaction" this module
  promises not to be. Provider I/O happens in the owner, between these calls,
  never inside one.

  Nothing user-facing happens here, so nothing here is audited: a lease is
  control-plane bookkeeping, and the events an operation owes — `sandbox.destroyed`
  and its siblings — are recorded by the owner's verbs in later stages.

  Nothing calls this module yet. `Fountain.Machines.Machine` (stage 4 onward)
  is its only intended caller.
  """

  import Ecto.Query

  alias Fountain.Conversations
  alias Fountain.Conversations.Sandbox
  alias Fountain.Repo

  require Logger

  @typedoc "A lease generation. Monotonic per sandbox; never reused."
  @type epoch :: non_neg_integer()

  @typedoc "Why a claim was refused: someone else holds a lease that has not expired."
  @type held :: {:held, String.t() | nil, DateTime.t()}

  # The only columns a machine's owner may write through `cas_update/3`.
  # `lease_*` are absent on purpose — a lease changes hands through the
  # functions below, under the lock, and never as a side effect of a state
  # write.
  @writable ~w(status transition transition_reason terminated_at last_resumed_at)a

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
          {:ok, epoch()} | {:error, :not_found | :lost | :transaction_open | held() | term()}
  def claim(sandbox_id, node, ttl_ms, now \\ DateTime.utc_now())
      when is_binary(sandbox_id) and is_binary(node) and is_integer(ttl_ms) and ttl_ms > 0 do
    guarded(fn -> do_claim(:claim, sandbox_id, node, ttl_ms, now) end)
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
          {:ok, epoch()} | {:error, :not_found | :lost | :transaction_open | held() | term()}
  def take_over(sandbox_id, node, ttl_ms, now \\ DateTime.utc_now())
      when is_binary(sandbox_id) and is_binary(node) and is_integer(ttl_ms) and ttl_ms > 0 do
    guarded(fn -> do_claim(:take_over, sandbox_id, node, ttl_ms, now) end)
  end

  @doc """
  Extend the lease held at `epoch` to `ttl_ms` past `now`.

  One `update_all` guarded by the epoch — no lock and no read, because the
  epoch *is* the check. Zero rows means the lease was taken over or the row is
  gone; either way this holder no longer owns the machine and must stop.
  """
  @spec renew(Ecto.UUID.t(), epoch(), pos_integer(), DateTime.t()) ::
          :ok | {:error, :lost | :transaction_open | term()}
  def renew(sandbox_id, epoch, ttl_ms, now \\ DateTime.utc_now())
      when is_binary(sandbox_id) and is_integer(epoch) and is_integer(ttl_ms) and ttl_ms > 0 do
    guarded(fn ->
      until = DateTime.add(now, ttl_ms, :millisecond)

      case Repo.update_all(held_by(sandbox_id, epoch), set: [lease_until: until]) do
        {1, _} -> :ok
        {0, _} -> {:error, :lost}
      end
    end)
  end

  @doc """
  Give the lease up.

  Clears `lease_node` and `lease_until` and keeps `lease_epoch` where it is:
  epochs are monotonic and never reused, so the next claimant still gets a
  strictly higher one and this holder's outstanding writes still fail. Zero
  rows means the lease had already moved on.
  """
  @spec release(Ecto.UUID.t(), epoch()) :: :ok | {:error, :lost | :transaction_open | term()}
  def release(sandbox_id, epoch) when is_binary(sandbox_id) and is_integer(epoch) do
    guarded(fn ->
      case Repo.update_all(held_by(sandbox_id, epoch), set: [lease_node: nil, lease_until: nil]) do
        {1, _} -> :ok
        {0, _} -> {:error, :lost}
      end
    end)
  end

  @doc """
  Write machine state, if and only if `epoch` is still the lease.

  The one write primitive the owner uses. One `update_all` matching on
  `(id, lease_epoch)`, returning the row it wrote; zero rows is `:stale`, which
  is the whole protocol in one word — a superseded owner changes nothing and
  learns so.

  `attrs` may name only #{inspect(@writable)}, with atom keys. `status` is
  checked against `Sandbox.statuses/0` and `transition` against
  `Sandbox.transitions/0` (`nil` clears it, which is how a transition
  finalizes) before anything is written; anything else is
  `{:error, {:invalid, field}}` and the row is untouched.

  Deliberately takes no advisory lock: a single guarded `update_all` is already
  atomic, and the serialization this needs was done when the epoch was taken.

  It does not consult `lease_until` either, and that is the contract, not an
  omission: an expired lease nobody has taken over is still the current epoch,
  and the holder finishing the work it started is what should happen. What the
  CAS buys is that the moment a takeover has happened, the old holder's write
  is invisible — which is the ADR's answer to a partitioned node completing a
  provider call. Nothing here refuses a write for a lapsed clock alone —
  `renew/4` does not either, since it too answers on the epoch — so a holder
  that wants to stop early keeps that deadline itself.
  """
  @spec cas_update(Ecto.UUID.t(), epoch(), map() | keyword()) ::
          {:ok, Sandbox.t()} | {:error, :stale | :transaction_open | {:invalid, atom()} | term()}
  def cas_update(sandbox_id, epoch, attrs) when is_binary(sandbox_id) and is_integer(epoch) do
    guarded(fn ->
      with {:ok, sets} <- cast_attrs(attrs) do
        # `updated_at` moves with a state change but not with a renewal: a
        # lease heartbeat every few seconds would otherwise make the column
        # mean nothing to anyone reading the table.
        sets = Keyword.put(sets, :updated_at, DateTime.utc_now() |> DateTime.truncate(:second))

        case Repo.update_all(select(held_by(sandbox_id, epoch), [s], s), set: sets) do
          {1, [sandbox]} -> {:ok, sandbox}
          {0, _} -> {:error, :stale}
        end
      end
    end)
  end

  defp do_claim(kind, sandbox_id, node, ttl_ms, now) do
    Conversations.with_sandbox_lock(sandbox_id, fn ->
      current =
        Repo.one(
          from s in Sandbox,
            where: s.id == ^sandbox_id,
            select: %{epoch: s.lease_epoch, node: s.lease_node, until: s.lease_until},
            lock: "FOR UPDATE"
        )

      cond do
        is_nil(current) ->
          {:error, :not_found}

        live?(current.until, now) ->
          {:error, {:held, current.node, current.until}}

        true ->
          epoch = current.epoch + 1
          until = DateTime.add(now, ttl_ms, :millisecond)

          # Guarded by the epoch the locked read saw, not just the id. The row
          # is held `FOR UPDATE`, so this cannot lose — and if it ever did,
          # answering `:lost` is better than a `MatchError` unwinding through
          # the transaction (#2329).
          case Repo.update_all(held_by(sandbox_id, current.epoch),
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

  # An absent or past `lease_until` is an expired lease and the only thing
  # takeover ever waits for.
  defp live?(nil, _now), do: false
  defp live?(until, now), do: DateTime.compare(until, now) == :gt

  defp log_claim(:take_over, sandbox_id, node, epoch, %{node: previous}) do
    Logger.info(
      "machine lease taken over on sandbox #{sandbox_id} by #{node} at epoch #{epoch}; " <>
        "previous holder #{previous || "none"} had expired"
    )
  end

  defp log_claim(:claim, _sandbox_id, _node, _epoch, _current), do: :ok

  defp held_by(sandbox_id, epoch),
    do: from(s in Sandbox, where: s.id == ^sandbox_id and s.lease_epoch == ^epoch)

  defp cast_attrs(attrs) when attrs == %{} or attrs == [], do: {:error, {:invalid, :attrs}}

  defp cast_attrs(attrs) do
    Enum.reduce_while(attrs, {:ok, []}, fn {field, value}, {:ok, sets} ->
      case cast_attr(field, value) do
        {:ok, casted} -> {:cont, {:ok, [{field, casted} | sets]}}
        :error -> {:halt, {:error, {:invalid, field}}}
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

  # A database fault is an answer, not a crash. Ecto rolls the transaction back
  # on the way out — releasing the transaction-scoped advisory lock with it —
  # and the caller gets the SQLSTATE rather than an exception to handle at
  # every call site (#2309's `57014` is the shape this is written for).
  defp guarded(fun) do
    if Repo.in_transaction?() do
      {:error, :transaction_open}
    else
      try do
        fun.()
      rescue
        error in Postgrex.Error -> {:error, {:database, sqlstate(error)}}
      end
    end
  end

  defp sqlstate(%Postgrex.Error{postgres: %{code: code}}), do: code
  defp sqlstate(_error), do: :unknown
end
