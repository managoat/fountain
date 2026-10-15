defmodule FountainWeb.VaultSecretControllerTest do
  use FountainWeb.ConnCase, async: true
  require Ecto.Query

  setup do
    user = insert_verified_user()
    {_key_record, raw_key} = insert_api_key(user)
    {:ok, user: user, raw_key: raw_key}
  end

  describe "GET /api/vaults/:vault_id/secrets" do
    test "returns 200 with a list of secrets for the vault", %{
      conn: conn,
      user: user,
      raw_key: raw_key
    } do
      vault = insert_vault(user_id: user.id)
      secret = insert_vault_secret(vault, key: "MY_KEY")

      conn = conn |> authed_with_key(raw_key) |> get("/api/vaults/#{vault.id}/secrets")

      body = json_response(conn, 200)
      assert is_list(body["data"])
      keys = Enum.map(body["data"], & &1["key"])
      assert secret.key in keys
    end

    test "returns 404 when vault belongs to another user", %{conn: conn, raw_key: raw_key} do
      other_user = insert_verified_user()
      other_vault = insert_vault(user_id: other_user.id)

      conn = conn |> authed_with_key(raw_key) |> get("/api/vaults/#{other_vault.id}/secrets")

      assert json_response(conn, 404)
    end
  end

  describe "POST /api/vaults/:vault_id/secrets" do
    test "creates a vault secret and returns 201", %{conn: conn, user: user, raw_key: raw_key} do
      vault = insert_vault(user_id: user.id)

      conn =
        conn
        |> authed_with_key(raw_key)
        |> post_json("/api/vaults/#{vault.id}/secrets", %{key: "API_TOKEN", value: "t0k3n"})

      body = json_response(conn, 201)
      assert body["data"]["key"] == "API_TOKEN"
      assert body["data"]["expires_at"] == nil
      refute Map.has_key?(body["data"], "value")
    end

    test "accepts and returns an optional expiry", %{conn: conn, user: user, raw_key: raw_key} do
      vault = insert_vault(user_id: user.id)

      conn =
        conn
        |> authed_with_key(raw_key)
        |> post_json("/api/vaults/#{vault.id}/secrets", %{
          key: "API_TOKEN",
          value: "t0k3n",
          expires_at: "2027-01-15T00:00:00Z"
        })

      body = json_response(conn, 201)
      assert body["data"]["expires_at"] == "2027-01-15T00:00:00Z"
    end

    test "a write without expires_at keeps the stored expiry; null clears it",
         %{conn: conn, user: user, raw_key: raw_key} do
      vault = insert_vault(user_id: user.id)

      post = fn body ->
        conn |> authed_with_key(raw_key) |> post_json("/api/vaults/#{vault.id}/secrets", body)
      end

      post.(%{key: "API_TOKEN", value: "v1", expires_at: "2027-01-15T00:00:00Z"})

      # Rotating the value with the key absent is not a request to change the
      # expiry — the console's blank date field relies on the same rule.
      kept = post.(%{key: "API_TOKEN", value: "v2"})
      assert json_response(kept, 201)["data"]["expires_at"] == "2027-01-15T00:00:00Z"

      # Clearing is explicit: the key present and null.
      cleared = post.(%{key: "API_TOKEN", value: "v3", expires_at: nil})
      assert json_response(cleared, 201)["data"]["expires_at"] == nil

      [secret] = Fountain.Vaults._unsafe_list_secrets(vault)
      assert secret.expires_at == nil
    end

    test "returns 404 when vault belongs to another user", %{conn: conn, raw_key: raw_key} do
      other_user = insert_verified_user()
      other_vault = insert_vault(user_id: other_user.id)

      conn =
        conn
        |> authed_with_key(raw_key)
        |> post_json("/api/vaults/#{other_vault.id}/secrets", %{key: "API_TOKEN", value: "t0k3n"})

      assert json_response(conn, 404)
    end
  end

  describe "PATCH /api/vaults/:vault_id/secrets/:id" do
    test "sets, extends and clears expiry without changing ciphertext or exposing values", %{
      conn: conn,
      user: user,
      raw_key: key
    } do
      vault = insert_vault(user_id: user.id)
      secret = insert_vault_secret(vault, key: "TOKEN", value: "expiry-test-secret")

      patch_expiry = fn attrs ->
        conn |> authed_with_key(key) |> patch_json("/api/vaults/#{vault.id}/secrets/TOKEN", attrs)
      end

      for expiry <- ["2027-01-15T00:00:00Z", "2027-02-15T00:00:00Z", nil] do
        response = patch_expiry.(%{expires_at: expiry})
        body = json_response(response, 200)["data"]
        assert body["expires_at"] == expiry
        refute Map.has_key?(body, "value")
        refute response.resp_body =~ "expiry-test-secret"
        stored = Fountain.Repo.reload!(secret)
        assert stored.value_ciphertext == secret.value_ciphertext
      end

      events =
        Fountain.Repo.all(
          Ecto.Query.from(a in Fountain.Audit.Event,
            where: a.user_id == ^user.id and a.action == "vault.secret.update"
          )
        )

      assert length(events) == 3
      assert Enum.all?(events, &(&1.actor == "api" and &1.metadata == %{"key" => "TOKEN"}))
    end

    test "omission and identical expiry keep the expiry and create no audit mutation",
         %{
           conn: conn,
           user: user,
           raw_key: key
         } do
      vault = insert_vault(user_id: user.id)
      insert_vault_secret(vault, key: "TOKEN", expires_at: "2027-01-15T00:00:00Z")

      for attrs <- [%{}, %{expires_at: "2027-01-15T00:00:00Z"}] do
        response =
          conn
          |> authed_with_key(key)
          |> patch_json("/api/vaults/#{vault.id}/secrets/TOKEN", attrs)

        assert json_response(response, 200)["data"]["expires_at"] == "2027-01-15T00:00:00Z"
      end

      refute Fountain.Repo.exists?(
               Ecto.Query.from(a in Fountain.Audit.Event,
                 where: a.user_id == ^user.id and a.action == "vault.secret.update"
               )
             )
    end

    test "rejects invalid expiry and value or identity fields without changing the secret", %{
      conn: conn,
      user: user,
      raw_key: key
    } do
      vault = insert_vault(user_id: user.id)
      secret = insert_vault_secret(vault, key: "TOKEN")

      for attrs <- [
            %{expires_at: "invalid"},
            %{value: "replacement"},
            %{key: "OTHER"},
            %{vault_id: Ecto.UUID.generate()}
          ] do
        response =
          conn
          |> authed_with_key(key)
          |> patch_json("/api/vaults/#{vault.id}/secrets/TOKEN", attrs)

        assert json_response(response, 422)
        assert Fountain.Repo.reload!(secret).value_ciphertext == secret.value_ciphertext
        assert Fountain.Repo.reload!(secret).expires_at == nil
      end
    end

    test "cannot update another tenant's secret or create a missing one", %{
      conn: conn,
      user: user,
      raw_key: key
    } do
      mine = insert_vault(user_id: user.id)
      foreign = insert_vault(user_id: insert_verified_user().id)
      secret = insert_vault_secret(foreign, key: "TOKEN")

      for vault_id <- [foreign.id, mine.id, Ecto.UUID.generate()] do
        response =
          conn
          |> authed_with_key(key)
          |> patch_json("/api/vaults/#{vault_id}/secrets/TOKEN", %{expires_at: nil})

        assert json_response(response, 404)
      end

      assert Fountain.Repo.reload!(secret).value_ciphertext == secret.value_ciphertext
      assert Fountain.Vaults._unsafe_list_secrets(mine) == []
    end
  end

  describe "DELETE /api/vaults/:vault_id/secrets/:id" do
    test "deletes a vault secret by key and returns 204", %{
      conn: conn,
      user: user,
      raw_key: raw_key
    } do
      vault = insert_vault(user_id: user.id)
      secret = insert_vault_secret(vault, key: "TO_DELETE")

      conn =
        conn
        |> authed_with_key(raw_key)
        |> delete("/api/vaults/#{vault.id}/secrets/#{secret.key}")

      assert conn.status == 204
    end

    test "returns 404 when vault belongs to another user", %{conn: conn, raw_key: raw_key} do
      other_user = insert_verified_user()
      other_vault = insert_vault(user_id: other_user.id)
      other_secret = insert_vault_secret(other_vault, key: "OTHER_KEY")

      conn =
        conn
        |> authed_with_key(raw_key)
        |> delete("/api/vaults/#{other_vault.id}/secrets/#{other_secret.key}")

      assert json_response(conn, 404)
    end

    test "returns 404 when the secret key does not exist", %{
      conn: conn,
      user: user,
      raw_key: raw_key
    } do
      vault = insert_vault(user_id: user.id)

      conn =
        conn
        |> authed_with_key(raw_key)
        |> delete("/api/vaults/#{vault.id}/secrets/NONEXISTENT_KEY")

      assert json_response(conn, 404)
    end
  end
end
