defmodule Fountain.Workers.ChatGPTGrantKeepalive do
  @moduledoc """
  Renews one pinned user grant through the shared coordinator (ADR 0052).

  The context rechecks ownership, eligibility, generation and renewal timing.
  Disconnect/reconnect or an already-renewed grant therefore makes stale work
  harmless. Terminal or unusable grants stop here; transient failures use
  Oban's exponential backoff with jitter, up to five attempts. No credential
  or provider response appears in job arguments or returned errors.
  """

  use Oban.Worker,
    queue: :chatgpt_refresh,
    max_attempts: 5,
    unique: [
      period: :infinity,
      fields: [:worker, :args],
      keys: [:user_id, :grant_id, :generation],
      states: :incomplete
    ]

  @terminal_errors ~w(not_connected stale_grant revoked expired invalid_grant account_mismatch undecryptable not_found unwrap_failed no_token)a

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    with {:ok, grant_id, user_id, generation} <- identity(args) do
      case Fountain.ChatGPTAccounts.refresh_for_user(grant_id, user_id, generation) do
        :ok -> :ok
        {:error, reason} when reason in @terminal_errors -> {:cancel, reason}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @impl Oban.Worker
  def timeout(_job), do: 35_000

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
