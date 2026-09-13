defmodule FountainWeb.AuthMeControllerTest do
  # async: false for the billing-disabled tests, which flip global app env.
  use FountainWeb.ConnCase, async: false

  defp with_billing_disabled(fun) do
    previous = Application.get_env(:fountain, :credits_enabled)
    Application.put_env(:fountain, :credits_enabled, false)

    try do
      fun.()
    after
      Application.put_env(:fountain, :credits_enabled, previous)
    end
  end

  describe "GET /api/auth/me" do
    test "returns user identity for an authenticated request", %{conn: conn} do
      user = insert_verified_user()
      {_key_record, raw_key} = insert_api_key(user)

      conn =
        conn
        |> authed_with_key(raw_key)
        |> get("/api/auth/me")

      assert %{
               "id" => id,
               "email" => email,
               "role" => role,
               "expires_at" => nil,
               "comped" => comped
             } = json_response(conn, 200)

      assert id == user.id
      assert email == user.email
      assert role == user.role
      assert comped == false
    end

    test "reports the presented key's expiry, not another key on the account", %{conn: conn} do
      user = insert_verified_user()
      expires_at = DateTime.utc_now() |> DateTime.add(3600) |> DateTime.truncate(:second)
      {_permanent, permanent_key} = insert_api_key(user)
      {expiring, raw_key} = insert_api_key(user, nil, expires_at: expires_at)

      body = conn |> authed_with_key(raw_key) |> get("/api/auth/me") |> json_response(200)
      assert body["expires_at"] == DateTime.to_iso8601(expiring.expires_at)

      permanent =
        build_conn()
        |> authed_with_key(permanent_key)
        |> get("/api/auth/me")
        |> json_response(200)

      assert Map.fetch!(permanent, "expires_at") == nil
    end

    test "carries brokered, false with no broker configured and true with one", %{conn: conn} do
      user = insert_verified_user()
      {_key_record, raw_key} = insert_api_key(user)

      assert %{"brokered" => false} =
               conn |> authed_with_key(raw_key) |> get("/api/auth/me") |> json_response(200)

      previous =
        for k <- [:broker_listen_port, :broker_proxy_url],
            do: {k, Application.get_env(:fountain, k)}

      on_exit(fn ->
        for {k, v} <- previous,
            do:
              if(is_nil(v),
                do: Application.delete_env(:fountain, k),
                else: Application.put_env(:fountain, k, v)
              )
      end)

      Application.put_env(:fountain, :broker_listen_port, 14_322)
      Application.put_env(:fountain, :broker_proxy_url, "http://broker.test:14322")

      assert %{"brokered" => true} =
               conn |> authed_with_key(raw_key) |> get("/api/auth/me") |> json_response(200)
    end

    test "returns 401 when no API key is provided", %{conn: conn} do
      conn = get(conn, "/api/auth/me")
      assert conn.status == 401
    end

    test "returns 401 when an invalid API key is provided", %{conn: conn} do
      conn =
        conn
        |> authed_with_key("ftn_invalid000000000000000000000000000000000000000000000000000000")
        |> get("/api/auth/me")

      assert conn.status == 401
    end

    test "returns role field for an admin user", %{conn: conn} do
      user = insert_verified_user(%{"role" => "admin"})
      {_key_record, raw_key} = insert_api_key(user)

      conn =
        conn
        |> authed_with_key(raw_key)
        |> get("/api/auth/me")

      assert %{"role" => "admin"} = json_response(conn, 200)
    end

    test "comped is null when billing is disabled — key kept for shape compat (#480)",
         %{conn: conn} do
      # Residue case on purpose: even an account that still carries a status
      # from before the flag flipped must not leak it to API consumers.
      user = insert_verified_user()
      {_key_record, raw_key} = insert_api_key(user)

      with_billing_disabled(fn ->
        conn =
          conn
          |> authed_with_key(raw_key)
          |> get("/api/auth/me")

        body = json_response(conn, 200)
        assert Map.has_key?(body, "comped")
        assert body["comped"] == nil
      end)
    end

    test "email in response is downcased", %{conn: conn} do
      # registration downcases email; confirm the stored value is returned
      user = insert_verified_user(%{"email" => "MixedCase@Example.com"})
      {_key_record, raw_key} = insert_api_key(user)

      conn =
        conn
        |> authed_with_key(raw_key)
        |> get("/api/auth/me")

      assert %{"email" => email} = json_response(conn, 200)
      assert email == String.downcase(email)
    end
  end
end
