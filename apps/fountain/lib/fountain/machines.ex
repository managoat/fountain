defmodule Fountain.Machines do
  @moduledoc """
  The machine — a sandbox with one owner (ADR 0058).

  A sandbox gets one `Fountain.Machines.Machine` process, registered in
  `Fountain.MachineRegistry` under the sandbox id, which will become the only
  writer of `sandboxes.status` and the only caller of the provider's create,
  resume, suspend, destroy and checkpoint. It is being built in stages behind
  `MACHINE_OWNER_ENABLED`. It answers one read-only question,
  `Machine.who_is_here/1`, and owns six protocols: `Fountain.Machines.Destroy`
  (stage 5), `Park` (6b), `Resume` (7a), `Provision` (7b), `Admission` (8a)
  and `Binding` (8b) — attach, detach, retarget and the Codex auth binding.

  The gate chooses *where* a verb runs — inside the owner process, or inline
  on the caller — and nothing else. The protocol, the fence it writes, the
  lease it takes and the event it records are the same on both sides, so
  every existing fence stays in force with the flag off and a mixed-version
  fleet stays safe with it on.
  """

  @doc """
  Whether this deployment runs the per-sandbox owner (`MACHINE_OWNER_ENABLED`).

  Default false. `config/runtime.exs` reads the variable once at boot; this is
  the one reader of the key, so a caller never has to know the default twice.
  """
  @spec enabled?() :: boolean()
  def enabled?, do: Application.get_env(:fountain, :machine_owner_enabled, false)
end
