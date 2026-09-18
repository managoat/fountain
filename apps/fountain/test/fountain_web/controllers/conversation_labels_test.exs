defmodule FountainWeb.ConversationLabelsTest do
  @moduledoc """
  Labels over the wire (#1637): create, read back, the repeatable AND filter,
  the merge route and who is allowed to call it.
  """

  use FountainWeb.ConnCase, async: true
  use Mimic

  alias Fountain.Conversations

  setup do
    user = insert_active_user()
    {_key, raw_key} = insert_api_key(user)
    {:ok, user: user, raw_key: raw_key}
  end

  describe "POST /api/conversations with labels" do
    # Nothing stubbed but the supervisor: the point is to exercise the real
    # `start_conversation/2` attrs, which is where `labels` actually reaches
    # the row. A stub of `start_or_resume_conversation/2` would test the view
    # and leave the create path uncovered.
    defp create_conversation(conn, raw_key, body) do
      stub_server_start(fn _s, _spec ->
        {:ok, spawn(fn -> :ok end)}
      end)

      conn |> authed_with_key(raw_key) |> post_json("/api/conversations", body)
    end

    test "creates with them and returns them", %{conn: conn, user: user, raw_key: raw_key} do
      agent = insert_agent(user_id: user.id)

      conn =
        create_conversation(conn, raw_key, %{
          "agent_id" => agent.id,
          "labels" => %{"env" => "prod", "drift" => "true"}
        })

      assert %{"data" => data} = json_response(conn, 201)
      assert data["labels"] == %{"env" => "prod", "drift" => "true"}

      # And on the row, not only in the response the create rendered.
      assert Conversations._unsafe_get_conversation!(data["id"]).labels ==
               %{"env" => "prod", "drift" => "true"}
    end

    test "creating with none leaves an empty map on the row", %{
      conn: conn,
      user: user,
      raw_key: raw_key
    } do
      agent = insert_agent(user_id: user.id)

      conn = create_conversation(conn, raw_key, %{"agent_id" => agent.id})

      assert %{"data" => %{"id" => id, "labels" => %{}}} = json_response(conn, 201)
      assert Conversations._unsafe_get_conversation!(id).labels == %{}
    end

    test "a label the limits refuse is a 422 and creates nothing", %{
      conn: conn,
      user: user,
      raw_key: raw_key
    } do
      agent = insert_agent(user_id: user.id)
      before = length(Conversations.list_conversations(user.id))

      conn =
        create_conversation(conn, raw_key, %{
          "agent_id" => agent.id,
          "labels" => %{"note" => String.duplicate("v", 300)}
        })

      assert [message] = json_response(conn, 422)["errors"]["labels"]
      assert message =~ ~s("note")
      assert length(Conversations.list_conversations(user.id)) == before
    end

    test "a conversation with no labels serves an empty object, never null", %{
      conn: conn,
      user: user,
      raw_key: raw_key
    } do
      conv = insert_conversation(user_id: user.id)

      conn = conn |> authed_with_key(raw_key) |> get("/api/conversations/#{conv.id}")

      assert %{"data" => %{"labels" => %{}}} = json_response(conn, 200)
    end
  end

  describe "GET /api/conversations?label=" do
    setup %{user: user} do
      prod_drift =
        insert_conversation(user_id: user.id, labels: %{"env" => "prod", "drift" => "true"})

      prod_clean = insert_conversation(user_id: user.id, labels: %{"env" => "prod"})
      staging = insert_conversation(user_id: user.id, labels: %{"env" => "staging"})

      {:ok, prod_drift: prod_drift, prod_clean: prod_clean, staging: staging}
    end

    defp listed(conn),
      do: conn |> json_response(200) |> Map.fetch!("data") |> Enum.map(& &1["id"])

    test "one pair keeps the conversations carrying it", context do
      ids =
        context.conn
        |> authed_with_key(context.raw_key)
        |> get("/api/conversations?label=env:prod")
        |> listed()

      assert Enum.sort(ids) == Enum.sort([context.prod_drift.id, context.prod_clean.id])
    end

    test "a repeated label is combined with AND", context do
      ids =
        context.conn
        |> authed_with_key(context.raw_key)
        |> get("/api/conversations?label=env:prod&label=drift:true")
        |> listed()

      assert ids == [context.prod_drift.id]
    end

    test "combines with the other filters", context do
      ids =
        context.conn
        |> authed_with_key(context.raw_key)
        |> get("/api/conversations?status=pending&label=env:staging")
        |> listed()

      assert ids == [context.staging.id]
    end

    test "a value splits on its first colon only", %{conn: conn, user: user, raw_key: raw_key} do
      conv = insert_conversation(user_id: user.id, labels: %{"path" => "apps/fountain:lib"})

      ids =
        conn
        |> authed_with_key(raw_key)
        |> get("/api/conversations?label=path:apps/fountain:lib")
        |> listed()

      assert ids == [conv.id]
    end

    test "a value with no colon is a 400 rather than a silent match-all", context do
      conn =
        context.conn
        |> authed_with_key(context.raw_key)
        |> get("/api/conversations?label=prod")

      assert %{"error" => "invalid_label_filter"} = json_response(conn, 400)
    end
  end

  describe "PATCH /api/conversations/:id/labels" do
    setup %{user: user} do
      conv = insert_conversation(user_id: user.id, labels: %{"env" => "staging"})
      {:ok, conv: conv}
    end

    test "merges into what is already there", context do
      conn =
        context.conn
        |> authed_with_key(context.raw_key)
        |> patch_json("/api/conversations/#{context.conv.id}/labels", %{
          "labels" => %{"drift" => "true"}
        })

      assert %{"data" => data} = json_response(conn, 200)
      assert data["labels"] == %{"env" => "staging", "drift" => "true"}
    end

    test "a null value removes one key", context do
      conn =
        context.conn
        |> authed_with_key(context.raw_key)
        |> patch_json("/api/conversations/#{context.conv.id}/labels", %{
          "labels" => %{"env" => nil, "run" => "17"}
        })

      assert %{"data" => %{"labels" => %{"run" => "17"}}} = json_response(conn, 200)
    end

    test "another tenant's conversation is a 404", context do
      other = insert_conversation(user_id: insert_active_user().id)

      conn =
        context.conn
        |> authed_with_key(context.raw_key)
        |> patch_json("/api/conversations/#{other.id}/labels", %{"labels" => %{"env" => "prod"}})

      assert json_response(conn, 404)
    end

    test "a body without a labels object is a 422", context do
      conn =
        context.conn
        |> authed_with_key(context.raw_key)
        |> patch_json("/api/conversations/#{context.conv.id}/labels", %{"labels" => "env=prod"})

      assert %{"error" => _} = json_response(conn, 422)
    end
  end

  describe "the limits over the wire" do
    setup %{user: user} do
      {:ok, conv: insert_conversation(user_id: user.id)}
    end

    defp label_error(context, labels) do
      context.conn
      |> authed_with_key(context.raw_key)
      |> patch_json("/api/conversations/#{context.conv.id}/labels", %{"labels" => labels})
      |> json_response(422)
      |> get_in(["errors", "labels"])
      |> List.first()
    end

    test "too many entries names the key over the limit", context do
      labels = for n <- 1..33, into: %{}, do: {String.pad_leading("#{n}", 3, "0"), "x"}

      message = label_error(context, labels)
      assert message =~ "at most 32 labels"
      assert message =~ ~s("033")
    end

    test "an over-long key names it", context do
      message = label_error(context, %{String.duplicate("k", 65) => "v"})

      assert message =~ "longer than 64 bytes"
      assert message =~ String.duplicate("k", 64)
    end

    test "an over-long value names its key", context do
      message = label_error(context, %{"note" => String.duplicate("v", 257)})

      assert message =~ ~s("note")
      assert message =~ "longer than 256 bytes"
    end

    # Postgres will not store a NUL inside a jsonb string. Unrejected, the
    # write reaches Repo.update and comes back as a raised Postgrex.Error —
    # a 500 on a request the caller should have been told was invalid.
    test "a NUL byte in a value is a 422, not a 500", context do
      message = label_error(context, %{"note" => "before\u0000after"})

      assert message =~ ~s("note")
      assert message =~ "NUL byte"
    end

    test "a NUL byte in a key is a 422, not a 500", context do
      message = label_error(context, %{"ke\u0000y" => "v"})

      assert message =~ "NUL byte"
    end
  end

  describe "a channel resume merges labels (#1637)" do
    setup %{user: user} do
      agent = insert_agent(user_id: user.id)

      bound =
        insert_conversation(
          user_id: user.id,
          agent: agent,
          status: "idle",
          channel_id: "chat:42",
          labels: %{"env" => "prod"},
          sandbox: insert_sandbox(user_id: user.id, status: "ready")
        )

      {:ok, agent: agent, bound: bound}
    end

    test "into the conversation it hands back", context do
      conn =
        context.conn
        |> authed_with_key(context.raw_key)
        |> post_json("/api/conversations", %{
          "agent_id" => context.agent.id,
          "channel_id" => "chat:42",
          "labels" => %{"run" => "17"}
        })

      # 200, not 201: the binding resumed rather than opening a conversation.
      assert %{"data" => data, "meta" => %{"resumed" => true}} = json_response(conn, 200)
      assert data["id"] == context.bound.id
      assert data["labels"] == %{"env" => "prod", "run" => "17"}
    end

    test "a resume with no labels leaves the ones already there", context do
      conn =
        context.conn
        |> authed_with_key(context.raw_key)
        |> post_json("/api/conversations", %{
          "agent_id" => context.agent.id,
          "channel_id" => "chat:42"
        })

      assert %{"data" => %{"labels" => %{"env" => "prod"}}} = json_response(conn, 200)
    end

    test "a label the limits refuse is a 422", context do
      conn =
        context.conn
        |> authed_with_key(context.raw_key)
        |> post_json("/api/conversations", %{
          "agent_id" => context.agent.id,
          "channel_id" => "chat:42",
          "labels" => %{"note" => String.duplicate("v", 300)}
        })

      assert [message] = json_response(conn, 422)["errors"]["labels"]
      assert message =~ ~s("note")
    end

    test "a sandbox token may not relabel another conversation by resuming its channel",
         context do
      {_key, sprite_raw} = insert_sprite_api_key(context.user)

      conn =
        context.conn
        |> authed_with_key(sprite_raw)
        |> post_json("/api/conversations", %{
          "agent_id" => context.agent.id,
          "channel_id" => "chat:42",
          "labels" => %{"run" => "17"}
        })

      assert %{"error" => "sprite_may_not_label_another_conversation"} = json_response(conn, 403)

      assert Conversations._unsafe_get_conversation!(context.bound.id).labels == %{
               "env" => "prod"
             }
    end

    test "a sandbox token may relabel the conversation it was minted for", context do
      {key, sprite_raw} = insert_sprite_api_key(context.user)

      {:ok, _} =
        Conversations.update_conversation(context.bound, %{callback_api_key_id: key.id})

      conn =
        context.conn
        |> authed_with_key(sprite_raw)
        |> post_json("/api/conversations", %{
          "agent_id" => context.agent.id,
          "channel_id" => "chat:42",
          "labels" => %{"run" => "17"}
        })

      assert %{"data" => %{"labels" => labels}} = json_response(conn, 200)
      assert labels == %{"env" => "prod", "run" => "17"}
    end
  end

  describe "a sandbox callback token" do
    setup %{user: user} do
      {key, raw} = insert_sprite_api_key(user)
      mine = insert_conversation(user_id: user.id, callback_api_key_id: key.id)
      theirs = insert_conversation(user_id: user.id)

      {:ok, sprite_key: raw, mine: mine, theirs: theirs}
    end

    test "labels the conversation it was minted for", context do
      conn =
        context.conn
        |> authed_with_key(context.sprite_key)
        |> patch_json("/api/conversations/#{context.mine.id}/labels", %{
          "labels" => %{"drift" => "true"}
        })

      assert %{"data" => %{"labels" => %{"drift" => "true"}}} = json_response(conn, 200)
    end

    test "is refused on another conversation of the same account", context do
      conn =
        context.conn
        |> authed_with_key(context.sprite_key)
        |> patch_json("/api/conversations/#{context.theirs.id}/labels", %{
          "labels" => %{"drift" => "true"}
        })

      assert %{"error" => "sprite_may_not_label_another_conversation"} = json_response(conn, 403)
      assert Conversations._unsafe_get_conversation!(context.theirs.id).labels == %{}
    end

    test "records the write as the sprite, with keys and no values", context do
      context.conn
      |> authed_with_key(context.sprite_key)
      |> patch_json("/api/conversations/#{context.mine.id}/labels", %{
        "labels" => %{"drift" => "true"}
      })

      assert [event] =
               context.user.id
               |> Fountain.Audit.list_recent_for_user(50)
               |> Enum.filter(&(&1.action == "conversation.labels_set"))

      assert event.actor == "sprite"
      assert event.metadata["keys"] == ["drift"]
      refute inspect(event.metadata) =~ "true"
    end
  end
end
