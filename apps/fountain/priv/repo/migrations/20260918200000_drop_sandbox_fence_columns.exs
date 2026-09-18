defmodule Fountain.Repo.Migrations.DropSandboxFenceColumns do
  use Ecto.Migration

  # ADR 0058 stage 9b-ii. `reset_requested_at` and `teardown_requested_at`
  # carried the intent to destroy a machine until stage 9a made the
  # `destroying` stamp carry it; stage 9b-i (#2423) stopped reading and writing
  # them and shipped a release before this one, so no replica that selects them
  # is still serving when this runs.
  #
  # Before 9b-i shipped, production had no live row with a column set and no
  # stamp (the query is in #2423's body); every row a 9a replica fenced carries
  # the stamp too, so dropping the columns drops no intent.
  def up do
    alter table(:sandboxes) do
      remove :reset_requested_at
      remove :teardown_requested_at
    end
  end

  # Back to empty, nullable columns. No release this could roll back to reads
  # them for anything but the fence, and an empty column is an unfenced row,
  # which is what every row the stamp does not fence is.
  def down do
    alter table(:sandboxes) do
      add :reset_requested_at, :utc_datetime_usec
      add :teardown_requested_at, :utc_datetime_usec
    end
  end
end
