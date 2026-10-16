defmodule RemoteBroker.Events do
  @moduledoc "Bounded, best-effort terminal egress delivery, matching the home request log."
  use GenServer
  require Logger

  def start_link(_opts), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  def attach do
    :telemetry.attach(
      "remote-broker-events",
      [:managoat, :broker, :request],
      &__MODULE__.record/4,
      nil
    )
  end

  def record(_event, measurements, meta, _config) do
    receipt = get_in(meta, [:meta, "receipt"])

    if is_binary(receipt) do
      # No paths, targets, headers, bodies, tokens, or raw errors cross this sink.
      event = %{
        receipt: receipt,
        method: meta.method,
        host: meta.host,
        outcome: outcome(meta),
        service: service(meta),
        status: meta[:status],
        latency_ms: System.convert_time_unit(measurements.duration, :native, :millisecond),
        failed: not is_nil(meta[:error])
      }

      if :ets.update_counter(__MODULE__, :size, 1) <= 5_000 do
        :ets.insert(__MODULE__, {System.unique_integer([:positive, :monotonic]), event})
      else
        :ets.update_counter(__MODULE__, :size, -1)
        Logger.warning("remote broker: egress buffer full, dropped=1")
      end
    end

    :ok
  rescue
    _ -> :ok
  end

  defp outcome(%{outcome: :injected, scheme: :passthrough}), do: "passthrough"

  defp outcome(%{outcome: value}) when value in [:injected, :passthrough, :denied],
    do: Atom.to_string(value)

  defp outcome(_), do: "error"

  defp service(%{outcome: :injected, scheme: scheme, rule: rule}) when scheme != :passthrough,
    do: rule

  defp service(_), do: nil

  @impl true
  def init(_) do
    :ets.new(__MODULE__, [:named_table, :public, :ordered_set, write_concurrency: true])
    :ets.insert(__MODULE__, {:size, 0})
    Process.send_after(self(), :flush, 1_000)
    {:ok, nil}
  end

  @impl true
  def handle_info(:flush, state) do
    # Small batches stay under the home's 64 KiB body limit even with receipts.
    batch = take(20, [], 60_000)

    if batch != [] do
      case RemoteBroker.Control.request("events", %{events: batch}) do
        {:ok, %{status: 200}} -> :ok
        _ -> Logger.warning("remote broker: egress delivery failed, dropped=#{length(batch)}")
      end
    end

    delay = if :ets.lookup_element(__MODULE__, :size, 2) > 0, do: 0, else: 1_000
    Process.send_after(self(), :flush, delay)
    {:noreply, state}
  end

  defp take(0, rows, _budget), do: Enum.reverse(rows)

  defp take(n, rows, budget) do
    case :ets.first(__MODULE__) do
      key when is_integer(key) ->
        [{^key, row}] = :ets.lookup(__MODULE__, key)
        bytes = byte_size(Jason.encode!(row)) + 1

        cond do
          bytes > 60_000 ->
            :ets.delete(__MODULE__, key)
            :ets.update_counter(__MODULE__, :size, -1)
            Logger.warning("remote broker: oversized egress event, dropped=1")
            take(n - 1, rows, budget)

          bytes > budget ->
            Enum.reverse(rows)

          true ->
            :ets.delete(__MODULE__, key)
            :ets.update_counter(__MODULE__, :size, -1)
            take(n - 1, [row | rows], budget - bytes)
        end

      _ ->
        Enum.reverse(rows)
    end
  end
end
