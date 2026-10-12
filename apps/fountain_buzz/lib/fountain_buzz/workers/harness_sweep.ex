defmodule FountainBuzz.Workers.HarnessSweep do
  @moduledoc """
  Starts the harness of every enabled hosted Buzz agent that is not running
  (#1017).

  A `Identity` is not a row. Each enabled one is a supervised `buzz-acp`
  **OS process** on Fountain's own pods (`FountainBuzz.Harness`, ADR 0020),
  holding an Erlang port, a live relay connection and a long-lived API key.
  `FountainBuzz.BootSweep` stands every one up when a node boots; this sweep
  is the self-healing path between boots, for a harness that lost a race or
  died on a drained node.

  Setting `enabled: false` is the tenant's own lever and this worker never
  touches it, nor starts a disabled identity.
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 3

  require Logger

  alias FountainBuzz, as: Buzz
  alias FountainBuzz.{BootSweep, Manager}

  @impl Oban.Worker
  def perform(_job) do
    %{started: started} = run()

    Logger.info("buzz harness sweep: started=#{started}")

    :telemetry.execute([:fountain, :buzz_harness_sweep, :run], %{started: started}, %{})

    :ok
  end

  @doc """
  Start every enabled identity's harness that is not running.

  Returns `%{started: n}`. A no-op unless a `buzz-acp` binary is configured —
  with none there is no harness to start, and `BootSweep.enabled?/0` is the
  same question this asks.
  """
  @spec run() :: %{started: non_neg_integer()}
  def run do
    if BootSweep.enabled?() do
      # ownership: a system-level sweep across all tenants, like the boot
      # sweep and the sandbox reaper. Each identity's own user_id scopes the
      # mint that `start_harness/2` performs downstream.
      started =
        Buzz._unsafe_list_enabled_identities()
        |> Enum.reject(&Manager.running?(&1.id))
        |> Enum.count(&start/1)

      %{started: started}
    else
      %{started: 0}
    end
  end

  defp start(identity) do
    case Manager.start_harness(identity) do
      {:ok, _pid} ->
        true

      {:error, reason} ->
        Logger.warning("buzz harness sweep: could not start #{identity.id}: #{inspect(reason)}")
        false
    end
  end
end
