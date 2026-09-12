defmodule Fountain.ChatGPTAccounts.RefreshLock do
  @moduledoc """
  Cross-node exclusion for a grant's upstream refresh.

  Only the holder keeps a database checkout across the provider request.
  Contenders try a transaction-scoped advisory lock and release the checkout
  before backing off. The transaction releases its lock on commit, rollback,
  connection loss or worker death; no session lock can leak into the pool.

  The callback must re-read the grant and fence its writes. It must not take
  a grant row lock before contacting the provider or emit best-effort audit
  events inside the transaction. Its result is returned only after commit.
  A provider rotation followed by a crash before commit still needs reconnect:
  database exclusion cannot make an external token exchange atomic.
  """

  alias Fountain.Repo

  # Separate from connection, admission and quota locks. Hash collisions only
  # serialize unrelated grants; they cannot weaken mutual exclusion.
  @namespace 52_001
  @wait_timeout 5_000
  @transaction_timeout 20_000

  @doc false
  def run(grant_id, fun, opts \\ []) when is_binary(grant_id) and is_function(fun, 0) do
    deadline = monotonic_ms() + Keyword.get(opts, :wait_timeout, @wait_timeout)
    timeout = Keyword.get(opts, :transaction_timeout, @transaction_timeout)
    attempt(:erlang.phash2(grant_id), fun, deadline, timeout)
  rescue
    DBConnection.ConnectionError -> {:error, :refresh_unavailable}
  end

  defp attempt(key, fun, deadline, timeout) do
    result =
      Repo.transaction(
        fn ->
          case Repo.query!("SELECT pg_try_advisory_xact_lock($1, $2)", [@namespace, key]) do
            %{rows: [[true]]} -> {:acquired, fun.()}
            %{rows: [[false]]} -> :busy
          end
        end,
        timeout: timeout
      )

    case result do
      {:ok, {:acquired, result}} ->
        result

      {:ok, :busy} ->
        # This event is outside the transaction, as is the bounded backoff.
        :telemetry.execute([:fountain, :chatgpt, :refresh_lock, :contention], %{count: 1}, %{})
        retry(key, fun, deadline, timeout)

      {:error, _reason} ->
        {:error, :refresh_unavailable}
    end
  end

  defp retry(key, fun, deadline, timeout) do
    remaining = deadline - monotonic_ms()

    if remaining > 0 do
      Process.sleep(min(remaining, 25 + :rand.uniform(50)))
      attempt(key, fun, deadline, timeout)
    else
      {:error, :refresh_busy}
    end
  end

  defp monotonic_ms, do: System.monotonic_time(:millisecond)
end
