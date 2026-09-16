defmodule FountainWeb.TeamControllerTest do
  use FountainWeb.ConnCase, async: true
  use Mimic

  alias Fountain.{Audit, Repo, Team}
  alias Fountain.Conversations.ConversationServer
  alias Fountain.Conversations.Termination

  # Ending a conversation whose server is gone now destroys its machine through
  # `Fountain.Machines.Machine` (ADR 0058 stage 5) rather than leaving the
  # sprite for the reaper, so these tests reach the provider where they did not
  # before. Nothing here is about the provider, so the adapter seam answers
  # yes. Stubbed at `Managoat.Sandbox.Sprites` rather than at the
  # `Managoat.Sandbox` facade so a test that drives either layer itself still
  # overrides it.
  setup do
    stub(Managoat.Sandbox.Sprites, :destroy, fn _handle -> :ok end)
    user = insert_verified_user()
    {_key, raw_key} = insert_api_key(user)
    {:ok, user: user, raw_key: raw_key}
  end

  defp insert_teammate_conv(user, agent, overrides \\ %{}) do
    insert_conversation(
      Map.merge(
        %{user_id: user.id, agent: agent, status: "idle", channel_id: Team.channel()},
        Map.new(overrides)
      )
    )
  end

  defp inert_start_child do
    stub(Horde.DynamicSupervisor, :start_child, fn _sup, _spec ->
      {:ok, spawn(fn -> Process.sleep(:infinity) end)}
    end)
  end

  describe "GET /api/team" do
    test "lists the roster with name, presence, preview and unread", %{
      conn: conn,
      user: user,
      raw_key: key
    } do
      ada = insert_agent(user_id: user.id, name: "Ada")
      conv = insert_teammate_conv(user, ada, title: "Ada (staging)")
      insert_turn(conv, prompt: "hello there", status: "completed")
      # Someone else's team is not ours; an unbound conversation is not a teammate.
      insert_teammate_conv(insert_verified_user(), insert_agent())
      insert_conversation(user_id: user.id, agent: insert_agent(user_id: user.id))

      body = conn |> authed_with_key(key) |> get("/api/team") |> json_response(200)

      assert [entry] = body["data"]
      assert entry["agent_id"] == ada.id
      assert entry["name"] == "Ada (staging)"
      assert entry["agent"]["name"] == "Ada"
      assert entry["conversation"]["id"] == conv.id
      assert entry["conversation"]["channel_id"] == "fountain:team"
      assert entry["presence"]["state"] == "away"
      assert entry["preview"] == %{"kind" => "you", "text" => "hello there"}
      assert entry["last_turn"]["prompt"] == "hello there"
      assert is_boolean(entry["unread"])
    end

    test "usage_total sums every conversation the agent had on the team (#827)", %{
      conn: conn,
      user: user,
      raw_key: key
    } do
      ada = insert_agent(user_id: user.id, name: "Ada")
      old = insert_teammate_conv(user, ada, status: "terminated")
      current = insert_teammate_conv(user, ada)
      t_old = insert_turn(old, prompt: "before", status: "completed")
      t_new = insert_turn(current, prompt: "now", status: "completed")

      {:ok, _} =
        Fountain.Conversations._unsafe_record_turn_usage(t_old, %{"input" => 10, "output" => 1})

      {:ok, _} =
        Fountain.Conversations._unsafe_record_turn_usage(t_new, %{"input" => 5, "output" => 2})

      body = conn |> authed_with_key(key) |> get("/api/team") |> json_response(200)

      assert [entry] = body["data"]
      assert entry["conversation"]["id"] == current.id
      assert entry["conversation"]["usage_total"] == %{"input" => 5, "output" => 2}
      assert entry["usage_total"] == %{"input" => 15, "output" => 3}
      assert entry["last_turn"]["usage"] == %{"input" => 5, "output" => 2}
    end

    test "is empty with no team", %{conn: conn, raw_key: key} do
      assert %{"data" => []} =
               conn |> authed_with_key(key) |> get("/api/team") |> json_response(200)
    end

    test "401 without a key", %{conn: conn} do
      assert conn |> get("/api/team") |> json_response(401)
    end
  end

  describe "runner-backed teammates (#834)" do
    test "presence is machine_offline while the runner is down, and the sandbox names the machine",
         %{
           conn: conn,
           user: user,
           raw_key: key
         } do
      {:ok, runner} =
        Fountain.Runners.register(user.id, %{
          "name" => "mini",
          "hostname" => "mac-mini.local",
          "root" => "/Users/j/sandboxes"
        })

      name = Fountain.Runners.sandbox_name_for(runner.id)

      sandbox =
        insert_sandbox(user_id: user.id, machine_name: name, provider: "runner", status: "ready")

      ada = insert_agent(user_id: user.id, name: "Ada")
      insert_teammate_conv(user, ada, sandbox_id: sandbox.id)

      [entry] =
        conn
        |> authed_with_key(key)
        |> get("/api/team")
        |> json_response(200)
        |> Map.fetch!("data")

      assert entry["presence"]["state"] == "machine_offline"
      assert entry["presence"]["label"] =~ "machine offline"

      assert %{
               "provider" => "runner",
               "runner" => %{
                 "name" => "mini",
                 "hostname" => "mac-mini.local",
                 "online" => false,
                 "path" => "/Users/j/sandboxes/" <> ^name
               }
             } = entry["conversation"]["sandbox"]

      {:ok, daemon} =
        Managoat.Runner.FakeDaemon.start(runner.id, meta: %{user_id: user.id}, name: "mini")

      [entry] =
        conn
        |> authed_with_key(key)
        |> get("/api/team")
        |> json_response(200)
        |> Map.fetch!("data")

      assert entry["presence"]["state"] == "online"
      assert entry["conversation"]["sandbox"]["runner"]["online"] == true
      Managoat.Runner.FakeDaemon.stop(daemon)
    end

    test "a pending conversation on a ready sandbox is online, not starting", %{
      conn: conn,
      user: user,
      raw_key: key
    } do
      ada = insert_agent(user_id: user.id, name: "Ada")
      ready = insert_sandbox(user_id: user.id, status: "ready")
      insert_teammate_conv(user, ada, status: "pending", sandbox_id: ready.id)

      bob = insert_agent(user_id: user.id, name: "Bob")
      starting = insert_sandbox(user_id: user.id, status: "starting")
      insert_teammate_conv(user, bob, status: "pending", sandbox_id: starting.id)

      entries =
        conn
        |> authed_with_key(key)
        |> get("/api/team")
        |> json_response(200)
        |> Map.fetch!("data")
        |> Map.new(&{&1["agent"]["name"], &1["presence"]})

      assert %{"state" => "online", "label" => "ready · waiting for a turn"} = entries["Ada"]
      assert %{"state" => "starting"} = entries["Bob"]
    end

    test "a hosted sandbox carries provider and a null runner", %{
      conn: conn,
      user: user,
      raw_key: key
    } do
      ada = insert_agent(user_id: user.id, name: "Ada")
      sandbox = insert_sandbox(user_id: user.id, status: "suspended")
      insert_teammate_conv(user, ada, sandbox_id: sandbox.id)

      [entry] =
        conn
        |> authed_with_key(key)
        |> get("/api/team")
        |> json_response(200)
        |> Map.fetch!("data")

      assert entry["presence"]["state"] == "asleep"
      assert entry["conversation"]["sandbox"]["provider"] == "sprites"
      assert entry["conversation"]["sandbox"]["runner"] == nil
    end
  end

  describe "GET /api/team/:agent_id" do
    test "one teammate, or 404 when the agent is not on the team", %{
      conn: conn,
      user: user,
      raw_key: key
    } do
      ada = insert_agent(user_id: user.id, name: "Ada")
      insert_teammate_conv(user, ada)
      loner = insert_agent(user_id: user.id)

      assert %{"data" => %{"agent_id" => id}} =
               conn |> authed_with_key(key) |> get("/api/team/#{ada.id}") |> json_response(200)

      assert id == ada.id
      assert conn |> authed_with_key(key) |> get("/api/team/#{loner.id}") |> json_response(404)
    end
  end

  describe "POST /api/team" do
    test "adds the agent with a name, environment and vault; 201 with the teammate", %{
      conn: conn,
      user: user,
      raw_key: key
    } do
      ada = insert_agent(user_id: user.id, name: "Ada")
      env = insert_env(user_id: user.id, name: "staging")
      vault = insert_vault(user_id: user.id)
      inert_start_child()

      resp =
        conn
        |> authed_with_key(key)
        |> post_json("/api/team", %{
          agent_id: ada.id,
          name: "Ada (staging)",
          environment_id: env.id,
          vault_id: vault.id
        })

      body = json_response(resp, 201)
      assert body["data"]["name"] == "Ada (staging)"
      assert body["data"]["conversation"]["environment_id"] == env.id
      assert body["data"]["conversation"]["vault_id"] == vault.id
      assert body["data"]["conversation"]["source"] == "api"

      actions = user.id |> Audit.list_recent_for_user(20) |> Enum.map(& &1.action)
      assert "team.member.added" in actions
    end

    test "200 when the agent is already on the team", %{conn: conn, user: user, raw_key: key} do
      ada = insert_agent(user_id: user.id, name: "Ada")
      conv = insert_teammate_conv(user, ada)

      body =
        conn
        |> authed_with_key(key)
        |> post_json("/api/team", %{agent_id: ada.id, name: "ignored"})
        |> json_response(200)

      assert body["data"]["conversation"]["id"] == conv.id
      assert body["data"]["name"] == "Ada"
    end

    test "404 for another tenant's agent, environment or vault", %{
      conn: conn,
      user: user,
      raw_key: key
    } do
      other = insert_verified_user()
      ada = insert_agent(user_id: user.id)

      assert conn
             |> authed_with_key(key)
             |> post_json("/api/team", %{agent_id: insert_agent(user_id: other.id).id})
             |> json_response(404)

      assert %{"error" => "environment_not_found"} =
               conn
               |> authed_with_key(key)
               |> post_json("/api/team", %{
                 agent_id: ada.id,
                 environment_id: insert_env(user_id: other.id).id
               })
               |> json_response(404)

      assert %{"error" => "vault_not_found"} =
               conn
               |> authed_with_key(key)
               |> post_json("/api/team", %{
                 agent_id: ada.id,
                 vault_id: insert_vault(user_id: other.id).id
               })
               |> json_response(404)
    end

    test "422 when the agent's allowlist forbids the environment", %{
      conn: conn,
      user: user,
      raw_key: key
    } do
      env = insert_env(user_id: user.id)
      ada = insert_agent(user_id: user.id, allowed_environment_ids: [])

      assert %{"error" => "environment_not_allowed"} =
               conn
               |> authed_with_key(key)
               |> post_json("/api/team", %{agent_id: ada.id, environment_id: env.id})
               |> json_response(422)

      assert Team.list_teammates(user.id) == []
    end
  end

  describe "PATCH /api/team/:agent_id (#831)" do
    test "renames; blank clears; 404 off the team; 422 too long", %{
      conn: conn,
      user: user,
      raw_key: key
    } do
      ada = insert_agent(user_id: user.id, name: "Ada")
      insert_teammate_conv(user, ada)

      body =
        conn
        |> authed_with_key(key)
        |> patch_json("/api/team/#{ada.id}", %{name: "Ada (staging)"})
        |> json_response(200)

      assert body["data"]["name"] == "Ada (staging)"
      assert body["data"]["conversation"]["title"] == "Ada (staging)"

      assert [%{actor: "api"}] =
               Enum.filter(Audit.list_recent_for_user(user.id), &(&1.action == "team.renamed"))

      body =
        conn
        |> authed_with_key(key)
        |> patch_json("/api/team/#{ada.id}", %{name: nil})
        |> json_response(200)

      assert body["data"]["name"] == "Ada"

      loner = insert_agent(user_id: user.id)

      assert conn
             |> authed_with_key(key)
             |> patch_json("/api/team/#{loner.id}", %{name: "x"})
             |> json_response(404)

      assert conn
             |> authed_with_key(key)
             |> patch_json("/api/team/#{ada.id}", %{name: String.duplicate("x", 121)})
             |> json_response(422)
    end
  end

  describe "GET /api/team/:agent_id/conversations (#832)" do
    test "the teammate's history newest first, the live one flagged; 404 off the team", %{
      conn: conn,
      user: user,
      raw_key: key
    } do
      ada = insert_agent(user_id: user.id, name: "Ada")
      old = insert_teammate_conv(user, ada, status: "terminated")
      current = insert_teammate_conv(user, ada)
      insert_conversation(user_id: user.id, agent: ada)

      body =
        conn
        |> authed_with_key(key)
        |> get("/api/team/#{ada.id}/conversations")
        |> json_response(200)

      assert Enum.map(body["data"], &{&1["id"], &1["current"]}) == [
               {current.id, true},
               {old.id, false}
             ]

      assert hd(body["data"])["channel_id"] == "fountain:team"

      loner = insert_agent(user_id: user.id)

      assert conn
             |> authed_with_key(key)
             |> get("/api/team/#{loner.id}/conversations")
             |> json_response(404)
    end

    test "the label filter is repeatable and AND-combined (#1637)", %{
      conn: conn,
      user: user,
      raw_key: key
    } do
      ada = insert_agent(user_id: user.id, name: "Ada")
      drifted = insert_teammate_conv(user, ada, labels: %{"env" => "prod", "drift" => "true"})
      insert_teammate_conv(user, ada, labels: %{"env" => "prod"})
      insert_teammate_conv(user, ada, labels: %{"env" => "staging"})

      body =
        conn
        |> authed_with_key(key)
        |> get("/api/team/#{ada.id}/conversations?label=env:prod&label=drift:true")
        |> json_response(200)

      assert Enum.map(body["data"], & &1["id"]) == [drifted.id]
      assert hd(body["data"])["labels"] == %{"env" => "prod", "drift" => "true"}
    end

    test "a label filter with no colon is a 400", %{conn: conn, user: user, raw_key: key} do
      ada = insert_agent(user_id: user.id, name: "Ada")
      insert_teammate_conv(user, ada)

      assert %{"error" => "invalid_label_filter"} =
               conn
               |> authed_with_key(key)
               |> get("/api/team/#{ada.id}/conversations?label=prod")
               |> json_response(400)
    end
  end

  describe "POST /api/team/:agent_id/conversations" do
    test "opens a fresh conversation on the same computer; the old one is retired", %{
      conn: conn,
      user: user,
      raw_key: key
    } do
      ada = insert_agent(user_id: user.id, name: "Ada")
      sandbox = insert_sandbox(user_id: user.id, status: "ready")
      prev = insert_teammate_conv(user, ada, sandbox: sandbox, title: "Ada (staging)")

      body =
        conn
        |> authed_with_key(key)
        |> post("/api/team/#{ada.id}/conversations")
        |> json_response(201)

      entry = body["data"]
      assert entry["agent_id"] == ada.id
      assert entry["name"] == "Ada (staging)"
      refute entry["conversation"]["id"] == prev.id
      assert entry["conversation"]["sandbox_id"] == sandbox.id
      assert entry["conversation"]["status"] == "idle"
      # Same computer, no server yet: online, wakes on the next message.
      assert entry["presence"]["state"] == "online"

      assert Repo.reload(prev).status == "terminated"
      assert Repo.reload(sandbox).status == "ready"

      history =
        conn
        |> authed_with_key(key)
        |> get("/api/team/#{ada.id}/conversations")
        |> json_response(200)

      assert Enum.map(history["data"], &{&1["id"], &1["current"]}) == [
               {entry["conversation"]["id"], true},
               {prev.id, false}
             ]

      assert Enum.any?(Audit.list_recent_for_user(user.id, 20), fn e ->
               e.action == "team.conversation.rotated" and e.actor == "api" and
                 e.metadata["previous_conversation_id"] == prev.id and
                 e.metadata["computer_kept"] == true
             end)
    end

    test "400 conversation_busy while a turn runs; 503 while the computer starts; 404 off the team",
         %{conn: conn, user: user, raw_key: key} do
      ada = insert_agent(user_id: user.id, name: "Ada")
      sandbox = insert_sandbox(user_id: user.id, status: "ready")
      insert_teammate_conv(user, ada, sandbox: sandbox, status: "running")
      stub(Termination, :release_conversation, fn _id, _opts -> {:error, :busy} end)

      assert %{"error" => "conversation_busy"} =
               conn
               |> authed_with_key(key)
               |> post("/api/team/#{ada.id}/conversations")
               |> json_response(400)

      linus = insert_agent(user_id: user.id, name: "Linus")
      starting = insert_sandbox(user_id: user.id, status: "starting")
      insert_teammate_conv(user, linus, sandbox: starting, status: "pending")

      assert %{"error" => "provisioning"} =
               conn
               |> authed_with_key(key)
               |> post("/api/team/#{linus.id}/conversations")
               |> json_response(503)

      loner = insert_agent(user_id: user.id)

      assert conn
             |> authed_with_key(key)
             |> post("/api/team/#{loner.id}/conversations")
             |> json_response(404)
    end
  end

  describe "DELETE /api/team/:agent_id" do
    test "removes the teammate; 404 when not on the team", %{conn: conn, user: user, raw_key: key} do
      ada = insert_agent(user_id: user.id, name: "Ada")
      conv = insert_teammate_conv(user, ada)

      resp = conn |> authed_with_key(key) |> delete("/api/team/#{ada.id}")
      assert response(resp, 204)
      assert Team.list_teammates(user.id) == []
      assert Repo.reload(conv).channel_id == nil

      assert conn |> authed_with_key(key) |> delete("/api/team/#{ada.id}") |> json_response(404)
    end
  end

  describe "POST /api/team/:agent_id/messages" do
    test "hands the prompt to the conversation server; 202 with the conversation", %{
      conn: conn,
      user: user,
      raw_key: key
    } do
      ada = insert_agent(user_id: user.id, name: "Ada")
      conv = insert_teammate_conv(user, ada)
      test_pid = self()

      stub(ConversationServer, :send_prompt, fn id, text, images, opts ->
        send(test_pid, {:sent, id, text, images, opts[:actor]})
        :ok
      end)

      body =
        conn
        |> authed_with_key(key)
        |> post_json("/api/team/#{ada.id}/messages", %{prompt: "hello"})
        |> json_response(202)

      assert body == %{"status" => "queued", "conversation_id" => conv.id}
      conv_id = conv.id
      assert_received {:sent, ^conv_id, "hello", [], "api"}
    end

    test "labels on the message land on the conversation it goes to (#1637)", %{
      conn: conn,
      user: user,
      raw_key: key
    } do
      ada = insert_agent(user_id: user.id, name: "Ada")
      conv = insert_teammate_conv(user, ada, labels: %{"env" => "prod"})
      stub(ConversationServer, :send_prompt, fn _id, _text, _images, _opts -> :ok end)

      assert %{"conversation_id" => _} =
               conn
               |> authed_with_key(key)
               |> post_json("/api/team/#{ada.id}/messages", %{
                 prompt: "hello",
                 labels: %{"run" => "17"}
               })
               |> json_response(202)

      assert Fountain.Conversations._unsafe_get_conversation!(conv.id).labels ==
               %{"env" => "prod", "run" => "17"}
    end

    test "labels ride onto the fresh conversation when the thread is past resuming (#1637)", %{
      conn: conn,
      user: user,
      raw_key: key
    } do
      ada = insert_agent(user_id: user.id, name: "Ada")
      dead = insert_teammate_conv(user, ada, status: "terminated")
      inert_start_child()

      body =
        conn
        |> authed_with_key(key)
        |> post_json("/api/team/#{ada.id}/messages", %{
          prompt: "are you there?",
          labels: %{"env" => "prod"}
        })
        |> json_response(202)

      refute body["conversation_id"] == dead.id

      assert Fountain.Conversations._unsafe_get_conversation!(body["conversation_id"]).labels ==
               %{"env" => "prod"}
    end

    test "a sandbox token may not label the teammate's conversation (#1637)", %{
      conn: conn,
      user: user
    } do
      ada = insert_agent(user_id: user.id, name: "Ada")
      conv = insert_teammate_conv(user, ada, labels: %{"env" => "prod"})
      {_sprite, sprite_raw} = insert_sprite_api_key(user)
      test_pid = self()

      stub(ConversationServer, :send_prompt, fn _id, _text, _images, _opts ->
        send(test_pid, :sent)
        :ok
      end)

      assert %{"error" => "sprite_may_not_label_another_conversation"} =
               conn
               |> authed_with_key(sprite_raw)
               |> post_json("/api/team/#{ada.id}/messages", %{
                 prompt: "hello",
                 labels: %{"run" => "17"}
               })
               |> json_response(403)

      assert Fountain.Conversations._unsafe_get_conversation!(conv.id).labels == %{
               "env" => "prod"
             }

      refute_received :sent
    end

    test "a sandbox token may label the conversation it was minted for (#1637)", %{
      conn: conn,
      user: user
    } do
      ada = insert_agent(user_id: user.id, name: "Ada")
      conv = insert_teammate_conv(user, ada, labels: %{"env" => "prod"})
      {sprite, sprite_raw} = insert_sprite_api_key(user)

      {:ok, _} =
        Fountain.Conversations.update_conversation(conv, %{callback_api_key_id: sprite.id})

      stub(ConversationServer, :send_prompt, fn _id, _text, _images, _opts -> :ok end)

      assert %{"status" => "queued"} =
               conn
               |> authed_with_key(sprite_raw)
               |> post_json("/api/team/#{ada.id}/messages", %{
                 prompt: "hello",
                 labels: %{"run" => "17"}
               })
               |> json_response(202)

      assert Fountain.Conversations._unsafe_get_conversation!(conv.id).labels ==
               %{"env" => "prod", "run" => "17"}
    end

    test "a message with no labels leaves the ones already there (#1637)", %{
      conn: conn,
      user: user,
      raw_key: key
    } do
      ada = insert_agent(user_id: user.id, name: "Ada")
      conv = insert_teammate_conv(user, ada, labels: %{"env" => "prod"})
      stub(ConversationServer, :send_prompt, fn _id, _text, _images, _opts -> :ok end)

      conn
      |> authed_with_key(key)
      |> post_json("/api/team/#{ada.id}/messages", %{prompt: "hello"})
      |> json_response(202)

      assert Fountain.Conversations._unsafe_get_conversation!(conv.id).labels == %{
               "env" => "prod"
             }
    end

    test "a label the limits refuse leaves the message unsent, naming the key", %{
      conn: conn,
      user: user,
      raw_key: key
    } do
      ada = insert_agent(user_id: user.id, name: "Ada")
      insert_teammate_conv(user, ada)
      test_pid = self()

      stub(ConversationServer, :send_prompt, fn _id, _text, _images, _opts ->
        send(test_pid, :sent)
        :ok
      end)

      body =
        conn
        |> authed_with_key(key)
        |> post_json("/api/team/#{ada.id}/messages", %{
          prompt: "hello",
          labels: %{"note" => String.duplicate("v", 300)}
        })
        |> json_response(422)

      assert [message] = body["errors"]["labels"]
      assert message =~ ~s("note")
      refute_received :sent
    end

    test "400 conversation_busy while the teammate is busy, 404 when not on the team", %{
      conn: conn,
      user: user,
      raw_key: key
    } do
      ada = insert_agent(user_id: user.id, name: "Ada")
      insert_teammate_conv(user, ada, status: "running")
      stub(ConversationServer, :send_prompt, fn _id, _text, _images, _opts -> {:error, :busy} end)

      assert %{"error" => "conversation_busy"} =
               conn
               |> authed_with_key(key)
               |> post_json("/api/team/#{ada.id}/messages", %{prompt: "hurry"})
               |> json_response(400)

      loner = insert_agent(user_id: user.id)

      assert conn
             |> authed_with_key(key)
             |> post_json("/api/team/#{loner.id}/messages", %{prompt: "hi"})
             |> json_response(404)
    end

    test "a terminated teammate gets a fresh conversation, named in the response", %{
      conn: conn,
      user: user,
      raw_key: key
    } do
      ada = insert_agent(user_id: user.id, name: "Ada")
      dead = insert_teammate_conv(user, ada, status: "terminated", title: "Ada (staging)")
      inert_start_child()

      body =
        conn
        |> authed_with_key(key)
        |> post_json("/api/team/#{ada.id}/messages", %{prompt: "are you there?"})
        |> json_response(202)

      refute body["conversation_id"] == dead.id
      assert [%{conversation: %{id: id}, name: "Ada (staging)"}] = Team.list_teammates(user.id)
      assert id == body["conversation_id"]
    end
  end
end
