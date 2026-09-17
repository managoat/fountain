defmodule Fountain.Machines.Renewal do
  @moduledoc """
  Keeping a machine's lease alive across a provider call (ADR 0058, stage 7a).

  A lease bounds one operation, and until this module existed it bounded it by
  *starting time*: `Fountain.Machines.Lease.claim/4` wrote a deadline
  `lease_ttl_ms` into the future and nothing moved it, so an operation slower
  than its own TTL outlived its lease. The compare-and-set made that safe — a
  superseded finalize writes no row — but safe by throwing the work away, and
  the 6b review found the shape that costs something: a home checkpoint with
  `Managoat.Sandbox.Retry`'s backoff behind it, followed by a suspend, can run
  past two minutes; the lease lapses; a reaper takes the row over and clears the
  transition while the suspend is still in flight; and the machine ends up
  genuinely suspended behind a row that says `ready`, with no usage row and no
  audit event, until some later pass notices.

  So a lease now bounds an operation that is *making progress*. The protocol
  wraps its provider call in `around/4`, which renews at a third of the TTL from
  a process of its own, and answers whether the lease survived.

  ## Why a process and not a timer

  The obvious implementation is `Process.send_after/3` in the operating process.
  It cannot work: that process is blocked inside a synchronous provider call for
  the whole window the renewal is for, so the message sits unread in exactly the
  interval it was meant to cover. The renewal therefore has to run somewhere
  else.

  It is deliberately **not** linked, and it sends the owner nothing. A link
  would let a renewer that met a database fault take a `ConversationServer`, an
  Oban worker or a `Machines.Machine` down mid-operation; a message would reach
  a `GenServer`'s `handle_info/2`, which for `Machines.Machine` has clauses for
  its idle timer and nothing else. The verdict is *pulled* instead, at
  `stop/1`, once the provider call has returned and the caller can ask.

  `$callers` is copied into the renewer so it resolves the same database
  connection ownership as its parent — which is what a test's SQL sandbox needs
  and what production ignores.

  ## What a lost lease means, and what a dead renewer does not

  `Lease.renew/4` answers `{:error, :lost}` for exactly one reason: this caller
  is not the holder any more. Somebody took the machine over, or the lease was
  released. Either way the work in flight is no longer this owner's to finish,
  and `around/4` answers `{:error, :superseded}` — the same word the finalize's
  own compare-and-set would have produced, reached one round trip earlier and
  before a second provider call.

  Anything else — a connection blip, a `{:database, sqlstate}` out of
  `Lease.guarded/2` — is **not** a takeover and is retried on the next tick. A
  renewer that cannot renew at all eventually lets the lease lapse, and that is
  the pre-7a behaviour, with the compare-and-set as the backstop it always was.

  A renewer that *dies* reports `:held` for the same reason: it has no evidence
  of a takeover, and the finalize's compare-and-set is what decides. This module
  can only ever turn a failure that would have been discovered at the finalize
  into one discovered before it; it is not itself a safety property, and a
  reviewer should not read it as one.
  """

  alias Fountain.Machines.Lease

  require Logger

  # A third of the TTL: two renewals may be missed — a database blip, a long
  # GC pause — before the lease anybody else can see has expired. A half would
  # tolerate none, and a tenth would spend ten writes a minute on a machine
  # doing one provider call.
  @renew_divisor 3

  # How long `stop/1` waits for the renewer's answer. It is a `receive` in a
  # process that is either idle or inside one short `update_all`, so this is a
  # ceiling on a pathology, not a bound anybody reaches.
  @stop_timeout_ms 5_000

  @typedoc "Whether the lease was still this owner's when the work finished."
  @type verdict :: :held | :lost

  @doc """
  Run `fun` with the lease on `sandbox_id` at `epoch` renewed underneath it.

  Answers `{:ok, result}` when the lease was still held throughout, and
  `{:error, :superseded}` when a renewal found it was not — in which case
  `fun`'s result is discarded, because it belongs to an operation another owner
  has taken over.

  `fun` is run in the calling process, not the renewer: it is the provider call
  the protocol is here to make, and moving it would move the protocol.
  """
  @spec around(Ecto.UUID.t(), Lease.epoch(), pos_integer(), (-> result)) ::
          {:ok, result} | {:error, :superseded}
        when result: term()
  def around(sandbox_id, epoch, ttl_ms, fun)
      when is_binary(sandbox_id) and is_integer(epoch) and is_integer(ttl_ms) and ttl_ms > 0 and
             is_function(fun, 0) do
    renewer = start(sandbox_id, epoch, ttl_ms)

    try do
      fun.()
    catch
      # Every protocol here rescues its own adapter, so this is the throw or
      # exit nobody expected. Stop the renewer before it goes past — a renewer
      # left running holds a connection and keeps re-arming a lease on work
      # nothing is doing — and let the original reason out unchanged.
      kind, reason ->
        _ = stop(renewer)
        :erlang.raise(kind, reason, __STACKTRACE__)
    else
      result ->
        case stop(renewer) do
          :held ->
            {:ok, result}

          :lost ->
            Logger.warning(
              "machine #{sandbox_id}: the lease at epoch #{epoch} was taken over while the " <>
                "provider call was in flight; discarding the result"
            )

            {:error, :superseded}
        end
    end
  end

  @doc """
  Start renewing, and return the renewer.

  `around/4` is the door; this and `stop/1` are public for the tests that drive
  a renewal without a provider call in the middle of it.
  """
  @spec start(Ecto.UUID.t(), Lease.epoch(), pos_integer()) :: pid()
  def start(sandbox_id, epoch, ttl_ms) do
    callers = [self() | Process.get(:"$callers", [])]
    interval = max(div(ttl_ms, @renew_divisor), 1)

    spawn(fn ->
      Process.put(:"$callers", callers)
      loop(sandbox_id, epoch, ttl_ms, interval, :held)
    end)
  end

  @doc "Stop renewing and collect the verdict. See the moduledoc on a dead renewer."
  @spec stop(pid()) :: verdict()
  def stop(renewer) when is_pid(renewer) do
    ref = Process.monitor(renewer)
    send(renewer, {:stop, self(), ref})

    receive do
      {:renewal, ^ref, verdict} ->
        Process.demonitor(ref, [:flush])
        verdict

      {:DOWN, ^ref, :process, ^renewer, reason} ->
        Logger.warning("machine lease renewer exited before it was stopped: #{inspect(reason)}")
        :held
    after
      @stop_timeout_ms ->
        Process.demonitor(ref, [:flush])
        Process.exit(renewer, :kill)
        Logger.warning("machine lease renewer did not answer in #{@stop_timeout_ms}ms")
        :held
    end
  end

  # One loop, carrying the verdict so far. A lost lease stops the renewals and
  # keeps the process alive to answer: the caller is still inside its provider
  # call and has nowhere to receive an unsolicited message.
  defp loop(sandbox_id, epoch, ttl_ms, interval, verdict) do
    receive do
      {:stop, from, ref} ->
        send(from, {:renewal, ref, verdict})
    after
      interval ->
        case renew(sandbox_id, epoch, ttl_ms, verdict) do
          :held -> loop(sandbox_id, epoch, ttl_ms, interval, :held)
          :lost -> await_stop(:lost)
        end
    end
  end

  defp renew(_sandbox_id, _epoch, _ttl_ms, :lost), do: :lost

  defp renew(sandbox_id, epoch, ttl_ms, :held) do
    case Lease.renew(sandbox_id, epoch, ttl_ms) do
      :ok ->
        :held

      {:error, :lost} ->
        :lost

      # Not a takeover: a fault between this process and the database says
      # nothing about who holds the machine. Keep trying; if it never clears,
      # the lease lapses on its own and the finalize's compare-and-set is what
      # it always was.
      {:error, reason} ->
        Logger.warning(
          "machine #{sandbox_id}: could not renew the lease at epoch #{epoch} " <>
            "(#{inspect(reason)}); retrying"
        )

        :held
    end
  end

  defp await_stop(verdict) do
    receive do
      {:stop, from, ref} -> send(from, {:renewal, ref, verdict})
    end
  end
end
