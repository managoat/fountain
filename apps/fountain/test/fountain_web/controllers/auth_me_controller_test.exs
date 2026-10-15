defmodule FountainWeb.AuthMeControllerTest do
  use FountainWeb.ConnCase, async: true

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
               "expires_at" => nil
             } = body = json_response(conn, 200)

      assert id == user.id
      assert email == user.email
      assert role == user.role
      refute Map.has_key?(body, "comped")
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

    test "carries brokered, which is always true", %{conn: conn} do
      user = insert_verified_user()
      {_key_record, raw_key} = insert_api_key(user)

      assert %{"brokered" => true} =
               conn |> authed_with_key(raw_key) |> get("/api/auth/me") |> json_response(200)
    end

    # ADR 0086: an `"auth": "conversation"` MCP server binds the key to its
    # conversation through this, instead of trusting a header.
    test "names the conversation a sandbox callback key belongs to", %{conn: conn} do
      user = insert_verified_user()
      {key, raw_key} = insert_sprite_api_key(user)
      conv = insert_conversation(user_id: user.id)
      {:ok, _} = Fountain.Conversations.update_conversation(conv, %{callback_api_key_id: key.id})

      assert %{"conversation_id" => id} =
               conn |> authed_with_key(raw_key) |> get("/api/auth/me") |> json_response(200)

      assert id == conv.id
    end

    test "conversation_id is null for a user's key and for a rotated-away sandbox key",
         %{conn: conn} do
      user = insert_verified_user()
      {_key, user_key} = insert_api_key(user)

      assert %{"conversation_id" => nil} =
               conn |> authed_with_key(user_key) |> get("/api/auth/me") |> json_response(200)

      # A sprite key no conversation names any more.
      {_old, old_key} = insert_sprite_api_key(user)

      assert %{"conversation_id" => nil} =
               build_conn()
               |> authed_with_key(old_key)
               |> get("/api/auth/me")
               |> json_response(200)
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
