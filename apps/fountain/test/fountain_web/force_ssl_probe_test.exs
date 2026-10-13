defmodule FountainWeb.ForceSslProbeTest do
  @moduledoc """
  The https redirect must not apply to the health probes.

  kubelet hits them directly on the pod IP, over plain http and with no
  X-Forwarded-Proto, because there is no proxy on that path. Plug.SSL saw http
  and answered 301; the probe scored a redirect as a failure; the pod never
  became ready; the deployment stalled on its progress deadline with an app that
  was running perfectly. Nothing in the logs said "broken" — the only clue was

      Plug.SSL is redirecting GET /health to https://10.42.3.221 with status 301
  """

  use FountainWeb.ConnCase, async: false

  setup do
    previous = Application.get_env(:fountain, :force_ssl)

    Application.put_env(:fountain, :force_ssl,
      rewrite_on: [:x_forwarded_proto],
      hsts: true
    )

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:fountain, :force_ssl)
        v -> Application.put_env(:fountain, :force_ssl, v)
      end
    end)

    :ok
  end

  describe "with force_ssl on, over plain http" do
    test "liveness answers 200 rather than redirecting", %{conn: conn} do
      conn = get(conn, "/health")

      assert conn.status == 200
      assert json_response(conn, 200)["status"] == "ok"
    end

    test "readiness answers rather than redirecting", %{conn: conn} do
      # A 301 here is scored as a probe failure, which drains the pod.
      conn = get(conn, "/health/ready")

      assert conn.status in [200, 503]
      refute conn.status == 301
    end

    test "everything else still redirects to https", %{conn: conn} do
      # The exemption must be exactly the probe paths and nothing more.
      conn = get(conn, "/auth/login")

      assert conn.status == 301
      assert [location] = Plug.Conn.get_resp_header(conn, "location")
      assert String.starts_with?(location, "https://")
    end

    test "a path merely starting with /health is not exempt", %{conn: conn} do
      # Guards against a prefix match quietly exempting more than intended.
      conn = get(conn, "/healthcheck")

      assert conn.status == 301
    end
  end

  describe "with an excluded in-network host" do
    test "a request to that host is served over http, without HSTS", %{conn: conn} do
      Application.put_env(:fountain, :force_ssl,
        rewrite_on: [:x_forwarded_proto],
        hsts: true,
        exclude: ["localhost", "fountain.fountain.svc.cluster.local"]
      )

      conn = conn |> Map.put(:host, "fountain.fountain.svc.cluster.local") |> get("/auth/login")

      refute conn.status == 301
      assert Plug.Conn.get_resp_header(conn, "strict-transport-security") == []
    end

    test "any other host still redirects", %{conn: conn} do
      Application.put_env(:fountain, :force_ssl,
        rewrite_on: [:x_forwarded_proto],
        hsts: true,
        exclude: ["localhost", "fountain.fountain.svc.cluster.local"]
      )

      conn = conn |> Map.put(:host, "fountain.example.com") |> get("/auth/login")

      assert conn.status == 301
    end
  end

  describe "with force_ssl off" do
    test "nothing redirects", %{conn: conn} do
      Application.delete_env(:fountain, :force_ssl)

      assert get(conn, "/health").status == 200
      refute get(conn, "/auth/login").status == 301
    end
  end
end
