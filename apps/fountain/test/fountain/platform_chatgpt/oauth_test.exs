defmodule Fountain.PlatformChatGPT.OAuthTest do
  # The device flow's legs against a socket, not a plug: what is held here is
  # a timeout, and `Req.Test` has none. `async: false`: the auth URL and the
  # Req options are application state.
  use ExUnit.Case, async: false

  alias Fountain.PlatformChatGPT.OAuth

  setup do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listener)
    old_url = Application.fetch_env(:fountain, :platform_chatgpt_auth_url)
    old_options = Application.fetch_env(:fountain, :platform_chatgpt_req_options)
    Application.put_env(:fountain, :platform_chatgpt_auth_url, "http://127.0.0.1:#{port}")
    Application.put_env(:fountain, :platform_chatgpt_req_options, [])

    # It takes the request and never says a word. Linked, so it ends with
    # the test.
    _server =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener)
        {:ok, _request} = :gen_tcp.recv(socket, 0, 2_000)
        Process.sleep(:infinity)
      end)

    on_exit(fn ->
      :gen_tcp.close(listener)
      restore_env(:platform_chatgpt_auth_url, old_url)
      restore_env(:platform_chatgpt_req_options, old_options)
    end)

    :ok
  end

  test "a poll of an auth server that stops answering gives up inside the refresh's ceiling" do
    started = System.monotonic_time(:millisecond)
    assert {:error, {:device_poll, _timeout}} = OAuth.device_poll("deviceauth_1", "CODE-1")
    elapsed = System.monotonic_time(:millisecond) - started

    # The lower bound says it waited; the upper is the one that matters: the
    # shared default would have held the queue's slot for fifteen seconds.
    assert elapsed >= 1_000
    assert elapsed < OAuth.refresh_timeout_ceiling_ms()
    assert elapsed < Application.get_env(:fountain, :connections_timeout_ms, 15_000)
  end

  defp restore_env(key, {:ok, value}), do: Application.put_env(:fountain, key, value)
  defp restore_env(key, :error), do: Application.delete_env(:fountain, key)
end
