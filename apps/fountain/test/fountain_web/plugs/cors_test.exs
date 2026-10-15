defmodule FountainWeb.Plugs.CorsTest do
  use FountainWeb.ConnCase, async: false

  alias FountainWeb.Plugs.Cors

  setup do
    previous = Application.get_env(:fountain, :api_cors_origins)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:fountain, :api_cors_origins, previous),
        else: Application.delete_env(:fountain, :api_cors_origins)
    end)

    :ok
  end

  defp call(conn), do: Cors.call(conn, Cors.init([]))

  test "does nothing when no origins are configured", %{conn: conn} do
    Application.put_env(:fountain, :api_cors_origins, [])

    conn =
      conn
      |> Map.put(:path_info, ["api", "conversations"])
      |> put_req_header("origin", "https://app.example.com")
      |> call()

    assert get_resp_header(conn, "access-control-allow-origin") == []
    refute conn.halted
  end

  test "echoes an allowed origin and never allows credentials", %{conn: conn} do
    Application.put_env(:fountain, :api_cors_origins, ["https://app.example.com"])

    conn =
      conn
      |> Map.put(:path_info, ["api", "conversations"])
      |> put_req_header("origin", "https://app.example.com")
      |> call()

    assert get_resp_header(conn, "access-control-allow-origin") == ["https://app.example.com"]
    assert get_resp_header(conn, "access-control-allow-credentials") == []
    assert get_resp_header(conn, "vary") == ["origin"]
    refute conn.halted
  end

  test "ignores an origin that is not allowed", %{conn: conn} do
    Application.put_env(:fountain, :api_cors_origins, ["https://app.example.com"])

    conn =
      conn
      |> Map.put(:path_info, ["api", "conversations"])
      |> put_req_header("origin", "https://evil.example.com")
      |> call()

    assert get_resp_header(conn, "access-control-allow-origin") == []
  end

  test "`*` allows any origin, still by echo", %{conn: conn} do
    Application.put_env(:fountain, :api_cors_origins, ["*"])

    conn =
      conn
      |> Map.put(:path_info, ["api", "conversations"])
      |> put_req_header("origin", "https://anywhere.example.com")
      |> call()

    assert get_resp_header(conn, "access-control-allow-origin") == [
             "https://anywhere.example.com"
           ]
  end

  test "answers a preflight from an allowed origin with 204 and halts", %{conn: conn} do
    Application.put_env(:fountain, :api_cors_origins, ["https://app.example.com"])

    conn =
      %{conn | method: "OPTIONS"}
      |> Map.put(:path_info, ["api", "conversations"])
      |> put_req_header("origin", "https://app.example.com")
      |> put_req_header("access-control-request-method", "POST")
      |> call()

    assert conn.halted
    assert conn.status == 204
    assert hd(get_resp_header(conn, "access-control-allow-headers")) =~ "authorization"
    assert hd(get_resp_header(conn, "access-control-allow-headers")) =~ "last-event-id"
  end

  test "leaves non-/api paths alone", %{conn: conn} do
    Application.put_env(:fountain, :api_cors_origins, ["*"])

    conn =
      conn
      |> Map.put(:path_info, ["dashboard"])
      |> put_req_header("origin", "https://app.example.com")
      |> call()

    assert get_resp_header(conn, "access-control-allow-origin") == []
  end

  describe "a registered OAuth client's origin (#1125)" do
    test "is admitted with API_CORS_ORIGINS empty", %{conn: conn} do
      Application.put_env(:fountain, :api_cors_origins, [])
      insert_oauth_client(redirect_uris: ["https://notes.test/callback"])

      conn =
        conn
        |> Map.put(:path_info, ["api", "conversations"])
        |> put_req_header("origin", "https://notes.test")
        |> call()

      assert get_resp_header(conn, "access-control-allow-origin") == ["https://notes.test"]
    end

    test "does not admit an origin nobody registered", %{conn: conn} do
      Application.put_env(:fountain, :api_cors_origins, [])
      insert_oauth_client(redirect_uris: ["https://notes.test/callback"])

      conn =
        conn
        |> Map.put(:path_info, ["api", "conversations"])
        |> put_req_header("origin", "https://evil.test")
        |> call()

      assert get_resp_header(conn, "access-control-allow-origin") == []
    end

    test "admits a loopback origin on any port", %{conn: conn} do
      Application.put_env(:fountain, :api_cors_origins, [])
      insert_oauth_client(redirect_uris: ["http://localhost:5173/callback"])

      conn =
        conn
        |> Map.put(:path_info, ["api", "conversations"])
        |> put_req_header("origin", "http://localhost:5174")
        |> call()

      assert get_resp_header(conn, "access-control-allow-origin") == ["http://localhost:5174"]
    end

    test "stops admitting it once the client is deleted", %{conn: conn} do
      Application.put_env(:fountain, :api_cors_origins, [])
      client = insert_oauth_client(redirect_uris: ["https://notes.test/callback"])
      {:ok, _} = Fountain.OAuth.delete_client(client)

      conn =
        conn
        |> Map.put(:path_info, ["api", "conversations"])
        |> put_req_header("origin", "https://notes.test")
        |> call()

      assert get_resp_header(conn, "access-control-allow-origin") == []
    end
  end

  test "end to end: a preflight against the endpoint is answered before auth", %{conn: conn} do
    Application.put_env(:fountain, :api_cors_origins, ["https://app.example.com"])

    conn =
      conn
      |> put_req_header("origin", "https://app.example.com")
      |> put_req_header("access-control-request-method", "GET")
      |> options("/api/conversations")

    assert conn.status == 204
    assert get_resp_header(conn, "access-control-allow-origin") == ["https://app.example.com"]
  end
end
