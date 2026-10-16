defmodule Fountain.Broker.Native.Diagnostics do
  @moduledoc """
  Operator logs for CONNECT attempts, including attempts that never reach HTTP.

  The broker's observer emits setup timings and samples outstanding transfers
  independently of its relay. These are connection totals, not request TTFB or
  bandwidth metrics. Keep IDs in logs, never in Prometheus labels. The existing
  terminal request log remains the user-facing egress record.
  """

  require Logger

  @handler "fountain-broker-native-diagnostics"
  @durations ~w(duration first_byte upstream_idle client_write_duration client_write_in_flight)a
  @counts ~w(upstream_bytes client_bytes pending_requests requests)a
  @fields ~w(event phase outcome reason client_writing request_id)a

  @doc false
  def attach do
    case :telemetry.attach(@handler, [:managoat, :broker, :diagnostic], &__MODULE__.handle/4, nil) do
      :ok -> :ok
      {:error, :already_exists} -> :ok
    end
  end

  @doc false
  def handle(_event, measurements, meta, _config) do
    timings =
      for key <- @durations, value = Map.get(measurements, key), is_integer(value), into: %{} do
        {"#{key}_ms", System.convert_time_unit(value, :native, :millisecond)}
      end

    fields = meta |> Map.take(@fields) |> Map.merge(Map.take(measurements, @counts))
    conv = get_in(meta, [:meta, "conversation_id"])

    # No URL, path, headers, body, raw error or wholesale session metadata.
    Logger.info(
      "broker: diagnostic conv #{conv || "?"} connection #{meta.connection_id} " <>
        "host #{meta.host}:#{meta.port} #{inspect(Map.merge(fields, timings))}"
    )

    :ok
  rescue
    _ ->
      # A malformed event must not detach the handler or disclose its contents.
      Logger.warning("broker: diagnostic event skipped")
      :ok
  end
end
