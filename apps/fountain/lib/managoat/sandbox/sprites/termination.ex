defmodule Managoat.Sandbox.Sprites.Termination do
  @moduledoc false

  alias Managoat.Sandbox.Sprites.{Client, Errors}

  @max_bytes 16_384
  @transport_grace_ms 5_000

  # The SDK's stop closes this node's WebSocket. The provider kill endpoint
  # targets the remote process group. Graceful stop can finish when its parent
  # exits, before a TERM-resistant child does. Force stop kills the group first.
  # https://docs.sprites.dev/api/dev-latest/exec/#kill-exec-session
  def terminate(name, session_id, timeout_ms, mode \\ :graceful) do
    client = Client.get!()
    path = "/v1/sprites/#{segment(name)}/exec/#{segment(session_id)}/kill"

    task =
      Task.async(fn ->
        try do
          client.req
          |> Req.post(
            url: path,
            params: [signal: signal(mode), timeout: "#{timeout_ms}ms"],
            retry: false,
            redirect: false,
            decode_body: false,
            compressed: false,
            receive_timeout: timeout_ms + @transport_grace_ms,
            into: &collect/2
          )
          |> result(mode)
        rescue
          _ -> {:error, {:unavailable, :termination_transport_failed}}
        catch
          _, _ -> {:error, {:unavailable, :termination_transport_failed}}
        end
      end)

    case Task.yield(task, timeout_ms + @transport_grace_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      _ -> {:error, {:unavailable, :termination_timeout}}
    end
  end

  defp segment(value), do: URI.encode(value, &URI.char_unreserved?/1)
  defp signal(:graceful), do: "SIGTERM"
  defp signal(:force), do: "SIGKILL"

  defp collect({:data, data}, {request, response}) do
    body = response.body || ""

    if byte_size(body) + byte_size(data) <= @max_bytes do
      {:cont, {request, %{response | body: body <> data}}}
    else
      {:halt, {request, %{response | body: :too_large}}}
    end
  end

  defp result({:ok, %{status: 404}}, :graceful), do: :ok

  defp result({:ok, %{status: 404}}, :force),
    do: {:error, {:unavailable, :termination_unconfirmed}}

  defp result({:ok, %{status: 200, body: body}}, mode) when is_binary(body) do
    with true <- byte_size(body) <= @max_bytes,
         lines when lines != [] <- String.split(body, "\n", trim: true),
         {:ok, events} <- decode(lines),
         true <- terminated?(events),
         true <- signal_confirmed?(events, mode) do
      :ok
    else
      _ -> {:error, {:unavailable, :termination_unconfirmed}}
    end
  end

  defp result({:ok, %{status: 200}}, _mode),
    do: {:error, {:unavailable, :termination_unconfirmed}}

  # Provider prose is not needed to classify the failure and can contain
  # private command details. Do not return it to the host's logs.
  defp result({:ok, %{status: status}}, _mode),
    do: {:error, Errors.normalize({:api_error, status, %{}})}

  defp result({:error, _}, _mode), do: {:error, {:unavailable, :termination_transport_failed}}

  defp signal_confirmed?(_events, :graceful), do: true

  defp signal_confirmed?(events, :force) do
    Enum.any?(events, fn
      %{"type" => "signal", "signal" => "SIGKILL", "pid" => pid}
      when is_integer(pid) and pid > 0 ->
        true

      _ ->
        false
    end)
  end

  defp decode(lines) do
    Enum.reduce_while(lines, {:ok, []}, fn line, {:ok, events} ->
      case Jason.decode(line) do
        {:ok, %{} = event} -> {:cont, {:ok, [event | events]}}
        _ -> {:halt, :error}
      end
    end)
  end

  # Events are reversed. Require a final complete frame, affirmative process
  # termination, and no errors/unknown frames. HTTP 200 or a sent signal alone
  # says nothing about whether the process stopped. This is never test evidence.
  defp terminated?([%{"type" => "complete", "exit_code" => code} | progress])
       when is_integer(code) and code >= 0 and code <= 255 do
    Enum.any?(progress, &(&1["type"] in ["exited", "killed"])) and
      Enum.all?(progress, &(&1["type"] in ["signal", "timeout", "exited", "killed"]))
  end

  defp terminated?(_), do: false
end
