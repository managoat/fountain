defmodule Fountain.Workers.AutonomousTurnReaper do
  @moduledoc """
  Reconciles turns left `running` without a live `ConversationServer`.

  The in-process autonomous quiet timer disappears with its server. This
  worker is the durable backstop for hard crashes and departed nodes. It only
  considers old turns that are not waiting on a permission and have produced
  no recent output. Output is the partition-safe liveness signal because all
  nodes write it to the shared database even when Horde's registry cannot see
  across a cluster partition.

  A conversation that reached its durable output budget can appear quiet even
  while its runtime is active. The server liveness check remains a second
  guard for that case. The oldest candidates are capped per run so a historical
  backlog cannot fan out an unbounded burst of events and webhooks.
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 3

  import Ecto.Query

  require Logger

  alias Fountain.Conversations.{ConversationServer, LogEvent, Turn}
  alias Fountain.Machines.Machine
  alias Fountain.Repo

  @stuck_after_minutes 30
  @quiet_grace_minutes 15
  @reap_limit 25

  @impl Oban.Worker
  def perform(_job) do
    reaped = sweep_stuck_turns()

    Logger.info("autonomous_turn_reaper: reaped=#{reaped}")
    :telemetry.execute([:fountain, :autonomous_turn_reaper, :run], %{reaped: reaped}, %{})

    :ok
  end

  @doc false
  def sweep_stuck_turns do
    now = DateTime.utc_now()
    started_cutoff = DateTime.add(now, -@stuck_after_minutes * 60, :second)
    quiet_cutoff = DateTime.add(now, -@quiet_grace_minutes * 60, :second)

    last_output =
      from(l in LogEvent,
        where: l.turn_id == parent_as(:turn).id and l.kind == "output",
        select: max(l.inserted_at)
      )

    Turn
    |> from(as: :turn)
    |> where([t], t.status == "running" and t.started_at < ^started_cutoff)
    |> where([t], is_nil(t.pending_permission))
    |> where([t], coalesce(subquery(last_output), t.started_at) < ^quiet_cutoff)
    |> order_by([t], asc: t.started_at)
    |> limit(^@reap_limit)
    |> Repo.all()
    |> Enum.count(&reap_if_unowned/1)
  end

  defp reap_if_unowned(%Turn{} = turn) do
    if ConversationServer.whereis(turn.conversation_id) do
      false
    else
      # Through the owner's door (ADR 0058 stage 8a), with no `:sandbox_id`:
      # the reaper recovers on nobody's behalf, so there is no binding to fence
      # on, and the write is the same one it has always made.
      case Machine.end_turn(turn, {:orphan, "stuck_running_no_server"},
             actor: "system:autonomous_turn_reaper"
           ) do
        {:ok, _, _} ->
          Logger.info(
            "autonomous_turn_reaper: reaped turn #{turn.id} " <>
              "(conversation #{turn.conversation_id}) started #{turn.started_at}"
          )

          true

        :noop ->
          false

        {:error, reason} ->
          Logger.warning(
            "autonomous_turn_reaper: could not reap turn #{turn.id}: #{inspect(reason)}"
          )

          false
      end
    end
  end
end
