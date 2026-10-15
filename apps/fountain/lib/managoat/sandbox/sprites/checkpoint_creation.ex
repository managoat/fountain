defmodule Managoat.Sandbox.Sprites.CheckpointCreation do
  @moduledoc false

  alias Managoat.Sandbox.{Config, Sprites}
  alias Managoat.Sandbox.Sprites.Client

  @max_bytes 65_536

  def create(handle, opts) do
    timeout = Keyword.get(opts, :timeout_ms, 30_000)
    operation_id = Keyword.get(opts, :operation_id)

    cond do
      not (is_integer(timeout) and timeout in 1..120_000) ->
        {:error, {:invalid, :checkpoint_timeout}}

      not (is_binary(operation_id) and Regex.match?(~r/\A[A-Za-z0-9_-]{1,128}\z/, operation_id)) ->
        {:error, {:invalid, :checkpoint_operation_id}}

      Keyword.keys(opts) -- [:timeout_ms, :operation_id] != [] ->
        {:error, {:invalid, :checkpoint_options}}

      not Config.get(Sprites, :checkpoint_creation_enabled, false) ->
        {:error, :not_supported}

      true ->
        run(Client.get!(), handle.name, "sandbox-operation:#{operation_id}", timeout)
    end
  end

  defp run(client, name, comment, timeout) do
    task =
      Task.async(fn ->
        receive do
          :start -> timed_request(client, name, comment, timeout)
        after
          timeout -> {:error, {:unavailable, :checkpoint_timeout}}
        end
      end)

    # The child timer survives caller loss; use an unlinked monitor while waiting
    # so its hard deadline is an opaque uncertain result, not a caller exit.
    Process.unlink(task.pid)
    send(task.pid, :start)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      _ -> {:error, {:unavailable, :checkpoint_timeout}}
    end
  end

  defp timed_request(client, name, comment, timeout) do
    {:ok, timer} = :timer.kill_after(timeout)

    try do
      request(client, name, comment, timeout)
    after
      :timer.cancel(timer)
    end
  end

  defp request(client, name, comment, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    budget = :atomics.new(1, [])
    path = "/v1/sprites/" <> URI.encode(name, &URI.char_unreserved?/1)
    opts = request_options(deadline, budget)

    with {:ok, %{status: 200, body: body}} when is_binary(body) <-
           Req.post(client.req, [url: path <> "/checkpoint", json: %{comment: comment}] ++ opts),
         true <- complete_stream?(body),
         {:ok, %{status: 200, body: listing}} when is_binary(listing) <-
           Req.get(client.req, [url: path <> "/checkpoints"] ++ request_options(deadline, budget)),
         {:ok, checkpoints} when is_list(checkpoints) <- Jason.decode(listing),
         true <- Enum.all?(checkpoints, &valid_checkpoint?/1),
         [%{"id" => id}] when is_binary(id) and byte_size(id) in 1..256 <-
           Enum.filter(checkpoints, &matching_checkpoint?(&1, comment)) do
      {:ok, id}
    else
      _ -> {:error, {:unavailable, :checkpoint_unconfirmed}}
    end
  rescue
    _ -> {:error, {:unavailable, :checkpoint_transport_failed}}
  catch
    _, _ -> {:error, {:unavailable, :checkpoint_transport_failed}}
  end

  defp request_options(deadline, budget) do
    remaining = deadline - System.monotonic_time(:millisecond)
    if remaining <= 0, do: throw(:deadline_expired)

    [
      retry: false,
      redirect: false,
      decode_body: false,
      compressed: false,
      receive_timeout: remaining,
      connect_options: [protocols: [:http1]],
      into: fn {:data, data}, {request, response} ->
        used = :atomics.add_get(budget, 1, byte_size(data))

        if used <= @max_bytes,
          do: {:cont, {request, %{response | body: (response.body || "") <> data}}},
          else: {:halt, {request, %{response | body: :too_large}}}
      end
    ]
  end

  # The provider documents info/error/complete NDJSON events. IDs in their
  # human-readable data are not authority; the separate exact-comment list is.
  defp complete_stream?(body) do
    body
    |> String.split("\n", trim: true)
    |> Enum.reduce_while(:pending, fn line, state ->
      case {state, Jason.decode(line)} do
        {:pending, {:ok, %{"type" => "info", "data" => data} = frame}} when is_binary(data) ->
          if Map.has_key?(frame, "error"), do: {:halt, :invalid}, else: {:cont, :pending}

        {:pending, {:ok, %{"type" => "complete", "data" => data} = frame}} when is_binary(data) ->
          if Map.has_key?(frame, "error"), do: {:halt, :invalid}, else: {:cont, :complete}

        _ ->
          {:halt, :invalid}
      end
    end)
    |> Kernel.==(:complete)
  end

  defp valid_checkpoint?(%{"id" => id} = checkpoint) do
    is_binary(id) and byte_size(id) in 1..256 and
      (is_nil(checkpoint["comment"]) or is_binary(checkpoint["comment"]))
  end

  defp valid_checkpoint?(_), do: false

  defp matching_checkpoint?(%{"id" => id, "comment" => comment}, comment),
    do: is_binary(id) and id != "Current"

  defp matching_checkpoint?(_, _), do: false
end
