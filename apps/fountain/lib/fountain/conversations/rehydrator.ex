defmodule Fountain.Conversations.Rehydrator do
  @moduledoc """
  On app boot, find conversations whose ConversationServer would have been
  alive at the time of a clean BEAM stop and start servers for them. Each
  server enters reattach mode: get a sprite handle without recreating,
  verify the sprite is still alive at sprites.dev, mark the sandbox failed
  if it isn't.

  Scoped to **fully-provisioned** conversations (sandbox.status == "ready"
  and conversation.status in ["idle", "running"]). Pending/starting
  sandboxes from a crashed mid-provision are left as-is — the user's next
  action lazily resolves them via `wake_conversation`.

  Saved execution allowances must be enforceable before a server is started.
  Refused rows remain unchanged; this preflight does not stop provider work
  that was already running. Turn admission still rechecks the saved policy.

  ## Clustered boot

  `run/1` fires on every node as it boots, but libcluster needs a few
  seconds (DNSPoll interval + connect) before the nodes form a cluster.
  If every node swept immediately, each would `start_child` all resumable
  conversations into its own not-yet-synced Horde registry; when the CRDT
  registries later merge they'd find duplicate names and mass-terminate the
  losers — a brief window of duplicate sprite servers and a noisy log storm.

  To avoid that we wait for cluster membership to stabilize, then let only
  the **rehydration leader** (the lowest node name in the connected set)
  run the sweep. `Horde.UniformDistribution` still spreads the started
  children across all nodes, so a single sweeper does not concentrate load.
  When clustering is disabled (single-node / no `CLUSTER_DNS_QUERY`) the
  wait and election short-circuit and the node sweeps immediately, exactly
  as before. `start_child` returning `{:already_started, _}` is treated as
  success so any residual cross-node overlap is a no-op rather than an error.
  """

  require Logger

  alias Fountain.{Agents, Conversations}
  alias Fountain.Conversations.{Launch, Sandbox}
  alias Fountain.Machines.Lease
  alias Fountain.Machines.Machine

  def run(opts \\ []) do
    if clustering_enabled?() do
      peers = await_stable_cluster(opts)

      if leader?(Node.self(), peers) do
        Logger.info("rehydrator: #{Node.self()} elected rehydration leader; sweeping")
        sweep()
      else
        Logger.info(
          "rehydrator: #{Node.self()} not leader (leader=#{leader_node(Node.self(), peers)}); skipping sweep"
        )

        {:skipped, %{leader: false, peers: peers}}
      end
    else
      sweep()
    end
  end

  # ── leader election (pure) ────────────────────────────────────────────────

  @doc "True if `self_node` is the rehydration leader for the connected set."
  def leader?(self_node, peers), do: self_node == leader_node(self_node, peers)

  @doc "The elected leader node: the lowest name across self + connected peers."
  def leader_node(self_node, peers), do: Enum.min([self_node | peers])

  # ── cluster stabilization ─────────────────────────────────────────────────

  # Poll `Node.list/0` until the connected set has been unchanged for
  # `stabilize_ms`, or `cluster_wait_ms` elapses — whichever comes first.
  # Returns the peer list to elect a leader against. A genuinely single
  # node simply observes an empty, stable set and returns after the quiet
  # period.
  defp await_stable_cluster(opts) do
    max_wait = Keyword.get(opts, :cluster_wait_ms, cfg(:rehydrate_cluster_wait_ms, 30_000))
    stabilize = Keyword.get(opts, :stabilize_ms, cfg(:rehydrate_stabilize_ms, 5_000))
    poll = Keyword.get(opts, :poll_ms, cfg(:rehydrate_poll_ms, 1_000))

    now = System.monotonic_time(:millisecond)
    loop_until_stable(MapSet.new(Node.list()), now, now + max_wait, stabilize, poll)
  end

  defp loop_until_stable(members, stable_since, deadline, stabilize, poll) do
    now = System.monotonic_time(:millisecond)
    current = MapSet.new(Node.list())
    unchanged? = MapSet.equal?(current, members)

    cond do
      now >= deadline ->
        MapSet.to_list(current)

      unchanged? and now - stable_since >= stabilize ->
        MapSet.to_list(current)

      unchanged? ->
        Process.sleep(poll)
        loop_until_stable(members, stable_since, deadline, stabilize, poll)

      true ->
        # Membership changed — restart the quiet window from now.
        Process.sleep(poll)
        loop_until_stable(current, now, deadline, stabilize, poll)
    end
  end

  defp clustering_enabled?, do: Application.get_env(:libcluster, :topologies, []) != []

  defp cfg(key, default), do: Application.get_env(:fountain, key, default)

  # ── sweep ─────────────────────────────────────────────────────────────────

  defp sweep do
    Fountain.Telemetry.span([:rehydrate], %{}, fn ->
      convs = Conversations._unsafe_list_resumable_conversations()
      Logger.info("rehydrator: scanning #{length(convs)} resumable conversation(s)")

      # One clock for the whole sweep (ADR 0058 stage 7a). `Machine.busy?/2`
      # judges against the database's, and letting it default would fetch one
      # per row on a boot sweep that reads every resumable conversation in the
      # deployment. Judging a page against one instant is also the honest
      # reading, and it is what the two reaper sweeps and the reset reconciler
      # do.
      lease_now = Lease.now()

      started =
        Enum.reduce(convs, 0, fn conv, count ->
          case spawn_server(conv, lease_now) do
            {:ok, _pid} -> count + 1
            _ -> count
          end
        end)

      Logger.info("rehydrator: ensured #{started} ConversationServer(s)")
      {started, %{candidates: length(convs), started: started}}
    end)
  end

  defp spawn_server(conv, lease_now) do
    # Ownership: internal boot sweep; each conversation supplies its own agent_id.
    with :ok <- Conversations._unsafe_check_saved_execution_allowance(conv.id),
         :ok <- check_machine_free(conv, lease_now),
         %Agents.Agent{} = _agent <-
           (conv.agent_id && Agents._unsafe_get_agent(conv.agent_id)) || {:skip, :no_agent},
         {:ok, runtime_module} <- Fountain.RuntimeDispatch.for_agent(conv) do
      conv.sandbox_id
      |> Conversations.register_server(
        Launch.child_spec(conv.id, conv.sandbox_id, runtime_module, initial_prompt: nil)
      )
      |> case do
        {:ok, pid} ->
          {:ok, pid}

        # Another node already started this server (cluster synced between
        # our list read and the start). Treat as success — it's running.
        {:error, {:already_started, pid}} ->
          {:ok, pid}

        # The door made the same refusal `check_machine_free/1` does, on the
        # row it re-read under the lock: a lease claimed in the gap between our
        # check and the registration. The same outcome as our own skip, and it
        # must say so — this `case` is the `with`'s *body*, so nothing here
        # reaches the `else` below, and before ADR 0058 stage 6a round 2 this
        # refusal left the sweep silently (round 1, locks review).
        {:error, :sandbox_unavailable} ->
          skipped(conv, {:skip, :machine_busy})

        other ->
          skipped(conv, other)
      end
    else
      outcome ->
        skipped(conv, outcome)
    end
  end

  # One logging path for every way this sweep declines a conversation, reached
  # from the `with`'s `else` and from its body alike.
  defp skipped(conv, {:skip, why}) do
    Logger.warning("rehydrator: skipping conv #{conv.id} (#{why})")
    :skipped
  end

  defp skipped(conv, {:error, reason}) do
    Logger.warning("rehydrator: skipping conv #{conv.id}: #{inspect(reason)}")
    :skipped
  end

  # `start_child` may also answer `:ignore`, which the `with` body used to
  # return untouched. Logged rather than matched on: a sweep that raises on one
  # odd row stops starting servers for the whole fleet.
  defp skipped(conv, other) do
    Logger.warning("rehydrator: skipping conv #{conv.id}: #{inspect(other)}")
    :skipped
  end

  # A machine whose owner holds a live lease is not a machine to start a server
  # on (ADR 0058 stage 6a). The sweep reads `ready` rows, and a `ready` row can
  # be one a destroy, a reset or — from stage 6b — a park is holding between
  # its intent and its finalize; the row it will write is not the row this
  # preloaded struct shows. Starting a server there gives the machine a second
  # writer during the one window the owner exists to prevent.
  #
  # A row whose lease has expired is started, stamped `transition` or not: that
  # is an owner that died, not one working, and a boot sweep that skipped it
  # would leave the conversation with no server until something else gave up on
  # the row (round 1).
  #
  # Skipping, not failing: the next boot sweep or the conversation's own next
  # prompt comes back, and by then the operation has finished or its lease has
  # expired. `{:skip, _}` is the sweep's own "not now" shape.
  defp check_machine_free(%{sandbox: %Sandbox{} = sandbox}, lease_now) do
    if Machine.busy?(sandbox, lease_now), do: {:skip, :machine_busy}, else: :ok
  end

  # `_unsafe_list_resumable_conversations/0` joins the sandbox and preloads it,
  # so the clause above is the one that runs. A conversation without one has no
  # machine to be busy.
  defp check_machine_free(_conv, _lease_now), do: :ok
end
