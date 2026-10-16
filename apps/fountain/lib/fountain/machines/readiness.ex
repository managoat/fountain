defmodule Fountain.Machines.Readiness do
  @moduledoc false

  # Sprites resume is a lookup: only an exec wakes the machine. A handshake can
  # fail before a cold boot finishes, so retry within one overall deadline.
  @timeout_ms 60_000
  @attempt_ms 10_000
  @retry_ms 250

  def wait(%Managoat.Sandbox.Handle{provider: :sprites} = handle, opts) do
    deadline = now() + Keyword.get(opts, :readiness_timeout_ms, @timeout_ms)
    retry_ms = Keyword.get(opts, :readiness_retry_ms, @retry_ms)
    probe(handle, deadline, retry_ms)
  end

  def wait(%Managoat.Sandbox.Handle{}, _opts), do: :ok

  defp probe(handle, deadline, retry_ms) do
    case deadline - now() do
      remaining when remaining > 0 ->
        result = exec(handle, min(remaining, @attempt_ms))

        if now() >= deadline do
          {:error, :readiness_timeout}
        else
          case result do
            {:ok, _output, 0} -> :ok
            {:ok, _output, code} -> {:error, {:readiness_exit, code}}
            {:error, reason} -> retry(handle, deadline, retry_ms, reason)
          end
        end

      _ ->
        {:error, :readiness_timeout}
    end
  end

  defp retry(handle, deadline, retry_ms, reason) do
    if Managoat.Sandbox.Retry.transient?(reason) do
      Process.sleep(min(retry_ms, max(deadline - now(), 0)))
      probe(handle, deadline, retry_ms)
    else
      {:error, reason}
    end
  end

  # Keep exec in the lease owner: killing only its caller can orphan the
  # SDK's unlinked command process. The adapter cancels on collection timeout.
  # Its synchronous SDK startup can overrun this budget (10s connect, 10s
  # upgrade, and a 5s inactivity timeout while reading an error body). Never
  # retry or accept a late success after startup has consumed the budget.
  defp exec(handle, timeout) do
    Managoat.Sandbox.exec(handle, "true", [], timeout: timeout)
  rescue
    error -> {:error, {:unavailable, Exception.message(error)}}
  catch
    :exit, reason -> {:error, {:unavailable, reason}}
  end

  defp now, do: System.monotonic_time(:millisecond)
end
