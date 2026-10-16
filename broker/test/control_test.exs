defmodule RemoteBroker.ControlTest do
  use ExUnit.Case, async: false

  setup do
    previous =
      Map.new([:control_url, :token, :request_options], fn key ->
        {key, Application.fetch_env(:remote_broker, key)}
      end)

    on_exit(fn ->
      for {key, value} <- previous do
        case value do
          {:ok, value} -> Application.put_env(:remote_broker, key, value)
          :error -> Application.delete_env(:remote_broker, key)
        end
      end
    end)

    Application.put_env(:remote_broker, :token, "test-control-token")
    Application.delete_env(:remote_broker, :request_options)
    :ok
  end

  test "real transport accepts bounded pool and connection options" do
    server = serve("200 OK", "content-type: application/json\r\n", ~s({"rules":[]}))

    assert {:ok, %{status: 200, body: %{"rules" => []}}} =
             RemoteBroker.Control.request("authorize", %{authorization: "test-session"})

    assert :ok = Task.await(server)
  end

  test "real transport does not follow control redirects" do
    server = serve("302 Found", "location: http://127.0.0.1:1/forbidden\r\n", "")
    assert {:ok, %{status: 302}} = RemoteBroker.Control.request("authorize", %{})
    assert :ok = Task.await(server)
  end

  defp serve(status, headers, body) do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, {_, port}} = :inet.sockname(listener)
    on_exit(fn -> :gen_tcp.close(listener) end)
    Application.put_env(:remote_broker, :control_url, "http://127.0.0.1:#{port}")

    Task.async(fn ->
      {:ok, socket} = :gen_tcp.accept(listener, 2_000)

      try do
        request = receive_headers(socket, "")
        assert request =~ "POST /internal/broker/v1/authorize HTTP/1.1"
        assert String.downcase(request) =~ "authorization: bearer test-control-token"

        :gen_tcp.send(
          socket,
          "HTTP/1.1 #{status}\r\n#{headers}content-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n#{body}"
        )
      after
        :gen_tcp.close(socket)
      end
    end)
  end

  defp receive_headers(socket, acc) do
    if String.contains?(acc, "\r\n\r\n") do
      acc
    else
      {:ok, data} = :gen_tcp.recv(socket, 0, 2_000)
      receive_headers(socket, acc <> data)
    end
  end
end
