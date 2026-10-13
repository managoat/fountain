defmodule Fountain.Drain do
  @moduledoc """
  Tells the cluster this node is shutting down, so no new conversation or
  machine owner is placed on it.

  A rolling deploy sends SIGTERM to a pod and then stops its children in
  reverse order. The endpoint goes first and can take a long time to drain
  its streaming connections, and until `Fountain.ConversationSupervisor`
  itself stops, Horde still counts the node as a member and starts children
  on it. On 2026-10-07 a pod started a turn 42 s after its SIGTERM and died 3
  s later, before the prompt reached the agent.

  This process is the last child of the application, so it is the first to
  stop. Its `terminate/2` writes `{:draining, node()}` into
  `Fountain.ConversationRegistry`'s replicated metadata, and
  `Fountain.Drain.Distribution` leaves every node marked that way out when
  Horde places a child. A booting node clears its own mark first: pod
  addresses, and so node names, are reused.

  Children already running on the node are untouched here. They stop with
  their supervisor, and Horde places them again through the same strategy,
  on a node that is not draining.
  """
  use GenServer

  require Logger

  @registry Fountain.ConversationRegistry

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Whether `node` has said it is shutting down."
  @spec draining?(node()) :: boolean()
  def draining?(node) do
    match?({:ok, true}, Horde.Registry.meta(@registry, {:draining, node}))
  rescue
    # The registry is not up yet (`Fountain.MachineSupervisor` starts first)
    # or is already gone: nothing is known to be draining.
    _ -> false
  catch
    :exit, _ -> false
  end

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)
    mark(false)
    {:ok, nil}
  end

  @impl true
  def terminate(_reason, _state) do
    Logger.info("drain: #{node()} is shutting down; no new conversations will be placed here")
    mark(true)
  end

  defp mark(draining?) do
    if draining?,
      do: Horde.Registry.put_meta(@registry, {:draining, node()}, true),
      else: Horde.Registry.delete_meta(@registry, {:draining, node()})

    :ok
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end
end

defmodule Fountain.Drain.Distribution do
  @moduledoc """
  `Horde.UniformDistribution` over the members whose node is not draining
  (`Fountain.Drain`). When every member is draining, it chooses among all of
  them: a child placed on a dying node is restarted elsewhere, and refusing
  to place it at all would be worse.
  """
  @behaviour Horde.DistributionStrategy

  @impl true
  def choose_node(child_spec, members) do
    members
    |> Enum.reject(fn %{name: {_name, node}} -> Fountain.Drain.draining?(node) end)
    |> case do
      [] -> Horde.UniformDistribution.choose_node(child_spec, members)
      live -> Horde.UniformDistribution.choose_node(child_spec, live)
    end
  end

  @impl true
  def has_quorum?(members), do: Horde.UniformDistribution.has_quorum?(members)
end
