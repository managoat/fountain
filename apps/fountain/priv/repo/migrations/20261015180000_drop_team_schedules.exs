defmodule Fountain.Repo.Migrations.DropTeamSchedules do
  @moduledoc """
  Drops `team_schedules` (ADR 0074, #2703).

  The previous release removed team schedules and stopped reading the
  table; it was kept for one release because the release before that reads
  it on every scheduler tick. The table had no inbound foreign keys.

  Also deletes the Oban jobs the removed workers left behind: the
  `TeamScheduler` cron ticks and `TeamScheduleRun` runs that were queued or
  scheduled when the removal deployed. With no `schedules` queue configured
  nothing runs them, and their worker modules no longer exist.

  `down` restores the table's shape, not its rows or the jobs.
  """
  use Ecto.Migration

  def up do
    execute("""
    DELETE FROM oban_jobs
    WHERE worker IN ('Fountain.Workers.TeamScheduler', 'Fountain.Workers.TeamScheduleRun')
    """)

    drop table(:team_schedules)
  end

  def down do
    create table(:team_schedules, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :agent_id, references(:agents, type: :binary_id, on_delete: :delete_all), null: false
      add :name, :string
      add :cron, :string, null: false
      add :prompt, :text, null: false
      add :one_off, :boolean, null: false, default: false
      add :enabled, :boolean, null: false, default: true
      add :next_run_at, :utc_datetime
      add :last_run_at, :utc_datetime
      add :last_error, :string

      add :last_conversation_id,
          references(:conversations, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create index(:team_schedules, [:user_id])
    create index(:team_schedules, [:agent_id])
    create index(:team_schedules, [:next_run_at], where: "enabled")
  end
end
