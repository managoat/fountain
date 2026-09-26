defmodule FountainWeb.ConversationReapplyControllerTest do
  @moduledoc """
  `POST /api/conversations/:id/reapply` and its status-code contract (#1565).

  Four refusals, four different meanings: 409 for a conversation mid-turn,
  409 with a `field` for a selection the machine cannot be reconfigured into,
  503 while the machine is still being built, and 410 once the conversation
  has ended.
  """

  use FountainWeb.ConnCase, async: true

  alias Fountain.{Agents, Conversations}
  alias Fountain.Conversations.Reapply

  setup do
    user = insert_active_user()
    {_key, raw_key} = insert_api_key(user)
    env = insert_env(user_id: user.id)
    vault = insert_vault(user_id: user.id)

    agent =
      insert_agent(
        user_id: user.id,
        runtime: "claude",
        environment_id: env.id,
        allowed_vault_ids: [vault.id]
      )

    sandbox =
      insert_sandbox(
        user_id: user.id,
        status: "ready",
        agent_id: agent.id,
        environment_id: env.id,
        vault_id: vault.id,
        build_fingerprint: Reapply.fingerprint(env)
      )

    conv =
      insert_conversation(
        user_id: user.id,
        agent: agent,
        agent_version_id: Agents._unsafe_current_version_id(agent.id),
        sandbox: sandbox,
        vault_id: vault.id,
        runtime_session_id: "old-session",
        status: "idle"
      )

    {:ok,
     user: user,
     raw_key: raw_key,
     agent: agent,
     env: env,
     vault: vault,
     sandbox: sandbox,
     conv: conv}
  end

  defp reapply(ctx, body, conv \\ nil) do
    ctx.conn
    |> authed_with_key(ctx.raw_key)
    |> post_json("/api/conversations/#{(conv || ctx.conv).id}/reapply", body)
  end

  test "200 changes the model and keeps the runtime session (ADR 0061)", ctx do
    response =
      ctx
      |> reapply(%{"model" => "anthropic/claude-sonnet-5"})
      |> json_response(200)
      |> Map.fetch!("data")

    assert response["model"] == "anthropic/claude-sonnet-5"
    assert response["agent_id"] == ctx.agent.id
    assert Fountain.Repo.reload!(ctx.conv).runtime_session_id == "old-session"

    response = ctx |> reapply(%{"model" => nil}) |> json_response(200) |> Map.fetch!("data")
    assert response["model"] == nil
  end

  test "422 model_invalid for a model the runtime cannot run, and nothing moves", ctx do
    resp = ctx |> reapply(%{"model" => "gemini/gemini-3-pro"}) |> json_response(422)
    assert resp["error"] == "model_invalid"
    assert Fountain.Repo.reload!(ctx.conv).model == nil

    assert Fountain.Repo.reload!(ctx.conv).configuration_revision ==
             ctx.conv.configuration_revision
  end

  test "200 keeps the thread and clears explicit nulls", ctx do
    response =
      ctx
      |> reapply(%{"vault_id" => nil})
      |> json_response(200)
      |> Map.fetch!("data")

    assert response["id"] == ctx.conv.id
    assert response["agent_id"] == ctx.agent.id
    assert response["vault_id"] == nil
    assert response["sandbox_id"] == ctx.conv.sandbox_id

    # The machine survives, so the runtime session on its disk is still
    # resumable and the agent keeps its memory of this thread.
    assert response["runtime_session_id"] == "old-session"

    [audit] =
      Fountain.Audit.list_for_user(ctx.user.id)
      |> Enum.filter(&(&1.action == "conversation.configuration_reapplied"))

    assert audit.actor == "api"
  end

  test "an empty body reapplies the current selection", ctx do
    response = ctx |> reapply(%{}) |> json_response(200) |> Map.fetch!("data")
    assert response["agent_id"] == ctx.agent.id
    assert response["vault_id"] == ctx.vault.id
  end

  test "404 for another tenant's conversation", ctx do
    other = insert_active_user()
    theirs = insert_conversation(user_id: other.id, status: "idle")

    assert %{"error" => "not_found"} =
             ctx |> reapply(%{}, theirs) |> json_response(404)
  end

  test "409 conversation_busy leaves a conversation mid-turn unchanged", ctx do
    insert_turn(ctx.conv, status: "running")

    assert %{"error" => "conversation_busy", "message" => message} =
             ctx |> reapply(%{}) |> json_response(409)

    assert message =~ "running turn"
    assert Conversations._unsafe_get_conversation!(ctx.conv.id).configuration_revision == 0
  end

  test "409 rebuild_required names the field that forced it", ctx do
    codex = insert_agent(user_id: ctx.user.id, runtime: "codex", environment_id: ctx.env.id)

    body =
      ctx
      |> reapply(%{"agent_id" => codex.id, "vault_id" => nil})
      |> json_response(409)

    assert body["error"] == "rebuild_required"
    assert body["field"] == "runtime"
    assert body["message"] =~ "different runtime"
    assert body["message"] =~ "DELETE /api/sandboxes/:id"
    assert Conversations._unsafe_get_conversation!(ctx.conv.id).agent_id == ctx.agent.id
  end

  for status <- ["ready", "suspended"], edited? <- [false, true] do
    test "missing build evidence refuses #{status} reapply and retries (edited: #{edited?})",
         ctx do
      {:ok, sandbox} =
        update_sandbox(ctx.sandbox, %{
          status: unquote(status),
          build_fingerprint: nil
        })

      if unquote(edited?) do
        {:ok, _} =
          Fountain.Environments.update_environment(ctx.env, %{"setup_script" => "echo edited"})
      end

      before = Fountain.Repo.get!(Fountain.Conversations.Conversation, ctx.conv.id)

      for _attempt <- 1..2 do
        body = ctx |> reapply(%{"vault_id" => nil}) |> json_response(409)
        assert body["error"] == "rebuild_required"
        assert body["field"] == "environment"
        assert body["message"] =~ "no recorded build fingerprint"
        assert body["message"] =~ "start a new conversation"
        assert body["message"] =~ "DELETE /api/sandboxes/:id"
        assert Fountain.Repo.reload!(sandbox) == sandbox
        assert Fountain.Repo.reload!(before) == before
      end
    end
  end

  test "503 while the machine is still being built", ctx do
    {:ok, _} = update_sandbox(ctx.sandbox, %{status: "starting"})
    {:ok, _} = Conversations.update_conversation(ctx.conv, %{status: "pending"})

    conn = reapply(ctx, %{})
    assert %{"error" => "provisioning"} = json_response(conn, 503)
    assert get_resp_header(conn, "retry-after") == ["30"]
  end

  test "410 once the conversation has ended", ctx do
    {:ok, _} = Conversations.update_conversation(ctx.conv, %{status: "terminated"})

    assert %{"error" => "conversation_terminated"} =
             ctx |> reapply(%{}) |> json_response(410)
  end

  test "422 for a selection the agent's allowlist forbids", ctx do
    locked =
      insert_agent(
        user_id: ctx.user.id,
        runtime: "claude",
        environment_id: ctx.env.id,
        allowed_vault_ids: []
      )

    other_vault = insert_vault(user_id: ctx.user.id)

    assert %{"error" => "vault_not_allowed"} =
             ctx
             |> reapply(%{"agent_id" => locked.id, "vault_id" => other_vault.id})
             |> json_response(422)
  end
end
