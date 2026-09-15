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
  alias Fountain.Conversations.Launch

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

      started =
        Enum.reduce(convs, 0, fn conv, count ->
          case spawn_server(conv) do
            {:ok, _pid} -> count + 1
            _ -> count
          end
        end)

      Logger.info("rehydrator: ensured #{started} ConversationServer(s)")
      {started, %{candidates: length(convs), started: started}}
    end)
  end

  defp spawn_server(conv) do
    # Ownership: internal boot sweep; each conversation supplies its own agent_id.
    with :ok <- Conversations._unsafe_check_saved_execution_allowance(conv.id),
         %Agents.Agent{} = _agent <-
           (conv.agent_id && Agents._unsafe_get_agent(conv.agent_id)) || {:skip, :no_agent},
         {:ok, runtime_module} <- Fountain.RuntimeDispatch.for_agent(conv) do
      Fountain.ConversationSupervisor
      |> Horde.DynamicSupervisor.start_child(
        Launch.child_spec(conv.id, conv.sandbox_id, runtime_module, initial_prompt: nil)
      )
      |> case do
        {:ok, pid} ->
          {:ok, pid}

        # Another node already started this server (cluster synced between
        # our list read and the start). Treat as success — it's running.
        {:error, {:already_started, pid}} ->
          {:ok, pid}

        other ->
          other
      end
    else
      {:skip, why} ->
        Logger.warning("rehydrator: skipping conv #{conv.id} (#{why})")
        :skipped

      {:error, reason} ->
        Logger.warning("rehydrator: skipping conv #{conv.id}: #{inspect(reason)}")
        :skipped
    end
  end
end
