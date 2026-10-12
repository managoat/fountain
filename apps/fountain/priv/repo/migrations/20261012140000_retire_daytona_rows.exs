defmodule Fountain.Repo.Migrations.RetireDaytonaRows do
  use Ecto.Migration

  @moduledoc """
  The Daytona sandbox provider is removed (simplify 2/5). Two kinds of row
  still name it, and neither can be served by a release with no Daytona
  adapter:

    * An agent pinned to `sandbox_provider = 'daytona'` would fail every
      launch. It is moved to the instance default (NULL), which is where a
      pin to a provider the instance cannot use belongs.
    * A sandbox on Daytona that is not yet terminal would be handed to the
      sandbox library, which raises on a provider it has no adapter for.
      It is marked `terminated`, ending when it was last written, and its
      transition stamp is cleared. Nothing is destroyed at Daytona: Daytona is
      already switched off on the hosted instance, so any machine left there
      is the operator's to delete in Daytona's own console. Its conversations
      stay; their next prompt provisions on the instance default.

  Terminal Daytona sandboxes keep `provider = 'daytona'` as history, and
  agents and conversations whose runtime is the removed `opencode` are not
  rewritten either: the columns are plain strings, reads tolerate the old
  value, and `Fountain.RuntimeDispatch.for_agent/1` refuses to run it.

  The previous release, serving during a rolling deploy, reads these rows the
  same way it did before: a terminated sandbox is one it already knows how to
  skip, and a NULL `sandbox_provider` is the default it already resolves.
  """

  def up do
    execute "UPDATE agents SET sandbox_provider = NULL WHERE sandbox_provider = 'daytona'"

    execute """
    UPDATE sandboxes
       SET status = 'terminated',
           terminated_at = COALESCE(terminated_at, updated_at),
           transition = NULL,
           transition_reason = NULL,
           updated_at = now()
     WHERE provider = 'daytona'
       AND status NOT IN ('terminated', 'failed')
    """
  end

  # Data, not shape: which agents were pinned and which sandboxes were live is
  # not recorded, and there is no Daytona adapter to put them back on.
  def down, do: :ok
end
