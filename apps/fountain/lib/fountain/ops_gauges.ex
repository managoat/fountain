defmodule Fountain.OpsGauges do
  @moduledoc """
  Periodic conversation / sandbox / Oban gauges (#321).

  Runs from the telemetry poller every 10s. Emits one datapoint per known
  status — including zeros — so every series exists from boot: an alert on
  `depth > N` needs the series to come back down to 0 on recovery rather
  than disappear, and a dashboard panel that only materializes during an
  incident is a panel nobody trusts.

  Oban states are the non-terminal ones plus `discarded`: `completed` and
  `cancelled` rows are unbounded history (Oban's Pruner owns them) and their
  count is not a queue-health signal. `discarded` is — a job that exhausted
  its retries failed permanently, and before this existed a nightly
  RetentionPruner or hourly SandboxReaper failure was invisible: Oban
  catches job exceptions internally, so nothing crashed and nothing paged.
  """

  import Ecto.Query

  require Logger

  alias Fountain.Repo

  @oban_states ~w(available scheduled executing retryable discarded)

  def emit_telemetry do
    # Guarded because telemetry_poller permanently drops a measurement
    # whose tick fails in any class — see Fountain.TelemetryTick (#365, #395).
    Fountain.TelemetryTick.run("ops gauges", fn ->
      emit_status_counts(
        [:fountain, :conversations],
        Fountain.Conversations.Conversation,
        Fountain.Conversations.Conversation.statuses()
      )

      emit_status_counts(
        [:fountain, :sandboxes],
        Fountain.Conversations.Sandbox,
        Fountain.Conversations.Sandbox.statuses()
      )

      emit_sandbox_provider_counts()
      emit_oban_depths()
    end)
  end

  # How many sandboxes are costing money on each provider right now — the live
  # counterpart to the after-the-fact roll-up in
  # `Fountain.Machines.Usage`, and the series to watch when a provider
  # bill moves. Deliberately not tagged by tenant: attribution belongs in the
  # database report, where a per-user dimension is a column rather than a new
  # Prometheus series per account.
  #
  # Terminal statuses are excluded for the same reason Oban's are: those rows
  # are unbounded history, not a signal.
  @live_statuses ~w(pending starting ready suspended)

  defp emit_sandbox_provider_counts do
    counts =
      Repo.all(
        from(s in Fountain.Conversations.Sandbox,
          where: s.status in @live_statuses,
          group_by: [s.provider, s.status],
          select: {{s.provider, s.status}, count(s.id)}
        )
      )
      |> Map.new()

    for provider <- Fountain.SandboxProviders.known_providers(), status <- @live_statuses do
      :telemetry.execute(
        [:fountain, :sandboxes_by_provider],
        %{count: Map.get(counts, {provider, status}, 0)},
        %{provider: provider, status: status}
      )
    end
  end

  # Scoped to the statuses asked for, which is a no-op for a caller passing its
  # schema's whole list and the difference between a full-table group-by and an
  # index read for one passing a subset. This runs every ten seconds.
  defp emit_status_counts(event, schema, statuses) do
    counts =
      Repo.all(
        from(r in schema,
          where: r.status in ^statuses,
          group_by: r.status,
          select: {r.status, count(r.id)}
        )
      )
      |> Map.new()

    for status <- statuses do
      :telemetry.execute(event, %{count: Map.get(counts, status, 0)}, %{status: status})
    end
  end

  defp emit_oban_depths do
    counts =
      Repo.all(
        from(j in Oban.Job,
          where: j.state in @oban_states,
          group_by: [j.queue, j.state],
          select: {{j.queue, j.state}, count(j.id)}
        )
      )
      |> Map.new()

    for queue <- known_queues(), state <- @oban_states do
      :telemetry.execute(
        [:fountain, :oban_queue],
        %{depth: Map.get(counts, {queue, state}, 0)},
        %{queue: queue, state: state}
      )
    end
  end

  defp known_queues do
    :fountain
    |> Application.fetch_env!(Oban)
    |> Keyword.get(:queues, [])
    |> Enum.map(fn {queue, _conc} -> to_string(queue) end)
  end
end
