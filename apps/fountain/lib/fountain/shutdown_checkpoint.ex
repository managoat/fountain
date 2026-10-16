defmodule Fountain.ShutdownCheckpoint do
  @moduledoc """
  Marks supervision-tree shutdown boundaries without delaying teardown.
  Children stop in reverse order; a checkpoint logs after the children above
  it have stopped. Compare these timestamps with ingress probes and pod events.
  """
  use GenServer
  require Logger

  def child_spec(phase), do: %{id: {__MODULE__, phase}, start: {__MODULE__, :start_link, [phase]}}
  def start_link(phase), do: GenServer.start_link(__MODULE__, phase)

  @impl true
  def init(phase) do
    Process.flag(:trap_exit, true)
    {:ok, phase}
  end

  @impl true
  def terminate(_reason, phase) do
    Logger.info(
      "rollout shutdown phase=#{phase} monotonic_ms=#{System.monotonic_time(:millisecond)}"
    )
  end
end
