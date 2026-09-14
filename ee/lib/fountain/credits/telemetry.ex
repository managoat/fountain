defmodule Fountain.Credits.Telemetry do
  @moduledoc """
  What the credit workers report about themselves (#1169).

  Under ADR 0031 the balance is the gate, so the workers that keep it honest
  are load-bearing — and until this existed none of them was watched. The only
  coverage was `FountainObanJobsRaising`, which needs a job to *raise*. A
  pricer that runs happily and prices nothing (a bad rate config, an empty
  `SandboxUsage`, a query that silently matches zero rows) never tripped it,
  and the failure mode is free compute with no signal at all.

  Two events, deliberately shaped for the two different questions.

  ### `[:fountain, :credits, :worker, :run]`

  "Did this worker run?" One event per pass, tagged `worker`
  (`pricer` / `expirer`), carrying `last_run_unix` and `total` (the
  rows it wrote). `last_run_unix` is a wall-clock stamp rather than a counter
  because the alert is a staleness one, and a gauge survives a worker that
  never fires at all, which is exactly the case a counter cannot express.

  **The per-replica gauge trap applies.** The stamp only exists on the pod
  that ran the Oban job, so every rule over it needs `max`, not `avg` or a
  bare selector.

  ### `[:fountain, :credits, :posted]`

  "Did money actually move?" Emitted by `Fountain.Credits.post/4` at the
  ledger write, not by a worker counting its own output, so the measurement
  cannot drift from the ledger. Tagged by `reason`, which is a closed
  vocabulary, so one event answers turns, inference, expiry, grants and
  purchases.

  That split is the point. A worker can run on schedule and still be broken,
  which is why "it ran" and "money moved" have to be separate signals.
  """

  @workers ~w(pricer expirer)

  @doc """
  Report that a credit worker finished a pass.

  `counts` is the map the worker's own `run/1` returns; `total` is the sum of
  its values, so a caller does not have to know which keys a given worker has.
  """
  @spec emit_run(String.t(), map()) :: :ok
  def emit_run(worker, counts) when worker in @workers and is_map(counts) do
    total = counts |> Map.values() |> Enum.filter(&is_integer/1) |> Enum.sum()

    :telemetry.execute(
      [:fountain, :credits, :worker, :run],
      Map.merge(counts, %{last_run_unix: System.system_time(:second), total: total}),
      %{worker: worker}
    )
  end
end
