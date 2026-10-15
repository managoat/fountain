defmodule Managoat.Sandbox.Sprites.Creation do
  @moduledoc false

  alias Managoat.Sandbox.Handle
  alias Managoat.Sandbox.Sprites.{Client, Errors}

  @max_bytes 65_536
  @default_timeout_ms 120_000

  def create(name, opts) do
    timeout = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    wait = Keyword.get(opts, :wait_for_capacity, false)

    cond do
      not (is_integer(timeout) and timeout in 1..@default_timeout_ms) ->
        {:error, {:invalid, :create_timeout}}

      not is_boolean(wait) or Keyword.keys(opts) -- [:timeout_ms, :wait_for_capacity] != [] ->
        {:error, {:invalid, :create_options}}

      true ->
        client = Client.get!()
        public? = Managoat.Sandbox.Config.get(Managoat.Sandbox.Sprites, :public_urls, true)

        body = %{
          name: name,
          wait_for_capacity: wait,
          url_settings: %{auth: if(public?, do: "public", else: "sprite")}
        }

        task = Task.async(fn -> request(client, name, body, timeout) end)

        case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
          {:ok, result} -> result
          _ -> {:error, {:unavailable, :create_timeout}}
        end
    end
  end

  defp request(client, name, body, timeout) do
    client.req
    |> Req.post(
      url: "/v1/sprites",
      json: body,
      retry: false,
      redirect: false,
      decode_body: false,
      compressed: false,
      receive_timeout: timeout,
      into: &collect/2
    )
    |> result(name)
  rescue
    _ -> {:error, {:unavailable, :create_transport_failed}}
  catch
    _, _ -> {:error, {:unavailable, :create_transport_failed}}
  end

  defp collect({:data, data}, {request, response}) do
    body = response.body || ""

    if byte_size(body) + byte_size(data) <= @max_bytes do
      {:cont, {request, %{response | body: body <> data}}}
    else
      {:halt, {request, %{response | body: :too_large}}}
    end
  end

  defp result({:ok, %{status: 409}}, _), do: {:error, :already_exists}

  defp result({:ok, %{status: status, body: body}}, name) when status in 200..299 do
    with true <- is_binary(body) and byte_size(body) <= @max_bytes,
         {:ok, %{"name" => ^name, "id" => id}} <- Jason.decode(body),
         true <- is_binary(id) and byte_size(id) in 1..256 do
      {:ok, %Handle{provider: :sprites, name: name, instance_id: id}}
    else
      _ -> {:error, {:unavailable, :create_unconfirmed}}
    end
  end

  defp result({:ok, %{status: status}}, _),
    do: {:error, Errors.normalize({:api_error, status, %{}})}

  defp result({:error, _}, _), do: {:error, {:unavailable, :create_transport_failed}}
end
