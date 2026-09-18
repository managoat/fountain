defmodule FountainWeb.SandboxApiAccessTest do
  use FountainWeb.ConnCase, async: true
  use Mimic

  alias Fountain.Conversations
  alias Fountain.Conversations.CallbackKey

  setup do
    user = insert_verified_user()
    {_key, raw} = insert_api_key(user)
    agent = insert_agent(user_id: user.id)
    stub_server_start(fn _, _ -> {:ok, spawn(fn -> :ok end)} end)
    {:ok, user: user, raw: raw, agent: agent}
  end

  test "public creation persists none before the worker can start", c do
    body =
      c.conn
      |> authed_with_key(c.raw)
      |> post_json("/api/conversations", %{
        "agent_id" => c.agent.id,
        "sandbox_mode" => "ephemeral",
        "sandbox_api_access" => "none"
      })
      |> json_response(201)

    assert body["data"]["sandbox_api_access"] == "none"
    conv = Conversations.get_conversation(body["data"]["id"], c.user.id)
    assert conv.sandbox.mode == "ephemeral"
    assert {:ok, nil, nil, _} = CallbackKey.rotate(conv, nil)
  end

  test "invalid values and persistent none refuse before sandbox creation", c do
    before_count = Fountain.Repo.aggregate(Conversations.Sandbox, :count)

    for {access, mode} <- [{"none", "persistent"}, {"typo", "ephemeral"}, {false, "ephemeral"}] do
      body =
        c.conn
        |> authed_with_key(c.raw)
        |> post_json("/api/conversations", %{
          "agent_id" => c.agent.id,
          "sandbox_mode" => mode,
          "sandbox_api_access" => access
        })
        |> json_response(422)

      expected = if access == "none", do: "invalid_sandbox_api_access", else: "validation_failed"
      assert body["error"] == expected
    end

    assert Fountain.Repo.aggregate(Conversations.Sandbox, :count) == before_count
  end

  test "none refuses a caller-supplied sprite_name (#1632)", c do
    # `none` promises a machine no other conversation can reach. That check
    # counts conversation rows pointing at the sandbox, so it cannot see a
    # machine reached by naming it — the provider adopts an existing name.
    before_count = Fountain.Repo.aggregate(Conversations.Sandbox, :count)

    body =
      c.conn
      |> authed_with_key(c.raw)
      |> post_json("/api/conversations", %{
        "agent_id" => c.agent.id,
        "sandbox_mode" => "ephemeral",
        "sandbox_api_access" => "none",
        "sprite_name" => "worker-1"
      })
      |> json_response(422)

    assert body["error"] == "invalid_sandbox_api_access"
    assert Fountain.Repo.aggregate(Conversations.Sandbox, :count) == before_count
  end

  test "a channel cannot silently resume a different credential policy", c do
    sandbox = insert_sandbox(user_id: c.user.id, status: "ready")

    conv =
      insert_conversation(
        user_id: c.user.id,
        agent: c.agent,
        sandbox: sandbox,
        status: "idle",
        channel_id: "bound"
      )

    attrs = %{
      "agent_id" => c.agent.id,
      "channel_id" => "bound",
      "sandbox_mode" => "ephemeral",
      "sandbox_api_access" => "none"
    }

    body =
      c.conn
      |> authed_with_key(c.raw)
      |> post_json("/api/conversations", attrs)
      |> json_response(422)

    assert body["error"] == "invalid_sandbox_api_access"
    assert Conversations.get_conversation(conv.id, c.user.id).sandbox_api_access == "owner"
  end

  test "none cannot inherit an existing machine or have another conversation attached", c do
    sandbox = insert_sandbox(user_id: c.user.id, agent_id: c.agent.id, status: "ready")

    attrs = %{
      "agent_id" => c.agent.id,
      "sandbox_id" => sandbox.id,
      "sandbox_api_access" => "none"
    }

    body =
      c.conn
      |> authed_with_key(c.raw)
      |> post_json("/api/conversations", attrs)
      |> json_response(422)

    assert body["error"] == "invalid_sandbox_api_access"

    insert_conversation(
      user_id: c.user.id,
      agent: c.agent,
      sandbox: sandbox,
      sandbox_api_access: "none"
    )

    body =
      c.conn
      |> authed_with_key(c.raw)
      |> post_json("/api/conversations", Map.delete(attrs, "sandbox_api_access"))
      |> json_response(422)

    assert body["error"] == "invalid_sandbox_api_access"
  end

  test "omitting sandbox_api_access on a channel resume retains none and issues no callback", c do
    sandbox = insert_sandbox(user_id: c.user.id, status: "ready")

    conv =
      insert_conversation(
        user_id: c.user.id,
        agent: c.agent,
        sandbox: sandbox,
        status: "idle",
        channel_id: "isolated",
        sandbox_api_access: "none"
      )

    body =
      c.conn
      |> authed_with_key(c.raw)
      |> post_json("/api/conversations", %{
        "agent_id" => c.agent.id,
        "channel_id" => "isolated"
      })
      |> json_response(200)

    assert body["data"]["id"] == conv.id
    assert body["data"]["sandbox_api_access"] == "none"
    resumed = Conversations.get_conversation(conv.id, c.user.id)
    assert resumed.sandbox_id == sandbox.id
    assert {:ok, nil, nil, _} = CallbackKey.rotate(resumed, nil)
  end
end
