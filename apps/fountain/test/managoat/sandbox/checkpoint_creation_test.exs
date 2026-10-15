defmodule Managoat.Sandbox.CheckpointCreationTest do
  use ExUnit.Case, async: false
  use Mimic

  alias Managoat.Sandbox
  alias Managoat.Sandbox.Handle

  @operation "persisted-operation-123"
  @comment "sandbox-operation:#{@operation}"
  @complete ~S|{"type":"complete","data":"snapshot created"}| <> "\n"

  setup do
    prior = Application.get_env(:fountain, Sandbox.Sprites)
    Application.put_env(:fountain, Sandbox.Sprites, checkpoint_creation_enabled: true)

    on_exit(fn ->
      if prior,
        do: Application.put_env(:fountain, Sandbox.Sprites, prior),
        else: Application.delete_env(:fountain, Sandbox.Sprites)
    end)

    :ok
  end

  defp handle, do: %Handle{provider: :sprites, name: "owned worker/x", instance_id: "instance"}

  defp create(opts \\ []),
    do: Sandbox.create_checkpoint_once(handle(), Keyword.merge([operation_id: @operation], opts))

  defp listing, do: Jason.encode!([%{id: "snapshot-42", comment: @comment}])

  defp client(plug) do
    req = Req.new(base_url: "https://provider.invalid", plug: plug, retry: :transient)
    stub(Sandbox.Sprites.Client, :get!, fn -> %Sprites.Client{req: req} end)
  end

  test "one POST then one GET correlates the operation without parsing prose" do
    owner = self()

    client(fn conn ->
      send(owner, {:request, conn.method, conn.request_path})

      if conn.method == "POST" do
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(body) == %{"comment" => @comment}

        Plug.Conn.send_resp(
          conn,
          200,
          (~S|{"type":"info","data":"v999 is prose"}| <> "\n") <> @complete
        )
      else
        Plug.Conn.send_resp(conn, 200, listing())
      end
    end)

    assert {:ok, "snapshot-42"} = create()
    assert_receive {:request, "POST", "/v1/sprites/owned%20worker%2Fx/checkpoint"}
    assert_receive {:request, "GET", "/v1/sprites/owned%20worker%2Fx/checkpoints"}
    refute_receive {:request, _, _}
    assert Sandbox.supports?(:sprites, :create_checkpoint_once)
  end

  for status <- [201, 202, 204, 302, 400, 401, 404, 429, 500, 503] do
    test "POST #{status} never retries, redirects or supplies checkpoint proof" do
      owner = self()

      client(fn conn ->
        send(owner, conn.method)

        conn
        |> Plug.Conn.put_resp_header("location", "https://elsewhere.invalid")
        |> Plug.Conn.send_resp(unquote(status), @complete)
      end)

      assert {:error, {:unavailable, :checkpoint_unconfirmed}} = create()
      assert_receive "POST"
      refute_receive "POST"
      refute_receive "GET"
    end
  end

  for stream <- [
        "",
        "not-json",
        "[]",
        "{}",
        "{\"type\":\"info\",\"data\":\"waiting\"}\n",
        "{\"type\":\"error\",\"error\":\"private provider failure\"}\n",
        "{\"type\":\"complete\",\"data\":4}\n",
        "{\"type\":\"complete\",\"data\":\"done\",\"error\":\"private detail\"}\n",
        (~S|{"type":"info","data":"info","error":null}| <> "\n") <> @complete,
        @complete <> @complete,
        @complete <> "{\"type\":\"info\",\"data\":\"late\"}\n"
      ] do
    @stream stream
    test "incomplete or malformed stream #{inspect(stream)} remains uncertain" do
      client(fn conn ->
        assert conn.method == "POST"
        Plug.Conn.send_resp(conn, 200, @stream)
      end)

      assert {:error, {:unavailable, :checkpoint_unconfirmed}} = create()
    end
  end

  for {response, index} <-
        Enum.with_index([
          "not-json",
          "{}",
          "[]",
          "[null]",
          "[4]",
          "[{\"id\":null}]",
          Jason.encode!([%{id: "old", comment: "earlier operation"}]),
          Jason.encode!([%{id: "Current", comment: @comment}]),
          Jason.encode!([%{id: "a", comment: @comment}, %{id: "b", comment: @comment}]),
          Jason.encode!([%{id: "", comment: @comment}]),
          Jason.encode!([%{id: String.duplicate("x", 257), comment: @comment}]),
          Jason.encode!([%{id: "snapshot-42", comment: @comment}, %{id: "other", comment: 9}])
        ]) do
    @listing response
    test "missing, ambiguous or malformed checkpoint list case #{index} cannot substitute" do
      client(fn conn ->
        Plug.Conn.send_resp(conn, 200, if(conn.method == "POST", do: @complete, else: @listing))
      end)

      assert {:error, {:unavailable, :checkpoint_unconfirmed}} = create()
    end
  end

  test "unrelated older checkpoints without comments are allowed alongside the unique match" do
    client(fn conn ->
      body =
        if conn.method == "POST",
          do: @complete,
          else: Jason.encode!([%{id: "old"}, %{id: "snapshot-42", comment: @comment}])

      Plug.Conn.send_resp(conn, 200, body)
    end)

    assert {:ok, "snapshot-42"} = create()
  end

  for status <- [202, 302, 404, 429, 503] do
    test "GET #{status} cannot retry or redirect" do
      owner = self()

      client(fn conn ->
        send(owner, conn.method)
        status = if conn.method == "POST", do: 200, else: unquote(status)
        body = if conn.method == "POST", do: @complete, else: listing()

        conn
        |> Plug.Conn.put_resp_header("location", "https://elsewhere.invalid")
        |> Plug.Conn.send_resp(status, body)
      end)

      assert {:error, {:unavailable, :checkpoint_unconfirmed}} = create()
      assert_receive "POST"
      assert_receive "GET"
      refute_receive "POST"
      refute_receive "GET"
    end
  end

  test "one 64 KiB response budget covers both requests" do
    client(fn conn ->
      body =
        if conn.method == "POST",
          do: @complete,
          else: listing() <> String.duplicate(" ", 65_536 - byte_size(listing()))

      Plug.Conn.send_resp(conn, 200, body)
    end)

    assert {:error, {:unavailable, :checkpoint_unconfirmed}} = create()
    client(fn conn -> Plug.Conn.send_resp(conn, 200, String.duplicate("x", 65_537)) end)
    assert {:error, {:unavailable, :checkpoint_unconfirmed}} = create()
  end

  test "private exceptions and throws do not escape" do
    client(fn _ -> raise "private detail" end)
    assert {:error, {:unavailable, :checkpoint_transport_failed}} = create()
    client(fn _ -> throw(:private_detail) end)
    assert {:error, {:unavailable, :checkpoint_transport_failed}} = create()
  end

  test "a stalled request stops its executing process at the total deadline" do
    owner = self()

    client(fn conn ->
      send(owner, {:transport, self()})

      receive do
        :never -> Plug.Conn.send_resp(conn, 200, @complete)
      end
    end)

    assert {:error, {:unavailable, :checkpoint_timeout}} = create(timeout_ms: 100)
    assert_receive {:transport, pid}
    refute Process.alive?(pid)
  end

  test "invalid options never reach provider credentials" do
    reject(Sandbox.Sprites.Client, :get!, 0)

    for timeout <- [nil, "100", 0, -1, 120_001] do
      assert {:error, {:invalid, :checkpoint_timeout}} = create(timeout_ms: timeout)
    end

    for operation <- [nil, "", "contains space", "a\n", String.duplicate("a", 129), 12] do
      assert {:error, {:invalid, :checkpoint_operation_id}} = create(operation_id: operation)
    end

    assert {:error, {:invalid, :checkpoint_options}} = create(retry: true)
  end

  test "disabled checkpoint creation and unsupported adapters have no fallback" do
    Application.put_env(:fountain, Sandbox.Sprites, checkpoint_creation_enabled: false)
    reject(Sandbox.Sprites.Client, :get!, 0)
    assert {:error, :not_supported} = create()
    refute Sandbox.supports?(:sprites, :create_checkpoint_once)

    for provider <- [:e2b] do
      assert {:error, :not_supported} =
               Sandbox.create_checkpoint_once(%{handle() | provider: provider},
                 operation_id: @operation
               )
    end
  end

  for mode <- [:stall, :oversize] do
    test "real HTTP/1 #{mode} closes the socket instead of leaving a hidden request" do
      {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
      {:ok, {_address, port}} = :inet.sockname(listener)
      on_exit(fn -> :gen_tcp.close(listener) end)
      req = Req.new(base_url: "http://127.0.0.1:#{port}")
      stub(Sandbox.Sprites.Client, :get!, fn -> %Sprites.Client{req: req} end)

      server =
        Task.async(fn ->
          {:ok, socket} = :gen_tcp.accept(listener, 2_000)
          {:ok, _request} = :gen_tcp.recv(socket, 0, 2_000)

          if unquote(mode) == :oversize do
            :ok =
              :gen_tcp.send(
                socket,
                "HTTP/1.1 200 OK\r\nContent-Length: 100000\r\n\r\n" <>
                  String.duplicate("x", 70_000)
              )
          end

          closed = drain_until_closed(socket)
          :gen_tcp.close(socket)
          closed
        end)

      assert {:error, {:unavailable, _}} = create(timeout_ms: 500)
      assert {:error, :closed} = Task.await(server, 3_000)
    end
  end

  test "a complete event inside a truncated HTTP response is not completion" do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, {_address, port}} = :inet.sockname(listener)
    on_exit(fn -> :gen_tcp.close(listener) end)
    req = Req.new(base_url: "http://127.0.0.1:#{port}")
    stub(Sandbox.Sprites.Client, :get!, fn -> %Sprites.Client{req: req} end)

    server =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 2_000)
        {:ok, _request} = :gen_tcp.recv(socket, 0, 2_000)

        :ok =
          :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\nContent-Length: 1000\r\n\r\n" <> @complete)

        :gen_tcp.close(socket)
        :gen_tcp.accept(listener, 150)
      end)

    assert {:error, {:unavailable, :checkpoint_unconfirmed}} = create(timeout_ms: 500)
    assert {:error, :timeout} = Task.await(server, 2_000)
  end

  test "the confirmation read receives only the remaining deadline" do
    client(fn _ -> flunk("the Req calls are stubbed directly") end)

    expect(Req, :post, fn _, opts ->
      assert opts[:receive_timeout] <= 500
      Process.sleep(25)
      {:ok, Req.Response.new(status: 200, body: @complete)}
    end)

    expect(Req, :get, fn _, opts ->
      assert opts[:receive_timeout] < 500
      assert opts[:receive_timeout] > 0
      assert opts[:retry] == false
      assert opts[:redirect] == false
      {:ok, Req.Response.new(status: 200, body: listing())}
    end)

    assert {:ok, "snapshot-42"} = create(timeout_ms: 500)
  end

  test "caller death still closes the real HTTP request at the child deadline" do
    owner = self()
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, {_address, port}} = :inet.sockname(listener)
    on_exit(fn -> :gen_tcp.close(listener) end)
    req = Req.new(base_url: "http://127.0.0.1:#{port}")
    stub(Sandbox.Sprites.Client, :get!, fn -> %Sprites.Client{req: req} end)

    server =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 2_000)
        {:ok, _request} = :gen_tcp.recv(socket, 0, 2_000)
        send(owner, :request_received)
        closed = drain_until_closed(socket)
        :gen_tcp.close(socket)
        closed
      end)

    caller =
      Task.async(fn ->
        receive do
          :start -> create(timeout_ms: 500)
        end
      end)

    Process.unlink(caller.pid)
    send(caller.pid, :start)
    assert_receive :request_received, 1_000
    Process.exit(caller.pid, :kill)
    assert {:exit, :killed} = Task.yield(caller, 1_000)
    assert {:error, :closed} = Task.await(server, 3_000)
  end

  defp drain_until_closed(socket) do
    case :gen_tcp.recv(socket, 0, 2_000) do
      {:ok, _request_body} -> drain_until_closed(socket)
      result -> result
    end
  end
end
