defmodule Fountain.Machines.BootSweep do
  @moduledoc """
  Clears the machine leases and abandoned operation stamps an earlier boot
  left behind (`Fountain.Machines.Lease.sweep_boot/0`, ADR 0072).

  A child of `Fountain.Application`, straight after the migrator, so it runs
  once the schema is current and before Oban, the endpoint or the rehydrator
  can claim anything. It does its work in `start_link/1` and returns
  `:ignore`, so the supervisor waits for it and keeps no process.

  A failure is logged, not raised: every lease of an earlier boot already reads
  as dead (`Lease.live?/1`), so what the sweep adds is tidiness — no stale
  holder on the admin table, no stale `parking` stamp for the next owner to
  take over — and a database hiccup at boot must not stop the node starting.

  `config :fountain, :machine_boot_sweep, false` turns it off; the test suite
  does, and calls `Lease.sweep_boot/0` itself.
  """

  require Logger

  @doc false
  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, restart: :temporary}
  end

  @doc false
  def start_link(_opts) do
    if Application.get_env(:fountain, :machine_boot_sweep, true), do: sweep()
    :ignore
  end

  defp sweep do
    _ = Fountain.Machines.Lease.sweep_boot()
  rescue
    error ->
      Logger.error("machine boot sweep failed: #{Exception.message(error)}")
  end
end
