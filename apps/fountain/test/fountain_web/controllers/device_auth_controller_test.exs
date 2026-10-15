defmodule FountainWeb.DeviceAuthControllerTest do
  # async: true is safe alongside the rate-limited routes because
  # :rate_limit_test_isolation keys the buckets by test pid.
  use FountainWeb.ConnCase, async: true

  alias Fountain.OAuth

  describe "POST /api/auth/device" do
    test "starts a grant the whole flow can run on", %{conn: conn} do
      conn = post_json(conn, "/api/auth/device", %{})

      assert %{
               "device_code" => device_code,
               "user_code" => user_code,
               "verification_uri" => uri,
               "verification_uri_complete" => uri_complete,
               "expires_in" => expires_in,
               "interval" => interval
             } = json_response(conn, 201)

      assert String.ends_with?(uri, "/device")
      assert uri_complete =~ "/device?code="
      assert expires_in > 0
      assert interval > 0
      # The pieces really belong to one live grant.
      assert {:ok, _} = OAuth.get_device_grant_for_approval(user_code)
      assert {:error, :authorization_pending} = OAuth.poll_device_grant(device_code)
      assert get_resp_header(conn, "cache-control") == ["no-store"]
    end

    test "a client_name is stored, sanitized, on the grant", %{conn: conn} do
      conn = post_json(conn, "/api/auth/device", %{client_name: "  Arugula on\ngeek "})
      assert %{"user_code" => user_code} = json_response(conn, 201)

      assert {:ok, %{client_name: "Arugula on geek"}} =
               OAuth.get_device_grant_for_approval(user_code)
    end

    test "a client_name that is not a string is invalid_request", %{conn: conn} do
      conn = post_json(conn, "/api/auth/device", %{client_name: 42})
      assert %{"error" => "invalid_request"} = json_response(conn, 400)
    end
  end

  describe "POST /api/auth/device/token" do
    setup %{conn: conn} do
      started = post_json(conn, "/api/auth/device", %{})

      %{"device_code" => device_code, "user_code" => user_code} =
        json_response(started, 201)

      %{device_code: device_code, user_code: user_code}
    end

    test "pending until approved, then the AuthTokenResponse shape, once",
         %{conn: conn, device_code: device_code, user_code: user_code} do
      pending = post_json(conn, "/api/auth/device/token", %{device_code: device_code})
      assert %{"error" => "authorization_pending"} = json_response(pending, 400)

      user = insert_verified_user()
      assert :ok = OAuth.approve_device_grant(user_code, user.id)

      minted = post_json(conn, "/api/auth/device/token", %{device_code: device_code})
      assert %{"api_key" => key, "key_id" => _, "prefix" => prefix} = json_response(minted, 201)
      assert String.starts_with?(key, "ftn_")
      assert String.starts_with?(prefix, "ftn_")
      assert get_resp_header(minted, "cache-control") == ["no-store"]

      # Consumed: the same device code never mints twice.
      again = post_json(conn, "/api/auth/device/token", %{device_code: device_code})
      assert %{"error" => "invalid_grant"} = json_response(again, 400)
    end

    test "a denial is access_denied", %{
      conn: conn,
      device_code: device_code,
      user_code: user_code
    } do
      user = insert_verified_user()
      assert :ok = OAuth.deny_device_grant(user_code, user.id)

      conn = post_json(conn, "/api/auth/device/token", %{device_code: device_code})
      assert %{"error" => "access_denied"} = json_response(conn, 400)
    end

    test "an unknown code is invalid_grant, and so is a missing one", %{conn: conn} do
      unknown = post_json(conn, "/api/auth/device/token", %{device_code: "nope"})
      assert %{"error" => "invalid_grant"} = json_response(unknown, 400)

      missing = post_json(conn, "/api/auth/device/token", %{})
      assert %{"error" => "invalid_grant"} = json_response(missing, 400)
    end
  end
end
