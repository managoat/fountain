defmodule Fountain.Machines.Machine do
  @moduledoc """
  The owner of one machine (ADR 0058) — **read-only for now**.

  One process per *active* sandbox, registered in `Fountain.MachineRegistry`
  under the sandbox id and supervised by `Fountain.MachineSupervisor`, both
  Horde members so the owner is addressable from any node. It idle-stops after
  a minute with nothing asked of it, and `ensure_started/1` brings it back:
  there is a process per active machine, not one per row.

  Today it answers one verb, `who_is_here/1`, which returns the
  `Fountain.Machines.Occupancy` struct. It holds no state beyond the sandbox
  id and its idle timer, it does not claim the lease
  (`Fountain.Machines.Lease`, stage 3), and it writes nothing — not the row,
  not the provider, not an audit event. The lease, the transition column and
  the verbs that need them (`destroy`, `park`, `ensure_up`, `attach`,
  `admit_turn`) arrive in stages 5 to 8.

  Asking through a process for an answer available from a pure function looks
  like ceremony, and it is the point: `who_is_here/1` is the door every writer
  will come through once the writes move here, so the callers move first,
  while moving them still changes nothing. With `MACHINE_OWNER_ENABLED` off,
  `who_is_here/1` reads `Occupancy` directly and starts nothing at all, so the
  gate governs whether the process exists, never what the answer is.
  """

  # `:transient` — an idle-stop exits `:normal` and Horde leaves it stopped,
  # which is what makes this one process per *active* machine; an abnormal
  # exit is restarted, and the replacement then holds a registry slot for a
  # full idle window although nobody asked it anything. That is the right
  # trade from stage 5 on, when the owner holds a lease it must reclaim, and
  # it is merely harmless now, when it holds nothing.
  use GenServer, restart: :transient

  require Logger

  alias Fountain.Machines
  alias Fountain.Machines.Occupancy

  # Long enough that a burst of questions about one machine — a lifecycle
  # check, a reaper pass and a park decision inside the same minute — reuses
  # one process; short enough that a machine nobody has asked about leaves no
  # process behind. Overridable per process for the tests that drive it.
  @idle_ms 60_000

  # The call is one to three indexed reads. A timeout longer than the default
  # would only ever hide a repo that is already in trouble.
  @call_timeout 15_000

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

  @impl true
  def handle_info({:idle, token}, %{idle_token: token} = state) do
    # Nothing durable to release: no lease, no provider handle, no in-flight
    # write. `ensure_started/1` starts a replacement on the next question.
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
