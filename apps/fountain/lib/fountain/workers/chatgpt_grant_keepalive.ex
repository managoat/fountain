defmodule Fountain.Workers.ChatGPTGrantKeepalive do
  @moduledoc """
  Renews one user's idle ChatGPT grant (ADR 0060 decision 5, stage 5): one
  `Fountain.ChatGPTAccounts.refresh_for_user/3`, queued by
  `Fountain.Workers.ChatGPTKeepaliveSweep`.

  The args are the grant's id, its owner's and the generation the sweep saw,
  and nothing else (0052 decision 2, "jobs carry ids, never tokens"). What
  the sweep saw is a hint. The context reads the grant again by its owner,
  checks the owner may still use one, the generation and whether a renewal
  is still due, and fences its write, so a job that runs after a disconnect,
  a reconnect, a removal, a suspension, a deleted account or somebody else's
  renewal asks the auth server nothing. Those end as `{:cancel, reason}`, or
  `:ok` for a grant already renewed.

  One job per grant, so nothing one grant does reaches another, including
  another of the same user's: a refused refresh token marks that grant
  reconnect-required in the context and cancels that job; a busy coordinator
  or a timeout snoozes that job for a minute or so. A snooze spends none of
  `max_attempts`; those three are for an error that may pass and for a run
  that raised.

  The queue, `chatgpt_refresh`, runs two at a time per node, below the four
  renewals `Fountain.ChatGPTAccounts.RefreshCoordinator` admits, so a turn
  that needs its grant renewed always finds room.

  While `Fountain.ChatGPTAccounts.RefreshBreaker` stands, because the auth
  server has turned this server's address away for two different owners, a
  job snoozes without calling. It does not wait without limit, because the
  breaker's evidence could be wrong and what is waiting is somebody's
  subscription: a job the breaker has held for `@max_deferral_seconds`, or
  whose grant has gone `@probe_idle_days` days unrenewed, goes ahead as a
  probe. Two run at a time per node, and a probe that is refused is an
  ordinary failed attempt. The wake-up is spread again, over the breaker's
  remaining time plus the window the sweep spread the jobs over (it is in the
  job's `meta`; the args stay the three ids), so the jobs a breaker held do
  not all come back in the two minutes after it clears.

  A snooze raises the job's `attempt`, and Oban's default backoff grows with
  it, so `backoff/1` is bounded (ADR 0060, "Stage 4a as built", after
  review). And a job gives way to the next day's sweep rather than snoozing
  without end: `@give_up_seconds` after its **first run**, which is also in
  `meta`, it is cancelled, and the sweep queues the grant again if it is
  still due. From the first run and not from the insert: a job is scheduled
  up to six hours out, and one that sat behind a paused queue for a day has
  not tried anything yet and must not give up on sight.

  A job that fails its last attempt says so once, at `error`, with the
  grant's id and the atom: a grant that fails every day without being
  refused for good is otherwise visible only in a counter. Nothing damps
  such a grant yet; it is queued again by the next sweep.

  Unique on the three ids while a job for them is incomplete, so a replayed
  sweep page queues nothing twice. A reconnect changes the generation, which
  is a different job.

  Its log lines and its telemetry carry the grant's id and an atom.
  """

  use Oban.Worker,
    queue: :chatgpt_refresh,
    max_attempts: 3,
    unique: [
      period: :infinity,
      fields: [:worker, :args],
      keys: [:user_id, :grant_id, :generation],
      states: :incomplete
    ]

  import Ecto.Query, only: [from: 2]

  require Logger

  alias Fountain.ChatGPTAccounts
  alias Fountain.ChatGPTAccounts.RefreshBreaker

  # The grant, or its owner, can no longer be renewed by anybody's retry.
  @terminal ~w(not_connected stale_grant revoked expired disconnected invalid_grant
               account_mismatch undecryptable not_found unwrap_failed no_token)a

  # Somebody else holds the renewal, or this node has no room for it.
  @crowded ~w(refresh_busy refresh_timeout refresh_unavailable)a

  @give_up_seconds 20 * 60 * 60
  @max_backoff_seconds 900
  @max_deferral_seconds 2 * 60 * 60
  @probe_idle_days 7
  @default_window_seconds 300

  @impl Oban.Worker
  def perform(%Oban.Job{args: args} = job) do
    with {:ok, grant_id, user_id, generation} <- identity(args) do
      now = System.os_time(:second)
      job = remember(job, "first_run_at", now)

      cond do
        now - job.meta["first_run_at"] > @give_up_seconds ->
          finish(job, grant_id, :gave_up, {:cancel, :gave_up})

        RefreshBreaker.open?() ->
          deferred(job, grant_id, user_id, generation, now)

        true ->
          renew(job, grant_id, user_id, generation)
      end
    end
  end

  # A retry waits 30 s, 60 s, 120 s and so on up to fifteen minutes, with a
  # little jitter, however many snoozes have raised `attempt`.
  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}) do
    exponent = attempt |> max(1) |> min(6)
    min(@max_backoff_seconds, 15 * Integer.pow(2, exponent)) + :rand.uniform(30)
  end

  # `RefreshCoordinator.run/4` answers within thirty seconds.
  @impl Oban.Worker
  def timeout(_job), do: 35_000

  # The breaker stands. The grant is read by its owner first, metadata only:
  # one that is gone or no longer this generation ends now rather than after
  # the wait, and one too long idle, like a job held too long, is the probe.
  defp deferred(job, grant_id, user_id, generation, now) do
    job = remember(job, "breaker_deferred_at", now)
    held = now - job.meta["breaker_deferred_at"]

    case ChatGPTAccounts.get_for_user(grant_id, user_id) do
      {:ok, %{generation: ^generation} = grant} ->
        if held > @max_deferral_seconds or idle_days(grant, now) >= @probe_idle_days,
          do: renew(job, grant_id, user_id, generation),
          else: finish(job, grant_id, :breaker_open, {:snooze, breaker_snooze(job)})

      {:ok, _reconnected} ->
        finish(job, grant_id, :stale_grant, {:cancel, :stale_grant})

      {:error, :not_found} ->
        finish(job, grant_id, :not_connected, {:cancel, :not_connected})
    end
  end

  defp idle_days(%{last_refreshed_at: %DateTime{} = at}, now),
    do: div(now - DateTime.to_unix(at), 86_400)

  defp idle_days(_grant, _now), do: @probe_idle_days

  defp renew(job, grant_id, user_id, generation) do
    case ChatGPTAccounts.refresh_for_user(grant_id, user_id, generation) do
      :ok ->
        finish(job, grant_id, :ok, :ok)

      {:error, reason} when reason in @terminal ->
        finish(job, grant_id, reason, {:cancel, reason})

      {:error, reason} when reason in @crowded ->
        finish(job, grant_id, reason, {:snooze, 60 + :rand.uniform(60)})

      {:error, reason} when is_atom(reason) ->
        finish(job, grant_id, reason, {:error, reason})
    end
  end

  defp finish(job, grant_id, reason, result) do
    outcome = outcome(result)

    :telemetry.execute([:fountain, :chatgpt, :keepalive, :grant], %{count: 1}, %{
      result: outcome,
      reason: reason
    })

    cond do
      outcome == :ok ->
        :ok

      match?({:error, _}, result) and last_attempt?(job) ->
        Logger.error(
          "chatgpt keepalive: grant #{grant_id} was not renewed and the job is discarded " <>
            "(#{reason}); the next sweep queues it again if it is still due"
        )

      true ->
        Logger.info("chatgpt keepalive: grant #{grant_id} #{outcome} (#{reason})")
    end

    result
  end

  defp last_attempt?(%Oban.Job{attempt: attempt, max_attempts: max})
       when is_integer(attempt) and is_integer(max),
       do: attempt >= max

  defp last_attempt?(_job), do: false

  defp outcome(:ok), do: :ok
  defp outcome({:cancel, _}), do: :cancelled
  defp outcome({:snooze, _}), do: :snoozed
  defp outcome({:error, :rate_limited}), do: :rate_limited
  defp outcome({:error, _}), do: :error

  # Until the breaker clears, and then somewhere in the window the sweep
  # spread these jobs over, so they come back at the sweep's rate.
  defp breaker_snooze(%Oban.Job{meta: meta}) do
    window =
      case meta do
        %{"window" => seconds} when is_integer(seconds) and seconds > 0 -> seconds
        _ -> @default_window_seconds
      end

    RefreshBreaker.remaining_seconds() + :rand.uniform(window)
  end

  # A clock the job keeps about itself, in `meta`: written once, on the row,
  # and read back from the struct. A job that is not a row (a test's) keeps
  # it for the one run.
  defp remember(%Oban.Job{meta: %{} = meta} = job, key, value) do
    if is_integer(meta[key]) do
      job
    else
      if is_integer(job.id) do
        from(j in Oban.Job,
          where: j.id == ^job.id,
          update: [set: [meta: fragment("? || ?", j.meta, ^%{key => value})]]
        )
        |> Fountain.Repo.update_all([])
      end

      %{job | meta: Map.put(meta, key, value)}
    end
  end

  defp remember(%Oban.Job{} = job, key, value), do: remember(%{job | meta: %{}}, key, value)

  defp identity(%{"grant_id" => grant, "user_id" => user, "generation" => generation} = args)
       when map_size(args) == 3 do
    with {:ok, grant} <- Ecto.UUID.cast(grant),
         {:ok, user} <- Ecto.UUID.cast(user),
         {:ok, generation} <- Ecto.UUID.cast(generation) do
      {:ok, grant, user, generation}
    else
      :error -> {:cancel, :invalid_args}
    end
  end

  defp identity(_), do: {:cancel, :invalid_args}
end
