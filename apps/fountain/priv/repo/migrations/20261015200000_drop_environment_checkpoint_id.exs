defmodule Fountain.Repo.Migrations.DropEnvironmentCheckpointId do
  @moduledoc """
  Drops `environments.checkpoint_id` (#2720).

  The previous release removed environment disk checkpoints and unmapped the
  column; it was kept for one release because the release before that selects
  it with every environment it loads. Production never stored a value in it.

  `down` restores the column, empty.
  """
  use Ecto.Migration

  def change do
    alter table(:environments) do
      remove :checkpoint_id, :string
    end
  end
end
