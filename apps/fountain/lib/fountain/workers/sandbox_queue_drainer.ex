defmodule Fountain.Workers.SandboxQueueDrainer do
  @moduledoc """
  Drains sandbox requests after capacity changes (#1033, ADR 0042).

  Two job shapes. `%{user_id: id}` drains one tenant. `%{scope: "all"}` (and
  the cron's empty args) fans out to every tenant with live work. The choke
  point that frees a slot schedules the fan-out, so a caller writing one
  sandbox row pays for one insert rather than a scan plus an insert per
  waiting tenant.

  A drain is Oban work rather than a task started from the path that freed the
  slot: it outlives the request, it must survive a replica going away
  mid-drain, and an unawaited `Task.async` linked to a web request would take
  that request down when a replay failed (#1040).

  Uniqueness is `[:user_id, :scope]` over `:scheduled` only. `:scope` is in
  the key so a fan-out job and a tenant job are never mistaken for each other.
  Oban's own state groups are the only alternative to `:scheduled` here, and
  every one of them includes `executing` — a poke reporting capacity that a
  running drain has already read past must create a follow-up job, not vanish
  into a uniqueness window.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [keys: [:user_id, :scope], period: 30, states: :scheduled]

  alias Fountain.SandboxQueue

  require Logger

  @doc "Enqueue a drain for one tenant."
  def poke(user_id) when is_binary(user_id) do
    %{user_id: user_id} |> new(schedule_in: 1) |> Oban.insert()
    :ok
  end

  @doc """
  Enqueue one job that fans out to every tenant with live requests.

  One insert, not one per waiting tenant: the caller is
  `Conversations.sandbox_status_effects/2`, which every sandbox status change
  runs after its write (the machine owner's, since ADR 0058), and the scan that finds those tenants belongs in a job
  rather than on the path that wrote the row.
  """
  def poke_all_later do
    %{scope: "all"} |> new(schedule_in: 1) |> Oban.insert()
    :ok
  end

  @doc "Enqueue one drain for every tenant with live requests."
  def poke_all do
    Enum.each(SandboxQueue.user_ids_with_active_requests(), &poke/1)
    :ok
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"user_id" => user_id}}) do
    %{started: started, failed: failed, expired: expired} = SandboxQueue.drain(user_id)

    if started + failed + expired > 0 do
      Logger.info(
        "sandbox queue: user #{user_id} started #{started}, failed #{failed}, expired #{expired}"
      )
    end

    :ok
  end

  def perform(%Oban.Job{args: %{"scope" => "all"}}), do: poke_all()

  # The cron backstop arrives with no args at all.
  def perform(%Oban.Job{args: args}) when map_size(args) == 0, do: poke_all()
end
