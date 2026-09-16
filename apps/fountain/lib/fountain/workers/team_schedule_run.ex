defmodule Fountain.Workers.TeamScheduleRun do
  @moduledoc """
  One firing of one team schedule: `Fountain.Team.Schedules.run_schedule/2`
  as a job, so it retries sensibly and never blocks the ticker.

  A teammate that is busy (`:busy`), whose computer is still starting
  (`:provisioning`) or whose own machine is off (`:runner_offline`) is worth
  waiting for: the job snoozes and tries again,
  for up to `@wait_for` after the scheduled time, then gives up with the
  error on the row — the next scheduled run is a better use of the prompt
  than a stale one delivered an hour late. Every other error is final for
  this firing: it is on the schedule's `last_error`, and retrying `:not_found`
  or a quota error seconds later would not change it.

  Idempotent per `{schedule_id, fired_at}` — the unique clause below — so a
  ticker that is retried cannot enqueue the same firing twice.
  """

  use Oban.Worker,
    queue: :schedules,
    max_attempts: 3,
    unique: [keys: [:schedule_id, :fired_at], period: 3600]

  require Logger

  alias Fountain.SandboxQueue
  alias Fountain.Team.Schedules

  # How long a firing waits for a busy teammate before it is dropped.
  @wait_for 30 * 60
  @snooze 30

  # `SandboxQueue`'s own transient-error list rather than a second copy of it
  # (ADR 0058 stage 6a). The two said the same thing until 6a added
  # `sandbox_unavailable` to the queue's, and a list spelled out here is a list
  # that gets found one refusal late. A module attribute because the guard
  # below needs one; assigning it from `SandboxQueue.transient_errors()` makes
  # this module compile-time dependent on `SandboxQueue`, which Mix orders
  # correctly on its own.
  @transient_errors SandboxQueue.transient_errors()

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"schedule_id" => id} = args}) do
    case Schedules._unsafe_get_schedule(id) do
      nil ->
        :ok

      %{enabled: false} ->
        :ok

      schedule ->
        # The schedule is the system's to run — the tenant set it up — so
        # the actor is the worker; the row already carries the user.
        case Schedules.run_schedule(schedule, actor: Schedules.actor()) do
          {:ok, _conv} ->
            :ok

          # A runner-backed teammate whose machine is off (#834) is the
          # same wait: it may come back within the window.
          # A shared machine busy with another conversation's turn
          # (`:sandbox_at_capacity`) frees itself the same way a busy
          # teammate does. So does a machine its owner is mid-operation on
          # (`:sandbox_unavailable`, ADR 0058), on a shorter clock than any
          # of them.
          {:error, reason} when reason in @transient_errors ->
            if stale?(args), do: :ok, else: {:snooze, @snooze}

          {:error, reason} ->
            Logger.info("team_schedule_run: #{id} did not run: #{inspect(reason)}")
            :ok
        end
    end
  end

  defp stale?(%{"fired_at" => fired_at}) do
    case DateTime.from_iso8601(fired_at) do
      {:ok, at, _} -> DateTime.diff(DateTime.utc_now(), at, :second) > @wait_for
      _ -> true
    end
  end

  defp stale?(_), do: false
end
