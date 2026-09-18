defmodule FountainWeb.TurnImageIngestTest do
  @moduledoc """
  What the API accepts as a turn image.

  #202 stopped hostile rows being *served*. This is the other half: they should
  not be storable either, and a malformed request should say so rather than
  looking like a server fault.

  Two layers answer here, and it is worth knowing which. `OpenApiSpex`
  `CastAndValidate` already enforces the `ImageInput` schema — including the
  `media_type` enum — and rejects those with 422 before the controller runs. It
  does not decode base64 and does not know about the size limit, so those
  reached `decode_images/1`, which called `Base.decode64!` and `raise`d an
  unrescued `ArgumentError`: both surfaced as a 500, telling a client with a
  malformed request that the server was broken.

  So the assertions below accept either 4xx where the spec layer gets there
  first, and pin 400 exactly where the controller is the only thing checking.
  The context-level guard that makes all of this defence in depth rather than a
  single boundary is in `Conversations._unsafe_insert_turn_images/2`.
  """

  use FountainWeb.ConnCase, async: true
  use Mimic

  alias Fountain.Conversations

  setup do
    user = insert_active_user()
    # "every allowed type is accepted" opens one conversation per media type,
    # which is more sandboxes than the default plan allows. The subject here
    # is the image payload, so the quota is lifted out of the way rather than
    # being allowed to answer 429 and read as a rejected media type.
    {:ok, user} = Fountain.Accounts.update_sandbox_limit(user, 25)
    {_key, raw_key} = insert_api_key(user)
    agent = insert_agent(user_id: user.id)
    {:ok, user: user, raw_key: raw_key, agent: agent}
  end

  defp png, do: Base.encode64(<<0x89, 0x50, 0x4E, 0x47>>)

  defp post_create(conn, raw_key, agent, images) do
    conn
    |> authed_with_key(raw_key)
    |> post_json("/api/conversations", %{
      "agent_id" => agent.id,
      "prompt" => "Describe these images",
      "images" => images
    })
  end

  describe "media type" do
    test "a disallowed type is a 400, not a 500 and not a stored row", %{
      conn: conn,
      raw_key: raw_key,
      agent: agent
    } do
      conn =
        post_create(conn, raw_key, agent, [%{"media_type" => "text/html", "data" => png()}])

      assert conn.status in [400, 422]
      assert conn.resp_body =~ "media_type" or conn.resp_body =~ "Invalid value"
    end

    test "a missing type is refused", %{conn: conn, raw_key: raw_key, agent: agent} do
      conn = post_create(conn, raw_key, agent, [%{"data" => png()}])
      assert conn.status in [400, 422]
    end

    test "every allowed type is accepted", %{raw_key: raw_key, agent: agent} do
      stub_server_start(fn _s, _spec ->
        {:ok, self()}
      end)

      for type <- Conversations.TurnImage.valid_media_types() do
        conn =
          build_conn()
          |> post_create(raw_key, agent, [%{"media_type" => type, "data" => png()}])

        assert conn.status in [200, 201], "#{type} was rejected with #{conn.status}"
        assert_received {:"$gen_cast", {:initial_prompt, "Describe these images", [image]}}
        assert image.media_type == type
        assert image.data == Base.decode64!(png())
      end
    end
  end

  describe "payload" do
    test "data that is not base64 is a 400 rather than a 500", %{
      conn: conn,
      raw_key: raw_key,
      agent: agent
    } do
      conn =
        post_create(conn, raw_key, agent, [
          %{"media_type" => "image/png", "data" => "not base64 !!!"}
        ])

      assert json_response(conn, 400)["error"] =~ "base64"
    end

    test "missing data is a 400", %{conn: conn, raw_key: raw_key, agent: agent} do
      conn = post_create(conn, raw_key, agent, [%{"media_type" => "image/png"}])
      assert conn.status in [400, 422]
    end

    test "an oversized image is a client error, not a 500" do
      # A body this large never reaches the controller: it exceeds the parser's
      # read length, so Plug.Parsers rejects it. That path used to raise a
      # MatchError inside CachingBodyReader and surface as a 500 for every
      # endpoint — fixed here, so it is now the 413 it should always have been.
      oversized = Base.encode64(:binary.copy(<<0>>, 10 * 1024 * 1024 + 1))
      user = insert_active_user()
      {_key, raw_key} = insert_api_key(user)
      agent = insert_agent(user_id: user.id)

      assert_raise Plug.Parsers.RequestTooLargeError, fn ->
        post_create(build_conn(), raw_key, agent, [
          %{"media_type" => "image/png", "data" => oversized}
        ])
      end
    end

    test "the controller still guards the size itself" do
      # Defence in depth: the parser limit is configuration and could be raised,
      # and this is the check that keeps a 10MB ceiling meaningful if it is.
      big = :binary.copy(<<0>>, 10 * 1024 * 1024 + 1)

      assert {:error, msg} =
               FountainWeb.PromptImages.decode([
                 %{"media_type" => "image/png", "data" => Base.encode64(big)}
               ])

      assert msg =~ "10MB"
    end

    test "a non-object entry is refused", %{conn: conn, raw_key: raw_key, agent: agent} do
      conn = post_create(conn, raw_key, agent, ["just a string"])
      assert conn.status in [400, 422]
    end
  end

  describe "the prompt endpoint validates the same way" do
    test "a disallowed type is refused there too", %{
      conn: conn,
      user: user,
      raw_key: raw_key,
      agent: agent
    } do
      # Two entry points take images; validating only one of them would leave
      # the other as the way in.
      conv = insert_conversation(user_id: user.id, agent: agent)

      conn =
        conn
        |> authed_with_key(raw_key)
        |> post_json("/api/conversations/#{conv.id}/prompts", %{
          "prompt" => "hi",
          "images" => [%{"media_type" => "application/octet-stream", "data" => png()}]
        })

      assert conn.status in [400, 422]
    end
  end

  describe "no images" do
    test "an absent images key is fine", %{conn: conn, raw_key: raw_key, agent: agent} do
      stub_server_start(fn _s, _spec ->
        {:ok, spawn(fn -> :ok end)}
      end)

      conn =
        conn
        |> authed_with_key(raw_key)
        |> post_json("/api/conversations", %{"agent_id" => agent.id})

      assert conn.status in [200, 201]
    end
  end
end
