defmodule FountainWeb.EnvironmentControllerTest do
  use FountainWeb.ConnCase, async: true

  setup do
    user = insert_verified_user()
    {_key_record, raw_key} = insert_api_key(user)
    {:ok, user: user, raw_key: raw_key}
  end

  describe "GET /api/environments" do
    test "returns 200 and lists user's environments", %{conn: conn, user: user, raw_key: raw_key} do
      env = insert_env(user_id: user.id)

      conn = conn |> authed_with_key(raw_key) |> get("/api/environments")

      body = json_response(conn, 200)
      assert is_list(body["data"])
      ids = Enum.map(body["data"], & &1["id"])
      assert env.id in ids
    end

    test "does not include environments belonging to other users", %{conn: conn, raw_key: raw_key} do
      other_user = insert_verified_user()
      other_env = insert_env(user_id: other_user.id)

      conn = conn |> authed_with_key(raw_key) |> get("/api/environments")

      body = json_response(conn, 200)
      ids = Enum.map(body["data"], & &1["id"])
      refute other_env.id in ids
    end

    test "returns 401 without authentication", %{conn: conn} do
      conn = get(conn, "/api/environments")
      assert json_response(conn, 401)
    end
  end

  describe "GET /api/environments/:id" do
    test "returns 200 with the environment for the authenticated user", %{
      conn: conn,
      user: user,
      raw_key: raw_key
    } do
      env = insert_env(user_id: user.id)

      conn = conn |> authed_with_key(raw_key) |> get("/api/environments/#{env.id}")

      body = json_response(conn, 200)
      assert body["data"]["id"] == env.id
      assert body["data"]["name"] == env.name
    end

    test "returns 404 when the environment belongs to a different user", %{
      conn: conn,
      raw_key: raw_key
    } do
      other_user = insert_verified_user()
      other_env = insert_env(user_id: other_user.id)

      conn = conn |> authed_with_key(raw_key) |> get("/api/environments/#{other_env.id}")

      assert json_response(conn, 404)
    end

    test "returns 401 without authentication", %{conn: conn, user: user} do
      env = insert_env(user_id: user.id)
      conn = get(conn, "/api/environments/#{env.id}")
      assert json_response(conn, 401)
    end
  end

  describe "POST /api/environments" do
    test "creates an environment and returns 201", %{conn: conn, raw_key: raw_key} do
      payload = %{name: "my-env"}

      conn =
        conn
        |> authed_with_key(raw_key)
        |> post_json("/api/environments", payload)

      body = json_response(conn, 201)
      assert body["data"]["name"] == "my-env"
      assert body["data"]["id"]
    end

    test "returns 401 without authentication", %{conn: conn} do
      payload = %{name: "my-env"}
      conn = post_json(conn, "/api/environments", payload)
      assert json_response(conn, 401)
    end

    test "round-trips metadata", %{conn: conn, raw_key: raw_key} do
      payload = %{name: "tagged-env", metadata: %{"managed-by" => "chant", "team" => "payments"}}

      conn =
        conn
        |> authed_with_key(raw_key)
        |> post_json("/api/environments", payload)

      body = json_response(conn, 201)
      assert body["data"]["metadata"] == %{"managed-by" => "chant", "team" => "payments"}
    end
  end

  test "setup timeout round-trips without allowing another tenant to update it", %{
    conn: conn,
    raw_key: raw_key
  } do
    created =
      conn
      |> authed_with_key(raw_key)
      |> post_json("/api/environments", %{name: "long-setup", setup_timeout_seconds: 900})
      |> json_response(201)

    id = created["data"]["id"]
    assert created["data"]["setup_timeout_seconds"] == 900

    updated =
      build_conn()
      |> authed_with_key(raw_key)
      |> put_json("/api/environments/#{id}", %{setup_timeout_seconds: 600})
      |> json_response(200)

    assert updated["data"]["setup_timeout_seconds"] == 600
    {_other_key, other_raw} = insert_api_key(insert_verified_user())

    denied =
      build_conn()
      |> authed_with_key(other_raw)
      |> put_json("/api/environments/#{id}", %{setup_timeout_seconds: 1})

    assert json_response(denied, 404)

    fetched =
      build_conn()
      |> authed_with_key(raw_key)
      |> get("/api/environments/#{id}")
      |> json_response(200)

    assert fetched["data"]["setup_timeout_seconds"] == 600
  end

  test "setup timeout outside the allowed range is refused by the API", %{
    conn: conn,
    raw_key: raw_key
  } do
    response =
      conn
      |> authed_with_key(raw_key)
      |> post_json("/api/environments", %{name: "unbounded-setup", setup_timeout_seconds: 901})

    assert json_response(response, 422)
  end

  describe "PUT /api/environments/:id" do
    test "updates the environment and returns 200", %{conn: conn, user: user, raw_key: raw_key} do
      env = insert_env(user_id: user.id)

      conn =
        conn
        |> authed_with_key(raw_key)
        |> put_json("/api/environments/#{env.id}", %{name: "updated-env"})

      body = json_response(conn, 200)
      assert body["data"]["name"] == "updated-env"
      assert body["data"]["id"] == env.id
    end

    test "returns 404 when the environment belongs to a different user", %{
      conn: conn,
      raw_key: raw_key
    } do
      other_user = insert_verified_user()
      other_env = insert_env(user_id: other_user.id)

      conn =
        conn
        |> authed_with_key(raw_key)
        |> put_json("/api/environments/#{other_env.id}", %{name: "hacked"})

      assert json_response(conn, 404)
    end

    test "returns 401 without authentication", %{conn: conn, user: user} do
      env = insert_env(user_id: user.id)
      conn = put_json(conn, "/api/environments/#{env.id}", %{name: "updated"})
      assert json_response(conn, 401)
    end

    test "returns 422 when name is empty string", %{conn: conn, user: user, raw_key: raw_key} do
      env = insert_env(user_id: user.id)

      conn =
        conn
        |> authed_with_key(raw_key)
        |> put_json("/api/environments/#{env.id}", %{name: ""})

      assert json_response(conn, 422)
    end

    test "returns 422 naming checkpoint_id, which was removed", %{
      conn: conn,
      user: user,
      raw_key: raw_key
    } do
      env = insert_env(user_id: user.id)

      conn =
        conn
        |> authed_with_key(raw_key)
        |> put_json("/api/environments/#{env.id}", %{checkpoint_id: "ckpt_1"})

      body = json_response(conn, 422)
      assert inspect(body) =~ "checkpoint_id"
      assert inspect(body) =~ "environment checkpoints no longer exist"
    end

    test "returns 422 naming cache_enabled and build_script, which were removed", %{
      conn: conn,
      user: user,
      raw_key: raw_key
    } do
      env = insert_env(user_id: user.id)

      conn =
        conn
        |> authed_with_key(raw_key)
        |> put_json("/api/environments/#{env.id}", %{cache_enabled: true, build_script: "make"})

      body = inspect(json_response(conn, 422))
      assert body =~ "the environment layer cache no longer exists"
      assert body =~ "put reusable setup in setup_script"
    end
  end

  describe "DELETE /api/environments/:id" do
    test "deletes the environment and returns 204", %{conn: conn, user: user, raw_key: raw_key} do
      env = insert_env(user_id: user.id)

      conn = conn |> authed_with_key(raw_key) |> delete("/api/environments/#{env.id}")

      assert conn.status == 204
    end

    test "returns 404 when the environment belongs to a different user", %{
      conn: conn,
      raw_key: raw_key
    } do
      other_user = insert_verified_user()
      other_env = insert_env(user_id: other_user.id)

      conn = conn |> authed_with_key(raw_key) |> delete("/api/environments/#{other_env.id}")

      assert json_response(conn, 404)
    end

    test "returns 401 without authentication", %{conn: conn, user: user} do
      env = insert_env(user_id: user.id)
      conn = delete(conn, "/api/environments/#{env.id}")
      assert json_response(conn, 401)
    end
  end
end
