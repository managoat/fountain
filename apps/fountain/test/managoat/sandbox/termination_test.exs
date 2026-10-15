defmodule Managoat.Sandbox.TerminationTest do
  use ExUnit.Case, async: true
  use Mimic

  alias Managoat.Sandbox
  alias Managoat.Sandbox.Sprites, as: Adapter

  defp handle, do: Adapter.build_handle("owned-worker")

  defp client(plug) do
    req = Req.new(base_url: "https://provider.invalid", plug: plug)
    stub(Managoat.Sandbox.Sprites.Client, :get!, fn -> %Sprites.Client{req: req} end)
  end

  defp body(events), do: Enum.map_join(events, "\n", &Jason.encode!/1) <> "\n"

  defp acknowledged(code \\ 137),
    do:
      body([
        %{type: "signal"},
        %{type: "timeout"},
        %{type: "killed"},
        %{type: "complete", exit_code: code}
      ])

  test "remote stop requires acknowledgement, preserves the target, and disables replay" do
    owner = self()

    client(fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      send(owner, {:request, conn.method, conn.request_path, conn.query_params})
      Plug.Conn.send_resp(conn, 200, acknowledged())
    end)

    assert :ok = Sandbox.terminate_session(handle(), "17", timeout_ms: 1000)

    assert_receive {:request, "POST", "/v1/sprites/owned-worker/exec/17/kill",
                    %{"signal" => "SIGTERM", "timeout" => "1000ms"}}

    refute_receive {:request, _, _, _}
  end

  test "graceful and already-absent sessions are confirmed without command success claims" do
    client(fn conn ->
      Plug.Conn.send_resp(conn, 200, body([%{type: "exited"}, %{type: "complete", exit_code: 0}]))
    end)

    assert :ok = Adapter.terminate_session(handle(), "17", [])
    client(fn conn -> Plug.Conn.send_resp(conn, 404, "absent") end)
    assert :ok = Adapter.terminate_session(handle(), "17", [])
  end

  test "force stop sends SIGKILL once and requires its affirmative completion" do
    owner = self()

    client(fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      send(owner, {:force_request, conn.method, conn.request_path, conn.query_params})

      Plug.Conn.send_resp(
        conn,
        200,
        body([
          %{type: "signal", signal: "SIGKILL", pid: 17},
          %{type: "exited"},
          %{type: "complete", exit_code: 137}
        ])
      )
    end)

    assert :ok = Sandbox.terminate_session(handle(), "17", mode: :force, timeout_ms: 500)

    assert_receive {:force_request, "POST", "/v1/sprites/owned-worker/exec/17/kill",
                    %{"signal" => "SIGKILL", "timeout" => "500ms"}}

    refute_receive {:force_request, _, _, _}
  end

  test "force stop cannot treat a missing parent session as absence of descendants" do
    client(fn conn -> Plug.Conn.send_resp(conn, 404, "absent") end)

    assert {:error, {:unavailable, :termination_unconfirmed}} =
             Sandbox.terminate_session(handle(), "17", mode: :force)
  end

  test "force mode refuses a legacy adapter before it can ignore the new option" do
    stub(Adapter, :capabilities, fn -> MapSet.new([:terminate_session]) end)
    reject(Adapter, :terminate_session, 3)

    assert {:error, :not_supported} =
             Sandbox.terminate_session(handle(), "17", mode: :force)
  end

  for signal <- [nil, "SIGTERM", "SIGKILL"] do
    test "force stop refuses incomplete signal evidence #{inspect(signal)}" do
      client(fn conn ->
        Plug.Conn.send_resp(
          conn,
          200,
          body([
            %{type: "signal", signal: unquote(signal)},
            %{type: "exited"},
            %{type: "complete", exit_code: 0}
          ])
        )
      end)

      assert {:error, {:unavailable, :termination_unconfirmed}} =
               Adapter.terminate_session(handle(), "17", mode: :force)
    end
  end

  for {label, response} <- [
        {"empty", ""},
        {"signal only", "{\"type\":\"signal\"}\n"},
        {"completion only", "{\"type\":\"complete\",\"exit_code\":0}\n"},
        {"no completion", "{\"type\":\"killed\"}\n"},
        {"malformed", "not JSON"},
        {"non-object", "[]\n"},
        {"missing code", "{\"type\":\"killed\"}\n{\"type\":\"complete\"}\n"},
        {"error then complete",
         "{\"type\":\"error\"}\n{\"type\":\"killed\"}\n{\"type\":\"complete\",\"exit_code\":0}\n"},
        {"unknown event",
         "{\"type\":\"unknown\"}\n{\"type\":\"killed\"}\n{\"type\":\"complete\",\"exit_code\":0}\n"},
        {"trailing event",
         "{\"type\":\"killed\"}\n{\"type\":\"complete\",\"exit_code\":0}\n{\"type\":\"signal\"}\n"},
        {"oversized", String.duplicate("x", 16_385)}
      ] do
    test "#{label} is uncertain despite HTTP 200" do
      response = unquote(response)
      client(fn conn -> Plug.Conn.send_resp(conn, 200, response) end)

      assert {:error, {:unavailable, :termination_unconfirmed}} =
               Adapter.terminate_session(handle(), "17", [])
    end
  end

  for code <- [-1, 256, 1.5, "137"] do
    test "invalid completion code #{inspect(code)} is refused" do
      client(fn conn -> Plug.Conn.send_resp(conn, 200, acknowledged(unquote(code))) end)

      assert {:error, {:unavailable, :termination_unconfirmed}} =
               Adapter.terminate_session(handle(), "17", [])
    end
  end

  for {status, expected} <- [
        {401, {:denied, {:http, 401, %{}}}},
        {429, {:rate_limited, nil}},
        {503, {:unavailable, {:http, 503, %{}}}},
        {302, {:invalid, {:http, 302, %{}}}}
      ] do
    test "HTTP #{status} is not retried or treated as a confirmed kill" do
      owner = self()

      client(fn conn ->
        send(owner, :write)

        conn
        |> Plug.Conn.put_resp_header("location", "https://elsewhere.invalid")
        |> Plug.Conn.send_resp(unquote(status), "private provider detail")
      end)

      assert {:error, unquote(Macro.escape(expected))} =
               Adapter.terminate_session(handle(), "17", [])

      assert_receive :write
      refute_receive :write
    end
  end

  test "a stalled provider is bounded independently of incoming progress" do
    owner = self()

    client(fn _conn ->
      send(owner, {:transport, self()})
      Process.sleep(:infinity)
    end)

    started = System.monotonic_time(:millisecond)

    assert {:error, {:unavailable, :termination_timeout}} =
             Adapter.terminate_session(handle(), "17", timeout_ms: 1)

    assert System.monotonic_time(:millisecond) - started < 6500
    assert_receive {:transport, pid}
    refute Process.alive?(pid)
  end

  test "a transport exception is sanitized and never replayed" do
    client(fn _conn -> raise "private detail" end)

    assert {:error, {:unavailable, :termination_transport_failed}} =
             Adapter.terminate_session(handle(), "17", [])
  end

  test "invalid targets and options are refused before a provider call" do
    reject(Managoat.Sandbox.Sprites.Client, :get!, 0)

    for id <- ["", "../other", "a/b", "a?x=1", String.duplicate("a", 257), nil] do
      assert {:error, {:invalid, :termination_request}} = Sandbox.terminate_session(handle(), id)

      assert {:error, {:invalid, :termination_request}} =
               Adapter.terminate_session(handle(), id, [])
    end

    for opts <- [
          [timeout_ms: 0],
          [timeout_ms: 30_001],
          [timeout_ms: 1.5],
          [signal: "KILL"],
          [mode: :unknown],
          [mode: :force, mode: :graceful],
          [timeout_ms: 1, timeout_ms: 2],
          %{}
        ] do
      assert {:error, {:invalid, :termination_request}} =
               Sandbox.terminate_session(handle(), "17", opts)
    end
  end

  test "unsupported providers refuse rather than destroying a shared machine" do
    assert {:error, :not_supported} =
             Sandbox.terminate_session(Sandbox.build_handle(:e2b, "shared"), "17")
  end
end
