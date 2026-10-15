defmodule Managoat.Sandbox.CreationTest do
  use ExUnit.Case, async: true
  use Mimic

  alias Managoat.Sandbox
  alias Managoat.Sandbox.Handle
  alias Managoat.Sandbox.Sprites, as: Adapter

  defp client(plug) do
    req = Req.new(base_url: "https://provider.invalid", plug: plug, retry: :transient)
    stub(Managoat.Sandbox.Sprites.Client, :get!, fn -> %Sprites.Client{req: req} end)
  end

  defp created, do: Jason.encode!(%{name: "new-worker", id: "provider-issued-id"})

  test "returns provider identity and sets URL access in the same create request" do
    owner = self()

    client(fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(owner, {:request, conn.method, conn.request_path, Jason.decode!(body)})
      Plug.Conn.send_resp(conn, 201, created())
    end)

    assert {:ok,
            %Handle{
              provider: :sprites,
              name: "new-worker",
              instance_id: "provider-issued-id",
              private: nil
            }} =
             Sandbox.create_new(:sprites, "new-worker",
               wait_for_capacity: true,
               timeout_ms: 1000
             )

    assert_receive {:request, "POST", "/v1/sprites",
                    %{
                      "name" => "new-worker",
                      "wait_for_capacity" => true,
                      "url_settings" => %{"auth" => "public"}
                    }}

    refute_receive {:request, _, _, _}
    assert Sandbox.supports?(:sprites, :create_new)
  end

  test "a create conflict never adopts, probes or mutates the existing machine" do
    owner = self()

    client(fn conn ->
      send(owner, {:request, conn.method, conn.request_path})
      Plug.Conn.send_resp(conn, 409, "existing machine")
    end)

    assert {:error, :already_exists} = Adapter.create_new("new-worker", [])
    assert_receive {:request, "POST", "/v1/sprites"}
    refute_receive {:request, _, _}
  end

  for {label, body} <- [
        {"missing name", ~s({"id":"id"})},
        {"wrong name", ~s({"name":"other","id":"id"})},
        {"missing identity", ~s({"name":"new-worker"})},
        {"empty identity", ~s({"name":"new-worker","id":""})},
        {"non-string identity", ~s({"name":"new-worker","id":123})},
        {"long identity", Jason.encode!(%{name: "new-worker", id: String.duplicate("x", 257)})},
        {"non-JSON", "private provider detail"},
        {"non-object", "[]"},
        {"oversized", String.duplicate("x", 65_537)}
      ] do
    test "#{label} is uncertain despite a successful HTTP status" do
      client(fn conn -> Plug.Conn.send_resp(conn, 200, unquote(body)) end)
      assert {:error, {:unavailable, :create_unconfirmed}} = Adapter.create_new("new-worker", [])
    end
  end

  for status <- [302, 400, 401, 429, 503] do
    test "HTTP #{status} is not replayed or redirected and does not expose provider prose" do
      owner = self()

      client(fn conn ->
        send(owner, :request)

        conn
        |> Plug.Conn.put_resp_header("location", "https://other.invalid")
        |> Plug.Conn.send_resp(unquote(status), "private provider detail")
      end)

      assert {:error, reason} = Adapter.create_new("new-worker", [])
      refute inspect(reason) =~ "private provider detail"
      assert_receive :request
      refute_receive :request
    end
  end

  test "a transport error is uncertain without replay" do
    expect(Req, :post, fn _, _ -> {:error, :private_detail} end)
    client(fn conn -> Plug.Conn.send_resp(conn, 200, created()) end)

    assert {:error, {:unavailable, :create_transport_failed}} =
             Adapter.create_new("new-worker", [])
  end

  test "raised and thrown transport failures retain no private detail" do
    client(fn _ -> raise "private detail" end)

    assert {:error, {:unavailable, :create_transport_failed}} =
             Adapter.create_new("new-worker", [])

    client(fn _ -> throw(:private_detail) end)

    assert {:error, {:unavailable, :create_transport_failed}} =
             Adapter.create_new("new-worker", [])
  end

  test "the total timeout stops waiting without claiming the create was undone" do
    owner = self()

    client(fn conn ->
      send(owner, {:transport, self()})

      receive do
        :continue -> Plug.Conn.send_resp(conn, 201, created())
      end
    end)

    assert {:error, {:unavailable, :create_timeout}} =
             Adapter.create_new("new-worker", timeout_ms: 100)

    assert_receive {:transport, pid}
    refute Process.alive?(pid)
  end

  test "invalid timeout is refused before provider access" do
    reject(Managoat.Sandbox.Sprites.Client, :get!, 0)

    for timeout <- [0, -1, 120_001, "1000", nil] do
      assert {:error, {:invalid, :create_timeout}} =
               Adapter.create_new("new-worker", timeout_ms: timeout)
    end
  end

  test "unsupported or malformed options are refused before provider access" do
    reject(Managoat.Sandbox.Sprites.Client, :get!, 0)

    for opts <- [[config: %{}], [wait_for_capacity: "true"], [retry: true]] do
      assert {:error, {:invalid, :create_options}} = Adapter.create_new("new-worker", opts)
    end
  end

  test "unsupported adapters never fall back to adopting creation" do
    for provider <- [:e2b] do
      assert {:error, :not_supported} = Sandbox.create_new(provider, "new-worker")
    end
  end
end
