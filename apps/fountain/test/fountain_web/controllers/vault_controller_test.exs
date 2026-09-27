defmodule FountainWeb.VaultControllerTest do
  use FountainWeb.ConnCase, async: true

  setup do
    user = insert_verified_user()
    {_key_record, raw_key} = insert_api_key(user)
    {:ok, user: user, raw_key: raw_key}
  end

  describe "GET /api/vaults" do
    test "returns 200 and lists user's vaults", %{conn: conn, user: user, raw_key: raw_key} do
      vault = insert_vault(user_id: user.id)

      conn = conn |> authed_with_key(raw_key) |> get("/api/vaults")

      body = json_response(conn, 200)
      assert is_list(body["data"])
      ids = Enum.map(body["data"], & &1["id"])
      assert vault.id in ids
    end

    test "does not include vaults belonging to other users", %{conn: conn, raw_key: raw_key} do
      other_user = insert_verified_user()
      other_vault = insert_vault(user_id: other_user.id)

      conn = conn |> authed_with_key(raw_key) |> get("/api/vaults")

      body = json_response(conn, 200)
      ids = Enum.map(body["data"], & &1["id"])
      refute other_vault.id in ids
    end

    test "returns 401 without authentication", %{conn: conn} do
      conn = get(conn, "/api/vaults")
      assert json_response(conn, 401)
    end
  end

  describe "GET /api/vaults/:id" do
    test "returns 200 with the vault for the authenticated user", %{
      conn: conn,
      user: user,
      raw_key: raw_key
    } do
      vault = insert_vault(user_id: user.id)

      conn = conn |> authed_with_key(raw_key) |> get("/api/vaults/#{vault.id}")

      body = json_response(conn, 200)
      assert body["data"]["id"] == vault.id
      assert body["data"]["name"] == vault.name
    end

    test "returns 404 when the vault belongs to a different user", %{conn: conn, raw_key: raw_key} do
      other_user = insert_verified_user()
      other_vault = insert_vault(user_id: other_user.id)

      conn = conn |> authed_with_key(raw_key) |> get("/api/vaults/#{other_vault.id}")

      assert json_response(conn, 404)
    end

    test "returns 401 without authentication", %{conn: conn, user: user} do
      vault = insert_vault(user_id: user.id)
      conn = get(conn, "/api/vaults/#{vault.id}")
      assert json_response(conn, 401)
    end
  end

  describe "POST /api/vaults" do
    test "creates a vault and returns 201", %{conn: conn, raw_key: raw_key} do
      payload = %{name: "my-vault"}

      conn =
        conn
        |> authed_with_key(raw_key)
        |> post_json("/api/vaults", payload)

      body = json_response(conn, 201)
      assert body["data"]["name"] == "my-vault"
      assert body["data"]["id"]
    end

    test "returns 401 without authentication", %{conn: conn} do
      payload = %{name: "my-vault"}
      conn = post_json(conn, "/api/vaults", payload)
      assert json_response(conn, 401)
    end

    test "returns 422 when name is empty", %{conn: conn, raw_key: raw_key} do
      conn =
        conn
        |> authed_with_key(raw_key)
        |> post_json("/api/vaults", %{name: ""})

      assert json_response(conn, 422)
    end

    test "round-trips metadata", %{conn: conn, raw_key: raw_key} do
      payload = %{name: "tagged-vault", metadata: %{"managed-by" => "chant"}}

      conn =
        conn
        |> authed_with_key(raw_key)
        |> post_json("/api/vaults", payload)

      body = json_response(conn, 201)
      assert body["data"]["metadata"] == %{"managed-by" => "chant"}
    end
  end

  describe "PUT /api/vaults/:id" do
    test "updates the vault and returns 200", %{conn: conn, user: user, raw_key: raw_key} do
      vault = insert_vault(user_id: user.id)

      conn =
        conn
        |> authed_with_key(raw_key)
        |> put_json("/api/vaults/#{vault.id}", %{name: "updated-vault"})

      body = json_response(conn, 200)
      assert body["data"]["name"] == "updated-vault"
      assert body["data"]["id"] == vault.id
    end

    test "returns 404 when the vault belongs to a different user", %{conn: conn, raw_key: raw_key} do
      other_user = insert_verified_user()
      other_vault = insert_vault(user_id: other_user.id)

      conn =
        conn
        |> authed_with_key(raw_key)
        |> put_json("/api/vaults/#{other_vault.id}", %{name: "hacked"})

      assert json_response(conn, 404)
    end

    test "returns 401 without authentication", %{conn: conn, user: user} do
      vault = insert_vault(user_id: user.id)
      conn = put_json(conn, "/api/vaults/#{vault.id}", %{name: "updated"})
      assert json_response(conn, 401)
    end

    test "returns 422 when name is empty", %{conn: conn, user: user, raw_key: raw_key} do
      vault = insert_vault(user_id: user.id)

      conn =
        conn
        |> authed_with_key(raw_key)
        |> put_json("/api/vaults/#{vault.id}", %{name: ""})

      assert json_response(conn, 422)
    end
  end

  describe "DELETE /api/vaults/:id" do
    test "deletes the vault and returns 204", %{conn: conn, user: user, raw_key: raw_key} do
      vault = insert_vault(user_id: user.id)

      conn = conn |> authed_with_key(raw_key) |> delete("/api/vaults/#{vault.id}")

      assert conn.status == 204
    end

    test "returns 404 when the vault belongs to a different user", %{conn: conn, raw_key: raw_key} do
      other_user = insert_verified_user()
      other_vault = insert_vault(user_id: other_user.id)

      conn = conn |> authed_with_key(raw_key) |> delete("/api/vaults/#{other_vault.id}")

      assert json_response(conn, 404)
    end

    test "returns 401 without authentication", %{conn: conn, user: user} do
      vault = insert_vault(user_id: user.id)
      conn = delete(conn, "/api/vaults/#{vault.id}")
      assert json_response(conn, 401)
    end
  end

  describe "POST /api/vaults/:id/copy" do
    setup %{user: user} do
      source = insert_vault(user_id: user.id, description: "project", metadata: %{"p" => "1"})
      insert_vault_secret(source, key: "API_TOKEN", value: "copy-api-token-plaintext")
      insert_vault_secret(source, key: "DB_PASSWORD", value: "copy-db-password-plaintext")
      {:ok, source: source}
    end

    test "creates a copy and answers 201 in the create shape", %{
      conn: conn,
      user: user,
      raw_key: raw_key,
      source: source
    } do
      conn =
        conn
        |> authed_with_key(raw_key)
        |> post_json("/api/vaults/#{source.id}/copy", %{name: "track-vault"})

      body = json_response(conn, 201)
      data = body["data"]
      assert data["name"] == "track-vault"
      assert data["id"] != source.id
      assert data["description"] == "project"
      assert data["metadata"] == %{"p" => "1"}
      assert data["secret_count"] == 2

      raw = conn.resp_body
      refute raw =~ "copy-api-token-plaintext"
      refute raw =~ "copy-db-password-plaintext"

      # Usable where secrets are consumed, not merely listed.
      copy = Fountain.Vaults.get_vault(data["id"], user.id)
      {:ok, dek} = Fountain.Crypto.load_tenant_key(user.id)

      assert Fountain.Conversations.SpriteEnv.merge_secrets(nil, copy, dek) == %{
               "API_TOKEN" => "copy-api-token-plaintext",
               "DB_PASSWORD" => "copy-db-password-plaintext"
             }
    end

    test "the secret listing of the copy shows keys only", %{
      conn: conn,
      raw_key: raw_key,
      source: source
    } do
      copy_conn =
        conn
        |> authed_with_key(raw_key)
        |> post_json("/api/vaults/#{source.id}/copy", %{name: "track-vault-2"})

      id = json_response(copy_conn, 201)["data"]["id"]

      list_conn =
        build_conn() |> authed_with_key(raw_key) |> get("/api/vaults/#{id}/secrets")

      keys = json_response(list_conn, 200)["data"] |> Enum.map(& &1["key"]) |> Enum.sort()
      assert keys == ["API_TOKEN", "DB_PASSWORD"]
      refute list_conn.resp_body =~ "plaintext"
    end

    test "returns 404 for another account's vault and creates nothing", %{
      conn: conn,
      user: user,
      raw_key: raw_key
    } do
      other_user = insert_verified_user()
      other_vault = insert_vault(user_id: other_user.id)
      insert_vault_secret(other_vault, key: "THEIRS", value: "not-yours")

      conn =
        conn
        |> authed_with_key(raw_key)
        |> post_json("/api/vaults/#{other_vault.id}/copy", %{name: "stolen"})

      assert json_response(conn, 404)["error"] == "not_found"
      assert Fountain.Vaults.get_vault_by_name("stolen", user.id) == nil
      assert Fountain.Vaults.get_vault_by_name("stolen", other_user.id) == nil
    end

    test "returns 404 for a missing or malformed source id", %{conn: conn, raw_key: raw_key} do
      for id <- [Ecto.UUID.generate(), "not-a-uuid"] do
        conn =
          conn
          |> authed_with_key(raw_key)
          |> post_json("/api/vaults/#{id}/copy", %{name: "orphan"})

        assert json_response(conn, 404)["error"] == "not_found"
      end
    end

    test "returns 422 when name is missing or taken", %{
      conn: conn,
      user: user,
      raw_key: raw_key,
      source: source
    } do
      missing =
        conn |> authed_with_key(raw_key) |> post_json("/api/vaults/#{source.id}/copy", %{})

      assert json_response(missing, 422)

      taken =
        build_conn()
        |> authed_with_key(raw_key)
        |> post_json("/api/vaults/#{source.id}/copy", %{name: source.name})

      assert json_response(taken, 422)
      assert length(Fountain.Vaults.list_vaults(user.id)) == 1
    end

    test "returns 422 naming the key when a secret cannot be copied", %{
      conn: conn,
      user: user,
      raw_key: raw_key,
      source: source
    } do
      import Ecto.Query

      Fountain.Repo.update_all(
        from(s in Fountain.Vaults.VaultSecret,
          where: s.vault_id == ^source.id and s.key == "DB_PASSWORD"
        ),
        set: [value_ciphertext: :crypto.strong_rand_bytes(48)]
      )

      conn =
        conn
        |> authed_with_key(raw_key)
        |> post_json("/api/vaults/#{source.id}/copy", %{name: "track-broken"})

      body = json_response(conn, 422)
      assert body["error"] == "secret_not_copyable"
      assert body["message"] =~ "DB_PASSWORD"
      assert Fountain.Vaults.get_vault_by_name("track-broken", user.id) == nil
    end

    test "returns 401 without authentication", %{conn: conn, source: source} do
      conn = post_json(conn, "/api/vaults/#{source.id}/copy", %{name: "x"})
      assert json_response(conn, 401)
    end
  end
end
