defmodule Fountain.Machines do
  @moduledoc """
  The machine — a sandbox with one owner (ADR 0058).

  A sandbox gets one `Fountain.Machines.Machine` process, registered in
  `Fountain.MachineRegistry` under the sandbox id, which will become the only
  writer of `sandboxes.status` and the only caller of the provider's create,
  resume, suspend, destroy and checkpoint. It is being built in stages behind
  `MACHINE_OWNER_ENABLED`; today it answers one read-only question,
  `Machine.who_is_here/1`, and writes nothing.

  While the gate is off every existing fence stays in force and every caller
  takes the path it took before — `Occupancy` is reachable without the
  process, so nothing about the answer depends on the flag.
  """

  @doc """
  Whether this deployment runs the per-sandbox owner (`MACHINE_OWNER_ENABLED`).

  Default false. `config/runtime.exs` reads the variable once at boot; this is
  the one reader of the key, so a caller never has to know the default twice.
  """
  @spec enabled?() :: boolean()
  def enabled?, do: Application.get_env(:fountain, :machine_owner_enabled, false)
end
