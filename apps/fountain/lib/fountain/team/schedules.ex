defmodule Fountain.Team.Schedules do
  @moduledoc """
  Scheduled prompts for teammates — a cron that runs a team member with a
  given prompt.

  A schedule belongs to a teammate (a user + agent on the team) and says
  what to send and when. Two ways to run, chosen per schedule:

    * **in the teammate's conversation** (`one_off: false`) — the prompt
      goes through `Fountain.Team.send_message/5`, so it lands in the same
      thread `/team` shows, wakes the teammate's computer if it is parked,
      and replaces it if it is gone, exactly as a typed message would;
    * **on a one-off computer** (`one_off: true`) — each run opens a fresh
      conversation with the same agent, environment and vault the teammate
      was added with, seeded with the prompt. The teammate's own thread is
      untouched; the run is an ordinary conversation in `/conversations`.

  Firing is two Oban pieces: `Fountain.Workers.TeamScheduler` ticks every
  minute, claims what is due (`_unsafe_claim_due/1` — a compare-and-swap on
  `next_run_at`, so a claim happens once however many tickers run) and
  enqueues one `Fountain.Workers.TeamScheduleRun` per claim, which calls
  `run_schedule/2`. Everything a run leaves is on the row: `last_run_at`,
  `last_conversation_id`, `last_error`.

  Times are UTC: the app has no time-zone database, and a schedule that says
  `0 9 * * 1-5` means 09:00 UTC. The UI says so.

  Every user-facing function is tenant-scoped by `user_id`; the `_unsafe_`
  ones are for the workers.
  """

  import Ecto.Query, warn: false

  alias Fountain.{Agents, Audit, Repo, Team}
  alias Fountain.Conversations.Launch
  alias Fountain.Team.Schedule

  @actor "system:team_scheduler"

  @doc "The audit actor a run fires as."
  def actor, do: @actor

  @doc "Every schedule of `user_id`, soonest next run first, agent preloaded."
  def list_schedules(user_id) when is_binary(user_id) do
    from(s in Schedule,
      where: s.user_id == ^user_id,
      order_by: [asc_nulls_last: s.next_run_at, asc: s.inserted_at],
      preload: [:agent]
    )
    |> Repo.all()
  end

  @doc "The schedules of one teammate."
  def list_schedules(user_id, agent_id) when is_binary(user_id) and is_binary(agent_id) do
    from(s in Schedule,
      where: s.user_id == ^user_id and s.agent_id == ^agent_id,
      order_by: [asc_nulls_last: s.next_run_at, asc: s.inserted_at],
      preload: [:agent]
    )
    |> Repo.all()
  end

  @doc "One schedule, tenant-scoped; nil when not the user's."
  def get_schedule(id, user_id) when is_binary(id) and is_binary(user_id) do
    Repo.one(from(s in Schedule, where: s.id == ^id and s.user_id == ^user_id, preload: [:agent]))
  end

  @doc "For the run worker, which acts as the system: no tenant scope."
  def _unsafe_get_schedule(id) when is_binary(id) do
    Repo.get(Schedule, id) |> Repo.preload(:agent)
  end

  @doc """
  Create a schedule for the teammate on `attrs["agent_id"]`.

  `attrs` is string-keyed: `"agent_id"`, `"cron"`, `"prompt"`, and
  optionally `"name"`, `"one_off"`, `"enabled"`. The agent must be the
  user's — `{:error, :not_found}` otherwise; it need not be on the team yet
  (a one-off schedule runs without a teammate; an in-thread one fails each
  run with "not on the team" until it is). `next_run_at` is computed here.
  Audited as `team.schedule.created`; `opts` is attribution.
  """
  def create_schedule(user_id, attrs, opts \\ []) when is_binary(user_id) and is_map(attrs) do
    with %Agents.Agent{} = agent <-
           Agents.get_agent(attrs["agent_id"] || "", user_id) || {:error, :not_found} do
      attrs = attrs |> Map.put("user_id", user_id) |> Map.put("agent_id", agent.id)

      %Schedule{}
      |> Schedule.changeset(attrs)
      |> put_next_run_at()
      |> Repo.insert()
      |> case do
        {:ok, schedule} ->
          schedule = Repo.preload(schedule, :agent)
          record("team.schedule.created", schedule, opts, describe(schedule))
          Team.broadcast_schedules_changed(schedule.user_id)
          {:ok, schedule}

        {:error, _} = err ->
          err
      end
    end
  end

  @doc """
  Update a schedule's user-editable fields. A changed cron or a re-enable
  recomputes `next_run_at` and clears `last_error`. Audited as
  `team.schedule.updated` with the changed field names.
  """
  def update_schedule(%Schedule{} = schedule, attrs, opts \\ []) when is_map(attrs) do
    changeset = Schedule.changeset(schedule, attrs)

    changeset =
      if Ecto.Changeset.changed?(changeset, :cron) or
           Ecto.Changeset.get_change(changeset, :enabled) == true,
         do: changeset |> put_next_run_at() |> Ecto.Changeset.put_change(:last_error, nil),
         else: changeset

    case Repo.update(changeset) do
      {:ok, updated} ->
        updated = Repo.preload(updated, :agent, force: true)

        if changeset.changes != %{} do
          record("team.schedule.updated", updated, opts, Audit.changed_fields(changeset))
          Team.broadcast_schedules_changed(updated.user_id)
        end

        {:ok, updated}

      {:error, _} = err ->
        err
    end
  end

  @doc "Delete a schedule. Audited as `team.schedule.deleted`."
  def delete_schedule(%Schedule{} = schedule, opts \\ []) do
    with {:ok, deleted} <- Repo.delete(schedule) do
      record("team.schedule.deleted", deleted, opts, describe(schedule))
      Team.broadcast_schedules_changed(deleted.user_id)
      {:ok, deleted}
    end
  end

  @doc """
  Delete every schedule of one teammate — what removing the teammate does.
  Nothing is recorded per row: the `team.member.removed` event covers it,
  and the schedules cannot outlive the teammate they belong to.
  """
  def _unsafe_delete_for_teammate(user_id, agent_id)
      when is_binary(user_id) and is_binary(agent_id) do
    {n, _} =
      Repo.delete_all(
        from(s in Schedule, where: s.user_id == ^user_id and s.agent_id == ^agent_id)
      )

    if n > 0, do: Team.broadcast_schedules_changed(user_id)
    n
  end

  @doc """
  Run the schedule now — from the worker on its cron, or from the UI's "Run
  now". Returns `{:ok, conv}` with the conversation the prompt went to, or
  the `Team.send_message/5` / `Fountain.Conversations.Launch.start_conversation/2` error
  unchanged (`:busy`, `:provisioning`, `:not_found`, `:fleet_full`, ...). A
  firing stamps `last_run_at`, and `last_conversation_id` / `last_error` say
  how it went; the caller decides whether an error is worth retrying (the
  worker snoozes on the transient ones, `:fleet_full` among them).

  `opts` is audit attribution: `Fountain.Workers.TeamScheduleRun` passes
  `actor: "system:team_scheduler"`, the UI passes the socket's. Recorded as
  `team.schedule.fired` on top of the conversation events underneath.
  """
  def run_schedule(%Schedule{} = schedule, opts \\ []) do
    result =
      if schedule.one_off,
        do: run_one_off(schedule, opts),
        else: Team.send_message(schedule.user_id, schedule.agent_id, schedule.prompt, [], opts)

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {:ok, _} = schedule |> Schedule.run_changeset(ran_attrs(result, now)) |> Repo.update()
    Team.broadcast_schedules_changed(schedule.user_id)

    record(
      "team.schedule.fired",
      schedule,
      opts,
      Map.merge(describe(schedule), %{
        "outcome" => outcome(result),
        "conversation_id" =>
          case result do
            {:ok, conv} -> conv.id
            _ -> nil
          end
      })
    )

    result
  end

  defp outcome({:ok, _conv}), do: "ok"
  defp outcome({:error, reason}), do: describe_error(reason)

  defp ran_attrs({:ok, conv}, now),
    do: %{last_run_at: now, last_conversation_id: conv.id, last_error: nil}

  defp ran_attrs({:error, reason}, now),
    do: %{last_run_at: now, last_error: describe_error(reason)}

  # A fresh conversation with what the teammate has: its agent, and the
  # environment override and vault its current team conversation carries.
  # Off the team, the agent's own defaults apply — that is what "same
  # environment and vault" means when there is no teammate to copy.
  defp run_one_off(%Schedule{} = schedule, opts) do
    {env_id, vault_id} =
      case Team.get_teammate(schedule.user_id, schedule.agent_id) do
        %{conversation: conv} -> {conv.environment_id, conv.vault_id}
        nil -> {nil, nil}
      end

    Launch.start_conversation(
      %{
        "agent_id" => schedule.agent_id,
        "user_id" => schedule.user_id,
        "prompt" => schedule.prompt,
        "source" => "ui",
        "environment_id" => env_id,
        "vault_id" => vault_id
      },
      opts
    )
  end

  @doc """
  Claim every enabled schedule due at `now`: advance its `next_run_at` past
  `now` and return it. The advance is a compare-and-swap on the old
  `next_run_at`, so two tickers racing on one row claim it once. Rows whose
  cron no longer parses (it cannot — the changeset checks — but a row is
  data) are disabled with an error rather than claimed forever.
  """
  def _unsafe_claim_due(now \\ DateTime.utc_now()) do
    now = DateTime.truncate(now, :second)

    from(s in Schedule,
      where: s.enabled and not is_nil(s.next_run_at) and s.next_run_at <= ^now,
      order_by: [asc: s.next_run_at],
      preload: [:agent]
    )
    |> Repo.all()
    |> Enum.filter(&claim(&1, now))
  end

  defp claim(%Schedule{} = schedule, now) do
    case Schedule.next_run_at(schedule.cron, now) do
      {:ok, next} ->
        {n, _} =
          Repo.update_all(
            from(s in Schedule,
              where: s.id == ^schedule.id and s.next_run_at == ^schedule.next_run_at
            ),
            set: [next_run_at: next]
          )

        n == 1

      {:error, message} ->
        {_n, _} =
          Repo.update_all(from(s in Schedule, where: s.id == ^schedule.id),
            set: [enabled: false, last_error: "disabled: cron #{message}"]
          )

        false
    end
  end

  # ── helpers ───────────────────────────────────────────────────────────────

  defp put_next_run_at(%Ecto.Changeset{valid?: false} = changeset), do: changeset

  defp put_next_run_at(changeset) do
    cron = Ecto.Changeset.get_field(changeset, :cron)

    case Schedule.next_run_at(cron) do
      {:ok, next} -> Ecto.Changeset.put_change(changeset, :next_run_at, next)
      {:error, message} -> Ecto.Changeset.add_error(changeset, :cron, message)
    end
  end

  # What a run's failure reads as on the row and in the UI. Never the prompt.
  def describe_error(:busy), do: "teammate was busy"

  def describe_error(:sandbox_at_capacity),
    do: "teammate's computer was busy with another conversation"

  def describe_error(:provisioning), do: "teammate's computer was still starting"

  # ADR 0058: an owner held the machine — parking it, rebuilding it, destroying
  # it. The sentence has to cover all three, including the one where the
  # computer does not come back, so it says what Fountain was doing rather than
  # what the computer was doing (round 1, surfaces review: "was being started or
  # stopped" told a user to expect a destroyed machine back). Deliberately not
  # "busy", which this vocabulary already spends on a teammate mid-turn and on a
  # full machine.
  def describe_error(:sandbox_unavailable),
    do: "Fountain was working on the teammate's computer"

  def describe_error(:not_found), do: "agent is not on the team"
  def describe_error(:fleet_full), do: "sandbox fleet is full"
  def describe_error(:runner_offline), do: "teammate's machine is offline"
  def describe_error(:sprite_probe_failed), do: "could not reach the sandbox provider"

  # The vocabulary below was found missing by the ADR 0058 stage 7 inventory:
  # each reached a schedule's `last_error` as `inspect/1`'s output, which is a
  # module name in a column a person reads.
  #
  # A machine parked on a provider whose credentials have gone. The wake
  # deliberately refuses rather than retiring the row (the parked disk is the
  # agent's memory), so the answer is about the provider, not the teammate.
  def describe_error({:sandbox_provider_disabled, provider}),
    do: "the #{provider} sandbox provider is not configured"

  # ADR 0058 stage 7a: the provider was asked to bring a parked machine back and
  # would not. The disk is intact and the row is still parked, so this is worth
  # retrying — which is what the 503 at the API says too.
  def describe_error(:sandbox_resume_failed),
    do: "teammate's computer would not wake up"

  # A reset or a teardown has been asked for, so the computer is going away and
  # there is nothing to wake. It reached this vocabulary in stage 7a, when the
  # owner's wake started answering it (round 1, surfaces review); the front door
  # has answered it since long before, but no schedule run had ever met one.
  # Not "busy" and not a retry: the fence's own owner finishes the job, and a
  # run against a computer being deleted has nowhere to go.
  def describe_error(:sandbox_reset_pending),
    do: "teammate's computer is being reset or deleted"


  def describe_error(%Ecto.Changeset{}), do: "could not open a conversation"
  def describe_error(other), do: inspect(other) |> String.slice(0, 250)

  # Names and shapes, never the prompt: it is the tenant's content.
  defp describe(%Schedule{} = s) do
    %{
      "name" => s.name,
      "agent_id" => s.agent_id,
      "agent_name" => s.agent && s.agent.name,
      "cron" => s.cron,
      "one_off" => s.one_off,
      "enabled" => s.enabled,
      "prompt_bytes" => byte_size(s.prompt || "")
    }
  end

  defp record(action, %Schedule{} = schedule, opts, metadata) do
    Audit.record(%{
      user_id: schedule.user_id,
      action: action,
      resource_type: "team_schedule",
      resource_id: schedule.id,
      actor: Keyword.get(opts, :actor, "self"),
      request_ip: Keyword.get(opts, :request_ip),
      metadata: metadata
    })
  end
end
