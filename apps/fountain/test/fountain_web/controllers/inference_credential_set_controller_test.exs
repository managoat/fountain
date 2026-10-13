defmodule FountainWeb.InferenceCredentialSetControllerTest do
  @moduledoc """
  `/api/account/inference-credential-sets` (ADR 0053 decision 1).

  Behind `:require_full_scope` like every other account-level write: a
  sandbox's per-conversation token must not be able to point the account's
  agents at a different provider account.
  """

  use FountainWeb.ConnCase, async: true

  alias Fountain.Crypto
  alias Fountain.InferenceCredentials

  setup %{conn: conn} do
    user = insert_verified_user()
    {_rec, key} = insert_api_key(user)
    %{conn: authed_with_key(conn, key), user: user}
  end

  describe "GET /api/account/inference-credential-sets" do
    test "is empty for an account that has never set a credential", %{conn: conn} do
      assert %{"data" => []} =
               conn |> get("/api/account/inference-credential-sets") |> json_response(200)
    end

    test "lists the default first, then by name, and never a value", %{conn: conn, user: user} do
      {:ok, dek} = Crypto.load_tenant_key(user.id)

      {:ok, _} =
        InferenceCredentials.put_credential(user.id, dek, :anthropic_api_key, "sk-secret")

      {:ok, _} = InferenceCredentials.create_set(user.id, "Zulu")
      {:ok, _} = InferenceCredentials.create_set(user.id, "Alpha")

      body = conn |> get("/api/account/inference-credential-sets") |> json_response(200)

      assert ["Default", "Alpha", "Zulu"] = Enum.map(body["data"], & &1["name"])
      assert [true, false, false] = Enum.map(body["data"], & &1["is_default"])

      [default | _] = body["data"]
      assert default["providers"] == ["anthropic_api_key"]
      refute inspect(body) =~ "sk-secret"
    end
  end

  describe "POST /api/account/inference-credential-sets" do
    test "creates a set, and the first one an account has is its default", %{conn: conn} do
      body =
        conn
        |> post_json("/api/account/inference-credential-sets", %{"name" => "Work"})
        |> json_response(201)

      assert %{"name" => "Work", "is_default" => true, "providers" => []} = body["data"]
    end

    test "a second is not the default", %{conn: conn} do
      _ = post_json(conn, "/api/account/inference-credential-sets", %{"name" => "Work"})

      body =
        conn
        |> post_json("/api/account/inference-credential-sets", %{"name" => "Personal"})
        |> json_response(201)

      assert body["data"]["is_default"] == false
    end

    test "a duplicate name is 422, and a missing one is refused by the spec", %{conn: conn} do
      _ = post_json(conn, "/api/account/inference-credential-sets", %{"name" => "Work"})

      assert conn
             |> post_json("/api/account/inference-credential-sets", %{"name" => "Work"})
             |> json_response(422)

      assert conn
             |> post_json("/api/account/inference-credential-sets", %{})
             |> json_response(422)
    end
  end

  describe "PATCH /api/account/inference-credential-sets/:id" do
    setup %{user: user} do
      {:ok, first} = InferenceCredentials.create_set(user.id, "Work")
      {:ok, second} = InferenceCredentials.create_set(user.id, "Personal")
      %{first: first, second: second}
    end

    test "renames", %{conn: conn, second: second} do
      body =
        conn
        |> patch_json("/api/account/inference-credential-sets/#{second.id}", %{
          "name" => "Renamed"
        })
        |> json_response(200)

      assert body["data"]["name"] == "Renamed"
    end

    test "promotes to default, and the old default steps down", %{
      conn: conn,
      first: first,
      second: second
    } do
      body =
        conn
        |> patch_json("/api/account/inference-credential-sets/#{second.id}", %{
          "is_default" => true
        })
        |> json_response(200)

      assert body["data"]["is_default"] == true
      refute Fountain.Repo.reload!(first).is_default
    end

    test "renames and promotes in one call", %{conn: conn, second: second} do
      body =
        conn
        |> patch_json("/api/account/inference-credential-sets/#{second.id}", %{
          "name" => "Both",
          "is_default" => true
        })
        |> json_response(200)

      assert %{"name" => "Both", "is_default" => true} = body["data"]
    end

    # There is no such state: the partial unique index allows one default per
    # account and nothing allows zero. Refused rather than ignored, so a
    # client that believes it demoted a set finds out here.
    test "is_default: false is refused", %{conn: conn, first: first} do
      body =
        conn
        |> patch_json("/api/account/inference-credential-sets/#{first.id}", %{
          "is_default" => false
        })
        |> json_response(422)

      assert body["error"] == "cannot_undefault"
      assert Fountain.Repo.reload!(first).is_default
    end

    test "another tenant's set is 404, not 403", %{conn: conn} do
      other = insert_verified_user()
      {:ok, theirs} = InferenceCredentials.create_set(other.id, "Theirs")

      assert conn
             |> patch_json("/api/account/inference-credential-sets/#{theirs.id}", %{
               "name" => "Mine"
             })
             |> json_response(404)

      assert Fountain.Repo.reload!(theirs).name == "Theirs"
    end
  end

  describe "DELETE /api/account/inference-credential-sets/:id" do
    setup %{user: user} do
      {:ok, first} = InferenceCredentials.create_set(user.id, "Work")
      {:ok, second} = InferenceCredentials.create_set(user.id, "Personal")
      %{first: first, second: second}
    end

    test "deletes one that is not the default", %{conn: conn, second: second} do
      assert conn
             |> delete("/api/account/inference-credential-sets/#{second.id}")
             |> response(204)

      assert is_nil(Fountain.Repo.reload(second))
    end

    test "refuses the default with a reason a client can branch on", %{conn: conn, first: first} do
      body =
        conn
        |> delete("/api/account/inference-credential-sets/#{first.id}")
        |> json_response(422)

      assert body["error"] == "credential_set_is_default"
      assert body["message"] =~ "promote another"
      assert body["reason"] == "is_default"
      refute is_nil(Fountain.Repo.reload(first))
    end

    test "another tenant's set is 404", %{conn: conn} do
      other = insert_verified_user()
      {:ok, theirs} = InferenceCredentials.create_set(other.id, "Theirs")

      assert conn
             |> delete("/api/account/inference-credential-sets/#{theirs.id}")
             |> json_response(404)

      refute is_nil(Fountain.Repo.reload(theirs))
    end
  end

  test "malformed set ids are missing resources", %{conn: conn} do
    assert conn
           |> patch_json("/api/account/inference-credential-sets/nope", %{"name" => "Mine"})
           |> json_response(404)

    assert conn |> delete("/api/account/inference-credential-sets/nope") |> json_response(404)
  end

  test "agent create contract accepts and returns credential selection", %{conn: conn, user: user} do
    {:ok, set} = InferenceCredentials.create_set(user.id, "Selected")

    params = %{
      "name" => "Selected agent",
      "runtime" => "claude",
      "model" => "anthropic/claude-sonnet-5",
      "inference_credential_id" => set.id,
      "allowed_inference_credential_ids" => [set.id]
    }

    schema = FountainWeb.Schemas.AgentRequest.schema()
    assert Map.has_key?(schema.properties, :inference_credential_id)
    assert Map.has_key?(schema.properties, :allowed_inference_credential_ids)
    body = conn |> post_json("/api/agents", params) |> json_response(201)
    assert body["data"]["inference_credential_id"] == set.id
    assert body["data"]["allowed_inference_credential_ids"] == [set.id]

    for field <- [
          :inference_credential_id,
          :allowed_inference_credential_ids,
          :allowed_environment_ids
        ] do
      refute Map.has_key?(FountainWeb.Schemas.Environment.schema().properties, field)
    end
  end

  describe "scope" do
    test "a sprite-scoped key cannot reach any of it", %{user: user} do
      {_rec, raw} = insert_sprite_api_key(user)
      conn = authed_with_key(build_conn(), raw)

      assert conn |> get("/api/account/inference-credential-sets") |> json_response(403)

      assert conn
             |> post_json("/api/account/inference-credential-sets", %{"name" => "Nope"})
             |> json_response(403)
    end
  end
end
