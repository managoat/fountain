defmodule Managoat.Sandbox.DeletionTest do
  use ExUnit.Case, async: true
  use Mimic

  alias Managoat.Sandbox
  alias Managoat.Sandbox.Handle

  defp handle, do: %Handle{provider: :sprites, name: "owned-worker", instance_id: "opaque-id"}

  defp client(plug) do
    req = Req.new(base_url: "https://provider.invalid", plug: plug, retry: :transient)
    stub(Managoat.Sandbox.Sprites.Client, :get!, fn -> %Sprites.Client{req: req} end)
  end

  for status <- [200, 202, 204] do
    test "HTTP #{status} needs a separate absence confirmation" do
      owner = self()

      client(fn conn ->
        send(owner, {:request, conn.method, conn.request_path})
        code = if conn.method == "DELETE", do: unquote(status), else: 404
        Plug.Conn.send_resp(conn, code, "")
      end)

      assert :ok = Sandbox.destroy_once(handle())
      assert_receive {:request, "DELETE", "/v1/sprites/owned-worker"}
      assert_receive {:request, "GET", "/v1/sprites/owned-worker"}
      refute_receive {:request, _, _}
      assert Sandbox.supports?(:sprites, :destroy_once)
    end
  end

  test "an already absent sandbox needs one request" do
    owner = self()

    client(fn conn ->
      send(owner, conn.method)
      Plug.Conn.send_resp(conn, 404, "")
    end)

    assert :ok = Sandbox.destroy_once(handle())
    assert_receive "DELETE"
    refute_receive "GET"
    refute_receive "DELETE"
  end

  for {delete_status, get_status} <- [{202, 200}, {204, 200}, {200, 503}, {200, 302}] do
    test "DELETE #{delete_status} then GET #{get_status} remains uncertain without replay" do
      owner = self()

      client(fn conn ->
        send(owner, conn.method)
        code = if conn.method == "DELETE", do: unquote(delete_status), else: unquote(get_status)

        conn
        |> Plug.Conn.put_resp_header("location", "https://elsewhere.invalid")
        |> Plug.Conn.send_resp(code, "private detail")
      end)

      assert {:error, {:unavailable, :delete_unconfirmed}} = Sandbox.destroy_once(handle())
      assert_receive "DELETE"
      assert_receive "GET"
      refute_receive "DELETE"
      refute_receive "GET"
    end
  end

  for status <- [302, 401, 429, 503] do
    test "DELETE #{status} cannot retry, redirect or leak provider prose" do
      owner = self()

      client(fn conn ->
        send(owner, conn.method)

        conn
        |> Plug.Conn.put_resp_header("location", "https://elsewhere.invalid")
        |> Plug.Conn.send_resp(unquote(status), "private detail")
      end)

      assert {:error, {:unavailable, :delete_unconfirmed}} = Sandbox.destroy_once(handle())
      assert_receive "DELETE"
      refute_receive "DELETE"
      refute_receive "GET"
    end
  end

  test "transport failures remain uncertain and reveal no exception content" do
    client(fn _ -> raise "private detail" end)
    assert {:error, {:unavailable, :delete_transport_failed}} = Sandbox.destroy_once(handle())
    client(fn _ -> throw(:private_detail) end)
    assert {:error, {:unavailable, :delete_transport_failed}} = Sandbox.destroy_once(handle())
  end

  test "a lost reply stops waiting within the total timeout" do
    owner = self()

    client(fn conn ->
      send(owner, {:transport, self()})

      receive do
        :continue -> Plug.Conn.send_resp(conn, 204, "")
      end
    end)

    assert {:error, {:unavailable, :delete_timeout}} =
             Sandbox.destroy_once(handle(), timeout_ms: 100)

    assert_receive {:transport, pid}
    refute Process.alive?(pid)
  end

  test "oversized responses stay bounded and cannot supply evidence of absence" do
    client(fn conn -> Plug.Conn.send_resp(conn, 200, String.duplicate("x", 65_537)) end)
    assert {:error, {:unavailable, :delete_unconfirmed}} = Sandbox.destroy_once(handle())
  end

  test "invalid options are refused before provider access" do
    reject(Managoat.Sandbox.Sprites.Client, :get!, 0)

    for timeout <- [nil, "100", 0, -1, 120_001] do
      assert {:error, {:invalid, :delete_timeout}} =
               Sandbox.destroy_once(handle(), timeout_ms: timeout)
    end

    assert {:error, {:invalid, :delete_options}} = Sandbox.destroy_once(handle(), retry: true)
  end

  test "unsupported adapters cannot fall back to ordinary deletion" do
    for provider <- [:e2b] do
      assert {:error, :not_supported} = Sandbox.destroy_once(%{handle() | provider: provider})
    end
  end
end
