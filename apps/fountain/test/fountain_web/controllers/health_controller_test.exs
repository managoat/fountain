defmodule FountainWeb.HealthControllerTest do
  use FountainWeb.ConnCase, async: true
  use Mimic

  describe "GET /health (liveness)" do
    test "returns 200 with status ok", %{conn: conn} do
      conn = get(conn, "/health")

      assert %{"status" => "ok"} = json_response(conn, 200)
    end

    test "is publicly accessible without authentication", %{conn: conn} do
      # No auth header — should still respond 200
      conn = get(conn, "/health")
      assert conn.status == 200
    end

    test "response content-type is application/json", %{conn: conn} do
      conn = get(conn, "/health")

      assert {"content-type", content_type} =
               List.keyfind(conn.resp_headers, "content-type", 0)

      assert content_type =~ "application/json"
    end

    test "checks no dependencies", %{conn: conn} do
      # This is the whole reason there are two endpoints. Liveness failing
      # restarts the pod, so if it consulted Postgres a database blip would
      # restart every replica at once — which does nothing to fix Postgres and
      # turns a brief outage into a crash loop.
      reject(&Fountain.Health.database/0)
      reject(&Fountain.Health.database/1)

      assert %{"status" => "ok"} = conn |> get("/health") |> json_response(200)
    end
  end

  describe "GET /health/ready (readiness)" do
    test "returns 200 when every dependency answers", %{conn: conn} do
      body = conn |> get("/health/ready") |> json_response(200)

      assert body["status"] == "ok"
      assert body["checks"]["database"] == "ok"
      assert body["checks"]["broker_listener"] == "ok"
    end

    test "returns 503 when the broker listener is down", %{conn: conn} do
      # #1726: the listener starts after the endpoint, so a fresh pod can
      # serve HTTP with nothing bound to BROKER_LISTEN_PORT. Every provision
      # routed there fails, because a deployment with a broker has no
      # unbrokered path to fall back to.
      stub(Fountain.Health, :broker_listener, fn -> :error end)

      conn = get(conn, "/health/ready")

      assert conn.status == 503
      body = json_response(conn, 503)
      assert body["status"] == "error"
      assert body["checks"]["broker_listener"] == "error"
      assert body["checks"]["database"] == "ok"
    end

    test "returns 503 when the database is unreachable", %{conn: conn} do
      # The case that made this issue worth fixing: before the split this pod
      # answered 200 and kept receiving traffic it could not serve.
      stub(Fountain.Health, :database, fn -> :error end)

      conn = get(conn, "/health/ready")

      assert conn.status == 503
      body = json_response(conn, 503)
      assert body["status"] == "error"
      assert body["checks"]["database"] == "error"
    end

    test "reports no detail about the failure", %{conn: conn} do
      # It is served on the public host, so a failing check must not describe
      # the database, the host it runs on, or the error it returned.
      stub(Fountain.Health, :database, fn -> :error end)

      raw = conn |> get("/health/ready") |> Map.fetch!(:resp_body)

      assert Jason.decode!(raw) == %{
               "status" => "error",
               "checks" => %{"database" => "error", "broker_listener" => "ok"}
             }

      for leak <- ~w(Postgrex DBConnection postgres password hostname stacktrace) do
        refute raw =~ leak
      end
    end

    test "is publicly accessible without authentication", %{conn: conn} do
      # kubelet does not carry an API key.
      assert conn |> get("/health/ready") |> json_response(200)
    end

    test "liveness keeps answering while readiness fails", %{conn: conn} do
      # The pair has to be able to disagree, or the split bought nothing:
      # kubelet must pull the pod from the Service without restarting it.
      stub(Fountain.Health, :database, fn -> :error end)

      assert conn |> get("/health") |> json_response(200)
      assert conn |> get("/health/ready") |> json_response(503)
    end
  end
end
