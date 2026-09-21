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
  server turned this server's address away, a job snoozes until it clears
  without calling. The job that was refused is retried like any other error,
  and its retry finds the breaker standing too.

  A snooze raises the job's `attempt`, and Oban's default backoff grows with
  it, so `backoff/1` is bounded (ADR 0060, "Stage 4a as built", after
  review). And a job gives way to the next day's sweep rather than snoozing
  without end: past `@give_up_seconds` since it was queued it is cancelled,
  and the sweep queues the grant again if it is still due.

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

  @impl Oban.Worker
  def perform(%Oban.Job{args: args} = job) do
    with {:ok, grant_id, user_id, generation} <- identity(args) do
      cond do
        gave_up?(job) -> finish(grant_id, :gave_up, {:cancel, :gave_up})
        RefreshBreaker.open?() -> finish(grant_id, :breaker_open, {:snooze, breaker_snooze()})
        true -> renew(grant_id, user_id, generation)
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

  defp renew(grant_id, user_id, generation) do
    case ChatGPTAccounts.refresh_for_user(grant_id, user_id, generation) do
      :ok ->
        finish(grant_id, :ok, :ok)

      {:error, reason} when reason in @terminal ->
        finish(grant_id, reason, {:cancel, reason})

      {:error, reason} when reason in @crowded ->
        finish(grant_id, reason, {:snooze, 60 + :rand.uniform(60)})

      {:error, reason} when is_atom(reason) ->
        finish(grant_id, reason, {:error, reason})
    end
  end

  defp finish(grant_id, reason, result) do
    outcome = outcome(result)

    :telemetry.execute([:fountain, :chatgpt, :keepalive, :grant], %{count: 1}, %{
      result: outcome,
      reason: reason
    })

    if outcome != :ok,
      do: Logger.info("chatgpt keepalive: grant #{grant_id} #{outcome} (#{reason})")

    result
  end

  defp outcome(:ok), do: :ok
  defp outcome({:cancel, _}), do: :cancelled
  defp outcome({:snooze, _}), do: :snoozed
  defp outcome({:error, :rate_limited}), do: :rate_limited
  defp outcome({:error, _}), do: :error

  defp breaker_snooze, do: RefreshBreaker.remaining_seconds() + :rand.uniform(120)

  defp gave_up?(%Oban.Job{inserted_at: %DateTime{} = at}),
    do: DateTime.diff(DateTime.utc_now(), at) > @give_up_seconds

  defp gave_up?(_job), do: false

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
