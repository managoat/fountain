defmodule Fountain.Repo.Migrations.RecordSandboxTeardownIntent do
  use Ecto.Migration

  # Reversing this migration removes the operation distinction, but retains
  # reset_requested_at and therefore the existing admission fence.
  def change do
    alter table(:sandboxes) do
      add :teardown_requested_at, :utc_datetime_usec
    end
  end
end
