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
  job snoozes without calling. The breaker's evidence could be wrong and
  what is waiting is somebody's subscription, so the wait is bounded, and
  what bounds it is a probe: a job the breaker has held for
  `@max_deferral_seconds`, or whose grant has gone `@probe_idle_days` days
  unrenewed, asks to be the probe, and **one job per node per fifteen
  minutes is**. The others wait for the pause to end, or for the next probe
  if that is sooner. A probe that succeeds closes the breaker for every job;
  one that is refused keeps it open (`RefreshBreaker.probe_refused/0`); one
  that asked the auth server nothing, because its renewal was crowded out or
  its grant can no longer be renewed, gives the turn back. A job never
  sleeps past the moment it would
  become due to probe, because that is only looked at when it wakes; short
  of that its wake-up is spread over the breaker's remaining time plus the
  window the sweep spread the jobs over (it is in the job's `meta`; the args
  stay the three ids), so the jobs a pause held do not all come back in the
  two minutes after it clears. When the breaker is down again the job
  forgets it was held, so a later pause starts its two hours afresh.

  A grant that is refused is the evidence the breaker stands on, and a
  grant that is always refused would otherwise be due to probe at every
  wake from its seventh idle day, against every other owner's job, first
  come. So a refusal that looks like a throttled address (`:rate_limited`),
  to a probe or to any run, is a snooze and not a failed attempt, and the
  job is not due to probe again, by either clock, until `refused_at` plus
  two hours, doubling with each refusal (`refusals`) up to a day; both are
  in `meta`. It costs a grant that really is throttled nothing: with the
  breaker down it runs as any job does.

  What this bounds, and what it does not. Under real throttling, while some
  job is due to probe, a node sends one keepalive request per fifteen
  minutes and the breaker does not lapse between them. When none is due
  (the first two hours, or every due job backed off) it lapses, and the
  jobs that wake then call until two owners have been refused again: two
  requests, or three with both queue slots busy. A job asks at most once
  per wait and spends no attempt on it. Under a breaker somebody is
  holding open on false evidence, one victim's job may wait as long as the
  breaker stands, less whatever a success from any owner, a turn's renewal
  included, cuts it short by: it is no longer guaranteed a request of its
  own at two hours, because that guarantee for every job was the hammer.

  A snooze raises the job's `attempt`, and Oban's default backoff grows with
  it, so `backoff/1` is bounded (ADR 0060, "Stage 4a as built", after
  review). Snoozes raise `max_attempts` too, so nothing in Oban ends a job
  that only ever snoozes: `@stop_seconds`, three days, after its **first
  run** (kept in `meta`; a job is scheduled up to six hours out and may sit
  behind a paused queue) it is cancelled whatever it is waiting on. There is
  no earlier give-up: while the job is incomplete the next sweep's insert
  for its grant conflicts with it, so the job is the grant's place in the
  queue, and a grant that is no longer due is an `:ok` at its next run.

  A job that fails its last attempt, or raises on it, or is stopped at three
  days, or is held while its grant is known to be seven days unrenewed,
  says so at `error` through `Fountain.LogThrottle`: once a minute per
  node, with one grant's id and the atom, and the counter's `discarded`
  says how many there were. A run Oban kills at its timeout is not seen
  here. Nothing damps a grant that fails every day without being refused
  for good; it is queued again by the next sweep.

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

  @stop_seconds 72 * 60 * 60
  @max_backoff_seconds 900
  @max_deferral_seconds 2 * 60 * 60
  @max_refusal_backoff_seconds 24 * 60 * 60
  @probe_idle_days 7
  @default_window_seconds 300
  @throttled_pause_seconds 900

  @impl Oban.Worker
  def perform(%Oban.Job{args: args} = job) do
    with {:ok, grant_id, user_id, generation} <- identity(args) do
      now = System.os_time(:second)
      job = remember(job, "first_run_at", now)

      cond do
        now - job.meta["first_run_at"] > @stop_seconds ->
          stopped(job, grant_id)

        RefreshBreaker.open?() ->
          deferred(job, grant_id, user_id, generation, now)

        true ->
          # The breaker is down, so whatever it held this job for is over:
          # the next time it stands, the two hours start again.
          job |> forget("breaker_deferred_at") |> renew(grant_id, user_id, generation, now, false)
      end
    end
  rescue
    error ->
      # A run that raises on its last attempt is discarded like one that
      # fails it. A run Oban kills at `timeout/1`, or that exits, is not
      # seen here: that one shows only in Oban's own telemetry.
      if last_attempt?(job), do: discarded(job.args["grant_id"], :raised)
      reraise error, __STACKTRACE__
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
  # one that is gone, reconnected or no longer active ends now rather than
  # after the wait. One held two hours, or seven days idle, asks to be the
  # probe, and one job per node per pause length is.
  defp deferred(job, grant_id, user_id, generation, now) do
    job = remember(job, "breaker_deferred_at", now)

    case ChatGPTAccounts.get_for_user(grant_id, user_id) do
      {:ok, %{generation: ^generation, status: "active"} = grant} ->
        if probe_due?(job, grant, now) and RefreshBreaker.claim_probe() == :claimed,
          do: renew(job, grant_id, user_id, generation, now, true),
          else: held(job, grant_id, grant, now)

      {:ok, %{generation: ^generation, status: status}} ->
        reason = String.to_existing_atom(status)
        finish(job, grant_id, reason, {:cancel, reason})

      {:ok, _reconnected} ->
        finish(job, grant_id, :stale_grant, {:cancel, :stale_grant})

      {:error, :not_found} ->
        finish(job, grant_id, :not_connected, {:cancel, :not_connected})
    end
  end

  # Held, and not the probe. A grant known to be seven days unrenewed is a
  # day from the assumed lapse, which until this line only a counter said:
  # once a minute per node, one grant's id.
  defp held(job, grant_id, grant, now) do
    if match?(%{last_refreshed_at: %DateTime{}}, grant) and
         idle_seconds(grant, now) >= @probe_idle_days * 86_400 do
      Fountain.LogThrottle.error(
        {:chatgpt_keepalive, :held_idle},
        "chatgpt keepalive: grant #{grant_id} has gone #{div(idle_seconds(grant, now), 86_400)} " <>
          "days unrenewed and still waits on the refresh breaker; a sign-in is assumed to " <>
          "lapse at eight. Others may be too (fountain_chatgpt_keepalive_grant_count)"
      )
    end

    finish(job, grant_id, :breaker_open, {:snooze, held_snooze(job, grant, now)})
  end

  defp probe_due?(job, grant, now), do: probe_due_at(job, grant, now) <= now

  # The second at which this job may ask to be the probe: held two hours or
  # its grant seven days idle, whichever is first, and in no case before its
  # last refusal's back-off has passed. That last is what keeps a grant that
  # is always refused, the breaker's own evidence, out of the way of the
  # jobs it is holding.
  defp probe_due_at(job, grant, now) do
    held = job.meta["breaker_deferred_at"] + @max_deferral_seconds
    idle = now + @probe_idle_days * 86_400 - idle_seconds(grant, now)
    max(min(held, idle), backed_off_until(job))
  end

  # Two hours after the first refusal, then four, eight, sixteen, and a day.
  defp backed_off_until(%Oban.Job{meta: %{"refused_at" => at, "refusals" => refusals}})
       when is_integer(at) and is_integer(refusals) and refusals > 0 do
    doubled = @max_deferral_seconds * Integer.pow(2, min(refusals, 5) - 1)
    at + min(@max_refusal_backoff_seconds, doubled)
  end

  defp backed_off_until(_job), do: 0

  # How long a held job sleeps. Spread over the sweep's window again, so the
  # jobs a pause held come back at the sweep's rate; and never past the
  # moment this job becomes due to probe, because that is only looked at
  # when it wakes. One that is due already and was not the probe wakes when
  # the next probe can be claimed, or when the pause ends if that is sooner.
  # Never sooner than thirty seconds. The queue's two slots pace whatever
  # wakes together.
  defp held_snooze(job, grant, now) do
    remaining = RefreshBreaker.remaining_seconds()
    spread = max(30, remaining) + :rand.uniform(window(job))

    wait =
      case probe_due_at(job, grant, now) - now do
        due_in when due_in > 0 -> due_in
        _due -> min(remaining, RefreshBreaker.probe_seconds())
      end

    min(spread, max(30, wait) + :rand.uniform(120))
  end

  defp window(%Oban.Job{meta: %{"window" => seconds}}) when is_integer(seconds) and seconds > 0,
    do: seconds

  defp window(_job), do: @default_window_seconds

  # A grant with no renewal on record (the column allows it; the changeset
  # does not, and linking sets it) is of unknown age, so it is taken for the
  # oldest a grant can safely be and is due to probe at once. It is not said
  # to be seven days idle in a log line, which nobody knows.
  defp idle_seconds(%{last_refreshed_at: %DateTime{} = at}, now), do: now - DateTime.to_unix(at)
  defp idle_seconds(_grant, _now), do: @probe_idle_days * 86_400

  # `probe?`: this run is the breaker's one probe. A probe that did not reach
  # the auth server (a grant already renewed, one that cannot be, a renewal
  # crowded out) gives the turn back, or nobody would ask for a pause length.
  defp renew(job, grant_id, user_id, generation, now, probe?) do
    case ChatGPTAccounts.refresh_for_user(grant_id, user_id, generation) do
      :ok ->
        # After a real success the breaker's table is empty and this is nothing.
        release(probe?)
        finish(job, grant_id, :ok, :ok)

      {:error, reason} when reason in @terminal ->
        release(probe?)
        finish(job, grant_id, reason, {:cancel, reason})

      {:error, reason} when reason in @crowded ->
        release(probe?)
        finish(job, grant_id, reason, {:snooze, 60 + :rand.uniform(60)})

      # Turned away as a throttled address is, as a probe or not. Asking again
      # soon is the one thing not to do, so this is a wait and not a failed
      # attempt: the two hours start again from now, the job stays out of the
      # probe's way for its back-off, and it asks once per wait at most. A
      # probe's refusal keeps the breaker open by itself.
      {:error, :rate_limited} ->
        if probe?, do: RefreshBreaker.probe_refused()

        job =
          restart(job, %{
            "breaker_deferred_at" => now,
            "refused_at" => now,
            "refusals" => refusals(job) + 1
          })

        pause = max(RefreshBreaker.remaining_seconds(), @throttled_pause_seconds)
        finish(job, grant_id, :rate_limited, {:snooze, pause + :rand.uniform(window(job))})

      {:error, reason} when is_atom(reason) ->
        finish(job, grant_id, reason, {:error, reason})
    end
  end

  defp release(true), do: RefreshBreaker.release_probe()
  defp release(false), do: :ok

  defp refusals(%Oban.Job{meta: %{"refusals" => count}}) when is_integer(count) and count > 0,
    do: count

  defp refusals(_job), do: 0

  # Three days after its first run, whatever it is waiting on. Snoozes raise
  # `max_attempts` with `attempt`, so nothing else ends a job that is always
  # answered "busy", or always turned away, and by now the sign-in has
  # lapsed at the auth server if this was its only renewal. The next sweep
  # queues the grant again if it still reads as due.
  defp stopped(job, grant_id) do
    Fountain.LogThrottle.error(
      {:chatgpt_keepalive, :stopped},
      "chatgpt keepalive: grant #{grant_id} was not renewed in three days of trying and the " <>
        "job is cancelled; others may have been too (fountain_chatgpt_keepalive_grant_count)"
    )

    finish(job, grant_id, :gave_up, {:cancel, :gave_up})
  end

  defp finish(job, grant_id, reason, result) do
    outcome = outcome(result, reason, job)

    :telemetry.execute([:fountain, :chatgpt, :keepalive, :grant], %{count: 1}, %{
      result: outcome,
      reason: reason
    })

    case outcome do
      :ok -> :ok
      :discarded -> discarded(grant_id, reason)
      _ -> Logger.info("chatgpt keepalive: grant #{grant_id} #{outcome} (#{reason})")
    end

    result
  end

  # Once a minute per node at most: an outage discards a job per grant, and
  # the counter's `discarded` says how many.
  defp discarded(grant_id, reason) do
    Fountain.LogThrottle.error(
      {:chatgpt_keepalive, :discarded},
      "chatgpt keepalive: grant #{grant_id} was not renewed and the job is discarded " <>
        "(#{reason}); the next sweep queues it again if it is still due. Others may have " <>
        "been too (fountain_chatgpt_keepalive_grant_count)"
    )
  end

  defp last_attempt?(%Oban.Job{attempt: attempt, max_attempts: max})
       when is_integer(attempt) and is_integer(max),
       do: attempt >= max

  defp last_attempt?(_job), do: false

  defp outcome(:ok, _reason, _job), do: :ok
  defp outcome({:cancel, _}, _reason, _job), do: :cancelled
  defp outcome({:snooze, _}, :rate_limited, _job), do: :rate_limited
  defp outcome({:snooze, _}, _reason, _job), do: :snoozed

  defp outcome({:error, _}, _reason, job),
    do: if(last_attempt?(job), do: :discarded, else: :error)

  # Clocks and a count the job keeps about itself, in `meta`, on the row and
  # on the struct: `remember/3` writes one once, `restart/2` writes some over
  # and `forget/2` takes one away. A job that is not a row (a test's) keeps
  # them for the one run.
  defp remember(%Oban.Job{meta: %{} = meta} = job, key, value) do
    if is_integer(meta[key]), do: job, else: restart(job, %{key => value})
  end

  defp remember(%Oban.Job{} = job, key, value), do: remember(%{job | meta: %{}}, key, value)

  defp restart(%Oban.Job{meta: meta} = job, %{} = changes) do
    if is_integer(job.id) do
      from(j in Oban.Job,
        where: j.id == ^job.id,
        update: [set: [meta: fragment("? || ?", j.meta, ^changes)]]
      )
      |> Fountain.Repo.update_all([])
    end

    %{job | meta: Map.merge(meta, changes)}
  end

  defp forget(%Oban.Job{meta: %{} = meta} = job, key) when is_map_key(meta, key) do
    if is_integer(job.id) do
      from(j in Oban.Job,
        where: j.id == ^job.id,
        update: [set: [meta: fragment("? - ?", j.meta, type(^key, :string))]]
      )
      |> Fountain.Repo.update_all([])
    end

    %{job | meta: Map.delete(meta, key)}
  end

  defp forget(job, _key), do: job

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
