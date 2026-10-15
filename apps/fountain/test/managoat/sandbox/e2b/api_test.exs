defmodule Managoat.Sandbox.E2B.ApiTest do
  use ExUnit.Case, async: false

  alias Managoat.Sandbox.E2B.Api

  setup do
    previous = Application.get_env(:fountain, Managoat.Sandbox.E2B, [])

    Application.put_env(
      :fountain,
      Managoat.Sandbox.E2B,
      api_key: "e2b_test_key",
      base_url: "https://api.test",
      template: "fountain-template",
      req_options: [plug: {Req.Test, __MODULE__}, retry: false]
    )

    on_exit(fn ->
      Application.put_env(:fountain, Managoat.Sandbox.E2B, previous)
    end)

    :ok
  end

  test "configuration builds the authenticated client" do
    assert Api.initial_ttl_s() == 1_800
    assert Api.base_url() == "https://api.test"
    assert Api.api_key!() == "e2b_test_key"
    assert Api.template() == "fountain-template"
    assert %Req.Request{} = Api.req()
  end

  test "control-plane operations send their documented requests" do
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, raw_body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:request, conn.method, conn.request_path, conn.query_string, raw_body})

      case {conn.method, conn.request_path} do
        {"POST", "/sandboxes"} -> Req.Test.json(conn, %{"sandboxID" => "sbx-1"})
        {"GET", "/v2/sandboxes"} -> Req.Test.json(conn, [%{"sandboxID" => "sbx-1"}])
        {"DELETE", "/sandboxes/sbx-1"} -> Plug.Conn.send_resp(conn, 204, "")
        {"POST", "/sandboxes/sbx-1/pause"} -> Plug.Conn.send_resp(conn, 204, "")
        {"POST", "/sandboxes/sbx-1/connect"} -> Plug.Conn.send_resp(conn, 204, "")
        {"POST", "/sandboxes/sbx-1/timeout"} -> Plug.Conn.send_resp(conn, 204, "")
        {"PUT", "/sandboxes/sbx-1/network"} -> Plug.Conn.send_resp(conn, 204, "")
      end
    end)

    assert {:ok, %{"sandboxID" => "sbx-1"}} = Api.create_sandbox("fountain-one")
    assert {:ok, %{"sandboxID" => "sbx-1"}} = Api.find_by_name("fountain-one")
    assert :ok = Api.delete_sandbox("sbx-1")
    assert :ok = Api.pause("sbx-1")
    assert :ok = Api.connect("sbx-1")
    assert :ok = Api.set_timeout("sbx-1", 90)
    assert :ok = Api.set_network("sbx-1", ["hex.pm", "github.com"])

    assert_received {:request, "POST", "/sandboxes", _, create_body}

    assert %{
             "templateID" => "fountain-template",
             "autoPause" => true,
             "secure" => true,
             "timeout" => 1_800
           } = Jason.decode!(create_body)

    assert_received {:request, "GET", "/v2/sandboxes", find_query, _}
    assert find_query =~ "state=running%2Cpaused"
    assert_received {:request, "POST", "/sandboxes/sbx-1/timeout", _, timeout_body}
    assert Jason.decode!(timeout_body) == %{"timeout" => 90}
    assert_received {:request, "PUT", "/sandboxes/sbx-1/network", _, network_body}

    assert Jason.decode!(network_body) == %{
             "allowOut" => ["hex.pm", "github.com"],
             "denyOut" => ["0.0.0.0/0"]
           }
  end

  test "get_sandbox returns the detail, and keeps failures tagged" do
    Req.Test.stub(__MODULE__, fn conn ->
      case conn.request_path do
        "/sandboxes/sbx-1" ->
          Req.Test.json(conn, %{"sandboxID" => "sbx-1", "envdAccessToken" => "tok"})

        "/sandboxes/sbx-gone" ->
          conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"message" => "not found"})

        "/sandboxes/sbx-down" ->
          Req.Test.transport_error(conn, :econnrefused)
      end
    end)

    assert {:ok, %{"envdAccessToken" => "tok"}} = Api.get_sandbox("sbx-1")
    assert {:error, {:api_error, 404, %{"message" => "not found"}}} = Api.get_sandbox("sbx-gone")
    assert {:error, %Req.TransportError{reason: :econnrefused}} = Api.get_sandbox("sbx-down")
  end

  test "find returns nil for an empty result" do
    Req.Test.stub(__MODULE__, &Req.Test.json(&1, []))
    assert {:ok, nil} = Api.find_by_name("missing")
  end

  test "listing follows x-next-token and collects only stamped names" do
    Req.Test.stub(__MODULE__, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      case conn.query_params["nextToken"] do
        nil ->
          conn
          |> Plug.Conn.put_resp_header("x-next-token", "page-2")
          |> Req.Test.json([
            %{"metadata" => %{"fountain_name" => "one"}},
            %{"metadata" => %{}}
          ])

        "page-2" ->
          Req.Test.json(conn, [%{"metadata" => %{"fountain_name" => "two"}}])
      end
    end)

    assert {:ok, names} = Api.list_all_names()
    assert names == MapSet.new(["one", "two"])
    assert {:error, :truncated} = Api.list_all_names(0)
  end

  test "idempotent lifecycle statuses are successful" do
    Req.Test.stub(__MODULE__, fn conn ->
      status = if conn.request_path =~ "/pause", do: 409, else: 404
      Plug.Conn.send_resp(conn, status, "already done")
    end)

    assert :ok = Api.delete_sandbox("gone")
    assert :ok = Api.pause("paused")
  end

  test "each operation preserves non-success HTTP errors" do
    Req.Test.stub(__MODULE__, fn conn ->
      conn |> Plug.Conn.put_status(418) |> Req.Test.json(%{"error" => "teapot"})
    end)

    error = {:error, {:api_error, 418, %{"error" => "teapot"}}}
    assert Api.create_sandbox("one") == error
    assert Api.find_by_name("one") == error
    assert Api.delete_sandbox("one") == error
    assert Api.pause("one") == error
    assert Api.connect("one") == error
    assert Api.set_timeout("one") == error
    assert Api.list_all_names() == error
    assert Api.set_network("one", []) == error
  end

  test "each operation preserves transport failures" do
    Req.Test.stub(__MODULE__, &Req.Test.transport_error(&1, :econnrefused))

    assert_transport_error(Api.create_sandbox("one"))
    assert_transport_error(Api.find_by_name("one"))
    assert_transport_error(Api.delete_sandbox("one"))
    assert_transport_error(Api.pause("one"))
    assert_transport_error(Api.connect("one"))
    assert_transport_error(Api.set_timeout("one"))
    assert_transport_error(Api.list_all_names())
    assert_transport_error(Api.set_network("one", []))
  end

  test "missing credentials fail before a request is made" do
    Application.put_env(:fountain, Managoat.Sandbox.E2B, api_key: nil)
    assert_raise RuntimeError, ~r/E2B_API_KEY is not set/, &Api.req/0
  end

  defp assert_transport_error({:error, %Req.TransportError{reason: :econnrefused}}), do: :ok
end
