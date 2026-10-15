defmodule FountainWeb.AgentAvatarApiTest do
  @moduledoc """
  Agent avatars over a bearer token (#528).

  Upload and delete lived only in the agents LiveView, and even reading the
  bytes required a session. The session route went with the console's agent
  pages (ADR 0076), so this is the only door now.
  """

  use FountainWeb.ConnCase, async: true

  alias Fountain.Agents

  # A 1x1 PNG.
  @png Base.decode64!(
         "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
       )

  setup do
    user = insert_verified_user()
    {_rec, key} = insert_api_key(user)
    agent = insert_agent(user_id: user.id)
    {:ok, user: user, key: key, agent: agent}
  end

  defp put_raw(conn, key, agent, media_type, body) do
    conn
    |> authed_with_key(key)
    |> put_req_header("content-type", media_type)
    |> put("/api/agents/#{agent.id}/avatar", body)
  end

  describe "PUT /api/agents/:id/avatar" do
    test "stores raw image bytes and reports the media type on the agent", %{
      conn: conn,
      user: user,
      key: key,
      agent: agent
    } do
      body = conn |> put_raw(key, agent, "image/png", @png) |> json_response(200)

      assert body["data"]["avatar_media_type"] == "image/png"
      assert Agents.get_agent(agent.id, user.id).avatar_media_type == "image/png"
      assert Agents.get_avatar(agent).data == @png
    end

    test "accepts the JSON base64 form prompt images already use", %{
      conn: conn,
      key: key,
      agent: agent
    } do
      body =
        conn
        |> authed_with_key(key)
        |> put_json("/api/agents/#{agent.id}/avatar", %{
          "data" => Base.encode64(@png),
          "media_type" => "image/png"
        })
        |> json_response(200)

      assert body["data"]["avatar_media_type"] == "image/png"
      assert Agents.get_avatar(agent).data == @png
    end

    test "replaces an existing avatar", %{conn: conn, key: key, agent: agent} do
      conn |> put_raw(key, agent, "image/png", @png) |> json_response(200)

      build_conn()
      |> put_raw(key, agent, "image/gif", "GIF89a-different-bytes")
      |> json_response(200)

      assert Agents.get_avatar(agent).data == "GIF89a-different-bytes"
    end

    test "refuses a content type that is not an image", %{conn: conn, key: key, agent: agent} do
      # The asymmetry that once let a client-declared text/html become
      # servable from the app's own origin.
      body =
        conn
        |> put_raw(key, agent, "text/html", "<script>alert(1)</script>")
        |> json_response(415)

      assert body["error"] == "unsupported_media_type"
      refute Agents.get_avatar(agent)
    end

    test "refuses an unsupported media_type in the JSON form", %{
      conn: conn,
      key: key,
      agent: agent
    } do
      conn
      |> authed_with_key(key)
      |> put_json("/api/agents/#{agent.id}/avatar", %{
        "data" => Base.encode64("<html>"),
        "media_type" => "text/html"
      })
      |> json_response(415)

      refute Agents.get_avatar(agent)
    end

    test "refuses invalid base64", %{conn: conn, key: key, agent: agent} do
      body =
        conn
        |> authed_with_key(key)
        |> put_json("/api/agents/#{agent.id}/avatar", %{
          "data" => "!!!not-base64!!!",
          "media_type" => "image/png"
        })
        |> json_response(422)

      assert body["error"] == "invalid_base64"
    end

    test "refuses an oversized image", %{conn: conn, key: key, agent: agent} do
      oversized = :binary.copy("a", 5_242_881)

      body =
        conn
        |> authed_with_key(key)
        |> put_json("/api/agents/#{agent.id}/avatar", %{
          "data" => Base.encode64(oversized),
          "media_type" => "image/png"
        })
        |> json_response(413)

      assert body["error"] == "avatar_too_large"
      refute Agents.get_avatar(agent)
    end

    test "another tenant's agent is 404", %{conn: conn, key: key} do
      other = insert_verified_user()
      other_agent = insert_agent(user_id: other.id)

      conn |> put_raw(key, other_agent, "image/png", @png) |> json_response(404)
      refute Agents.get_avatar(other_agent)
    end
  end

  describe "GET /api/agents/:id/avatar" do
    test "serves the bytes with the stored type and the sandboxing headers", %{
      conn: conn,
      key: key,
      agent: agent
    } do
      build_conn() |> put_raw(key, agent, "image/png", @png) |> json_response(200)

      conn = conn |> authed_with_key(key) |> get("/api/agents/#{agent.id}/avatar")

      assert conn.status == 200
      assert conn.resp_body == @png
      assert get_resp_header(conn, "content-type") |> hd() =~ "image/png"
      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
      assert get_resp_header(conn, "content-security-policy") == ["default-src 'none'; sandbox"]
    end

    test "an agent with no avatar is 404", %{conn: conn, key: key, agent: agent} do
      conn = conn |> authed_with_key(key) |> get("/api/agents/#{agent.id}/avatar")
      assert conn.status == 404
    end

    test "a stored media type outside the allowlist is a 404, not served", %{
      conn: conn,
      key: key,
      agent: agent
    } do
      # A row that slipped past ingest validation (or predates it) must not
      # be reflected into Content-Type — that is the self-XSS this endpoint
      # once allowed.
      {:ok, updated} = Agents.upload_avatar(agent, "<script>alert(1)</script>", "image/png")

      updated
      |> Ecto.Changeset.change(%{avatar_media_type: "text/html"})
      |> Fountain.Repo.update!()

      conn = conn |> authed_with_key(key) |> get("/api/agents/#{agent.id}/avatar")

      assert conn.status == 404
    end

    test "another tenant's avatar is 404, not the bytes", %{conn: conn, key: key} do
      other = insert_verified_user()
      {_rec, other_key} = insert_api_key(other)
      other_agent = insert_agent(user_id: other.id)

      build_conn() |> put_raw(other_key, other_agent, "image/png", @png) |> json_response(200)

      conn = conn |> authed_with_key(key) |> get("/api/agents/#{other_agent.id}/avatar")

      assert conn.status == 404
      refute conn.resp_body == @png
    end

    test "requires authentication", %{conn: conn, agent: agent} do
      conn = get(conn, "/api/agents/#{agent.id}/avatar")
      assert conn.status == 401
    end
  end

  describe "DELETE /api/agents/:id/avatar" do
    test "removes the avatar and clears the media type", %{
      conn: conn,
      user: user,
      key: key,
      agent: agent
    } do
      build_conn() |> put_raw(key, agent, "image/png", @png) |> json_response(200)

      conn
      |> authed_with_key(key)
      |> delete("/api/agents/#{agent.id}/avatar")
      |> response(204)

      refute Agents.get_avatar(agent)
      refute Agents.get_agent(agent.id, user.id).avatar_media_type
    end

    test "is idempotent for an agent that never had one", %{conn: conn, key: key, agent: agent} do
      conn
      |> authed_with_key(key)
      |> delete("/api/agents/#{agent.id}/avatar")
      |> response(204)
    end

    test "another tenant's agent is 404 and keeps its avatar", %{conn: conn, key: key} do
      other = insert_verified_user()
      {_rec, other_key} = insert_api_key(other)
      other_agent = insert_agent(user_id: other.id)
      build_conn() |> put_raw(other_key, other_agent, "image/png", @png) |> json_response(200)

      conn
      |> authed_with_key(key)
      |> delete("/api/agents/#{other_agent.id}/avatar")
      |> json_response(404)

      assert Agents.get_avatar(other_agent)
    end
  end

  describe "agent JSON" do
    test "avatar_media_type is null until one is uploaded", %{conn: conn, key: key, agent: agent} do
      body =
        conn
        |> authed_with_key(key)
        |> get("/api/agents/#{agent.id}")
        |> json_response(200)

      assert body["data"]["avatar_media_type"] == nil
    end
  end
end
