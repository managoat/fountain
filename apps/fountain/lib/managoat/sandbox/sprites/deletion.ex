defmodule Managoat.Sandbox.Sprites.Deletion do
  @moduledoc false

  alias Managoat.Sandbox.Sprites.Client

  @max_bytes 65_536
  @max_timeout_ms 120_000

  def destroy(handle, opts) do
    timeout = Keyword.get(opts, :timeout_ms, 30_000)

    cond do
      not (is_integer(timeout) and timeout in 1..@max_timeout_ms) ->
        {:error, {:invalid, :delete_timeout}}

      Keyword.keys(opts) -- [:timeout_ms] != [] ->
        {:error, {:invalid, :delete_options}}

      true ->
        client = Client.get!()
        task = Task.async(fn -> request(client, handle.name, timeout) end)

        case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
          {:ok, result} -> result
          _ -> {:error, {:unavailable, :delete_timeout}}
        end
    end
  end

  defp request(client, name, timeout) do
    opts = [
      url: "/v1/sprites/" <> URI.encode(name, &URI.char_unreserved?/1),
      retry: false,
      redirect: false,
      decode_body: false,
      compressed: false,
      receive_timeout: timeout,
      into: &collect/2
    ]

    case Req.delete(client.req, opts) do
      {:ok, %{status: 404}} -> :ok
      {:ok, %{status: status}} when status in 200..299 -> confirm_absence(client, opts)
      _ -> {:error, {:unavailable, :delete_unconfirmed}}
    end
  rescue
    _ -> {:error, {:unavailable, :delete_transport_failed}}
  catch
    _, _ -> {:error, {:unavailable, :delete_transport_failed}}
  end

  # A successful HTTP write, including 202, is not evidence the machine is gone.
  # One bounded read can confirm absence; it never grants another DELETE.
  defp confirm_absence(client, opts) do
    case Req.get(client.req, opts) do
      {:ok, %{status: 404}} -> :ok
      _ -> {:error, {:unavailable, :delete_unconfirmed}}
    end
  end

  defp collect({:data, data}, {request, response}) do
    body = response.body || ""

    if byte_size(body) + byte_size(data) <= @max_bytes do
      {:cont, {request, %{response | body: body <> data}}}
    else
      {:halt, {request, %{response | body: :too_large}}}
    end
  end
end
