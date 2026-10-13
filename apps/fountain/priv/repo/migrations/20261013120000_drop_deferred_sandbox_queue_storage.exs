defmodule Fountain.Repo.Migrations.DropDeferredSandboxQueueStorage do
  use Ecto.Migration

  @moduledoc """
  The contract step for the release that removed the sandbox-capacity queue
  and the per-account sandbox cap (ADR 0042 and 0005, 2026-10-13 addenda).

  That release stopped reading `sandbox_requests` and `users.max_concurrent_sandboxes`
  but left both in place: the release before it probes `sandbox_requests` on
  every sandbox status change and selects every `users` column on each
  request, so dropping either mid-rollout would fail the old replicas. Take
  this only after that release is fully rolled out.

  Pending jobs for the removed drainer go with the table, since no worker
  module is left to run them.

  `down` restores the shape, not the rows.
  """

  def up do
    execute "DELETE FROM oban_jobs WHERE worker = 'Fountain.Workers.SandboxQueueDrainer'"

    drop table(:sandbox_requests)

    alter table(:users) do
      remove :max_concurrent_sandboxes
    end
  end

  def down do
    alter table(:users) do
      add :max_concurrent_sandboxes, :integer
    end

    create table(:sandbox_requests, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :agent_id, references(:agents, type: :binary_id, on_delete: :delete_all), null: false
      add :kind, :string, null: false, default: "start"
      add :attrs, :map, null: false, default: %{}
      add :schedule_id, :binary_id
      add :sandbox_key_id, :binary_id
      add :source, :string
      add :status, :string, null: false, default: "queued"

      add :conversation_id,
          references(:conversations, type: :binary_id, on_delete: :nilify_all)

      add :error, :string
      timestamps(type: :utc_datetime_usec)
    end

    create index(:sandbox_requests, [:user_id, :status, :inserted_at])
    create index(:sandbox_requests, [:status], where: "status IN ('queued', 'starting')")
  end
end
