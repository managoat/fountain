defmodule Fountain.Repo.Migrations.RetireRunnerRows do
  use Ecto.Migration

  @moduledoc """
  The self-hosted runner provider is removed (#2676; ADR 0022 and 0036
  superseded). Two kinds of row still name it, and neither can be served by a
  release with no runner adapter:

    * An agent pinned to `sandbox_provider = 'runner'` would fail every
      launch. It is moved to the instance default (NULL), which is where a
      pin to a provider the instance cannot use belongs.
    * A sandbox on a runner that is not yet terminal would be handed to the
      sandbox library, which raises on a provider it has no adapter for. It is
      marked `terminated`, ending when it was last written, and its transition
      stamp is cleared. Nothing is destroyed on the runner's machine: Fountain
      can no longer reach it, so the sandbox directories (or Firecracker VMs)
      left there are the machine owner's to delete, with the daemon stopped.
      Its conversations stay; their next prompt provisions on the instance
      default.

  Terminal runner sandboxes keep `provider = 'runner'` as history; reads
  tolerate it (`Conversations.sandbox_provider_atom/1` answers `:removed`).
  The `runners` table is left in place for one release and dropped by a
  later migration, so the previous release, serving during a rolling deploy,
  still finds the rows it reads. That release reads the rewritten rows the
  way it always did: a terminated sandbox is one it already skips, and a NULL
  `sandbox_provider` is the default it already resolves.
  """

  def up do
    execute "UPDATE agents SET sandbox_provider = NULL WHERE sandbox_provider = 'runner'"

    execute """
    UPDATE sandboxes
       SET status = 'terminated',
           terminated_at = COALESCE(terminated_at, updated_at),
           transition = NULL,
           transition_reason = NULL,
           updated_at = now()
     WHERE provider = 'runner'
       AND status NOT IN ('terminated', 'failed')
    """
  end

  # Data, not shape: which agents were pinned and which sandboxes were live is
  # not recorded, and there is no runner adapter to put them back on.
  def down, do: :ok
end
