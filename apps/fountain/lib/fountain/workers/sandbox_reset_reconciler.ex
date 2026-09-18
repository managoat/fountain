defmodule Fountain.Workers.SandboxResetReconciler do
  @moduledoc """
  A no-op, kept for one release so a rolling deploy does not page anyone.

  ADR 0058 stage 9b folded this worker's job into
  `Fountain.Workers.SandboxReaper.sweep_fenced_teardowns/0`, which retries an
  unconfirmed reset every five minutes through the same door this worker
  called. During the rolling deploy of that release, pods still on the
  previous release keep running this worker's `*/5` cron entry and enqueue its
  jobs, and a pod on the new release may pick one up. Without the module
  that job fails as an unknown worker, retries, and is discarded after ten
  attempts — which fires the critical `FountainObanJobsDiscarded` alert for a
  job whose work the reaper does anyway.

  So the module stays, does nothing and answers `:ok`, and nothing on this
  release enqueues it (its cron entry is gone from `config/config.exs`).
  **Stage 9b-ii deletes it**, one release later, when no pod can still be
  running the previous one.
  """
  use Oban.Worker, queue: :maintenance, max_attempts: 1

  @impl Oban.Worker
  def perform(%Oban.Job{}), do: :ok
end
