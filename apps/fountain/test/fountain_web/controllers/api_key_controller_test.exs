defmodule FountainWeb.ApiKeyControllerTest do
  use FountainWeb.ConnCase, async: true
  use Mimic

  alias Fountain.Accounts

  describe "POST /api/auth/api-keys" do
    test "creates a key and returns it in full once", %{conn: conn} do
      user = insert_verified_user()
      {_record, raw_key} = insert_api_key(user)

      conn =
        conn
        |> authed_with_key(raw_key)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> post("/api/auth/api-keys", Jason.encode!(%{name: "CI pipeline"}))

      body = json_response(conn, 201)
      assert body["key"] =~ "ftn_"
      assert body["name"] == "CI pipeline"
      assert body["prefix"]
      assert body["id"]
    end

    test "returns 422 when name is missing", %{conn: conn} do
      user = insert_verified_user()
      {_record, raw_key} = insert_api_key(user)

      conn =
        conn
        |> authed_with_key(raw_key)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> post("/api/auth/api-keys", Jason.encode!(%{}))

      assert json_response(conn, 422)
    end

    test "returns 422 when name is empty string", %{conn: conn} do
      user = insert_verified_user()
      {_record, raw_key} = insert_api_key(user)

      conn =
        conn
        |> authed_with_key(raw_key)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> post("/api/auth/api-keys", Jason.encode!(%{name: ""}))

      assert json_response(conn, 422)
    end

    test "returns 401 without valid API key", %{conn: conn} do
      conn =
        conn
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> post("/api/auth/api-keys", Jason.encode!(%{name: "test"}))

      assert json_response(conn, 401)
    end

    test "returns 422 with changeset error when Accounts.create_api_key fails", %{conn: conn} do
      user = insert_verified_user()
      {_record, raw_key} = insert_api_key(user)

      # Arity 3: the controller passes `Audited.attribution/1` through so the
      # context can attribute the mint it audits (#542).
      stub(Fountain.Accounts, :create_api_key, fn _user_id, _name, _opts ->
        cs = %Ecto.Changeset{valid?: false, errors: [name: {"has already been taken", []}]}
        {:error, cs}
      end)

      conn =
        conn
        |> authed_with_key(raw_key)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> post("/api/auth/api-keys", Jason.encode!(%{name: "CI pipeline"}))

      assert json_response(conn, 422)
    end
  end

  describe "DELETE /api/auth/api-keys/:id" do
    test "revokes the key and returns 204", %{conn: conn} do
      user = insert_verified_user()
      {_auth_record, auth_raw} = insert_api_key(user, "auth-key")
      {target_record, target_raw} = insert_api_key(user, "target-key")

      conn =
        conn
        |> authed_with_key(auth_raw)
        |> delete("/api/auth/api-keys/#{target_record.id}")

      assert conn.status == 204

      # Key is now revoked — authentication with the revoked key fails
      assert {:error, :revoked} = Accounts.get_user_by_api_key(target_raw)
    end

    test "returns 404 when key does not belong to user", %{conn: conn} do
      user_a = insert_verified_user()
      user_b = insert_verified_user()
      {key_b, _} = insert_api_key(user_b)
      {_auth, raw_a} = insert_api_key(user_a)

      conn =
        conn
        |> authed_with_key(raw_a)
        |> delete("/api/auth/api-keys/#{key_b.id}")

      assert json_response(conn, 404)
    end

    test "returns 401 without valid API key", %{conn: conn} do
      conn = delete(conn, "/api/auth/api-keys/#{Ecto.UUID.generate()}")
      assert json_response(conn, 401)
    end
  end

  describe "GET /api/auth/api-keys" do
    test "lists active keys newest-first with metadata only", %{conn: conn} do
      user = insert_verified_user()
      {first, raw_key} = insert_api_key(user, "first-key")
      {second, _} = insert_api_key(user, "second-key")

      # inserted_at is second-granular; backdate the first key so the
      # newest-first ordering assertion can't tie.
      first =
        first
        |> Ecto.Changeset.change(inserted_at: DateTime.add(first.inserted_at, -60, :second))
        |> Fountain.Repo.update!()

      conn =
        conn
        |> authed_with_key(raw_key)
        |> get("/api/auth/api-keys")

      %{"data" => keys} = json_response(conn, 200)
      assert Enum.map(keys, & &1["id"]) == [second.id, first.id]

      for key <- keys do
        assert key["name"]
        assert key["prefix"]
        assert key["created_at"]
        assert Map.has_key?(key, "last_used_at")
        refute Map.has_key?(key, "key")
        refute Map.has_key?(key, "key_hash")
      end
    end

    test "excludes revoked keys", %{conn: conn} do
      user = insert_verified_user()
      {_auth, raw_key} = insert_api_key(user, "auth-key")
      {revoked, _} = insert_api_key(user, "revoked-key")
      {:ok, _} = Accounts.revoke_api_key(user.id, revoked.id)

      conn =
        conn
        |> authed_with_key(raw_key)
        |> get("/api/auth/api-keys")

      %{"data" => keys} = json_response(conn, 200)
      refute Enum.any?(keys, &(&1["id"] == revoked.id))
    end

    test "only returns the authenticated user's keys", %{conn: conn} do
      user_a = insert_verified_user()
      user_b = insert_verified_user()
      {_key_b, _} = insert_api_key(user_b, "other-tenant")
      {key_a, raw_a} = insert_api_key(user_a, "mine")

      conn =
        conn
        |> authed_with_key(raw_a)
        |> get("/api/auth/api-keys")

      %{"data" => keys} = json_response(conn, 200)
      assert Enum.map(keys, & &1["id"]) == [key_a.id]
    end

    test "returns 401 without valid API key", %{conn: conn} do
      conn = get(conn, "/api/auth/api-keys")
      assert json_response(conn, 401)
    end
  end

  describe "GET /api/auth/me" do
    test "returns user identity for authenticated request", %{conn: conn} do
      user = insert_verified_user()
      {_record, raw_key} = insert_api_key(user)

      conn =
        conn
        |> authed_with_key(raw_key)
        |> get("/api/auth/me")

      body = json_response(conn, 200)
      assert body["id"] == user.id
      assert body["email"] == user.email
      assert body["role"] == "user"
      assert Map.has_key?(body, "comped")
    end

    test "returns 401 without credentials", %{conn: conn} do
      conn = get(conn, "/api/auth/me")
      assert json_response(conn, 401)
    end
  end
end
