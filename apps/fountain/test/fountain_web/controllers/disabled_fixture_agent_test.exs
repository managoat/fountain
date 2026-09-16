defmodule FountainWeb.DisabledFixtureAgentTest do
  use FountainWeb.ConnCase, async: false

  alias Fountain.{Agents, RuntimeDispatch}
  alias FountainWeb.SchemaGuard

  setup do
    previous = Application.get_env(:fountain, :deployed_acp_fixture)
    user = insert_verified_user()
    {_key, raw_key} = insert_api_key(user)
    Application.put_env(:fountain, :deployed_acp_fixture, %{enabled: true, user_id: user.id})

    {:ok, agent} =
      Agents.create_agent(%{
        name: "fixture",
        runtime: "fountain-fixture",
        model: "fixture/deterministic-v1",
        user_id: user.id
      })

    # How a deployment disables it: `DEPLOYED_ACP_FIXTURE_ENABLED` goes false
    # and the account stays named, which is what keeps this agent's runtime —
    # and its conversations' — in the enum this deployment serves while any of
    # them is still around (#1716).
    Application.put_env(:fountain, :deployed_acp_fixture, %{enabled: false, user_id: user.id})
    OpenApiSpex.Plug.Cache.adapter().erase(FountainWeb.ApiSpec)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:fountain, :deployed_acp_fixture, previous),
        else: Application.delete_env(:fountain, :deployed_acp_fixture)

      OpenApiSpex.Plug.Cache.adapter().erase(FountainWeb.ApiSpec)
    end)

    %{agent: agent, user: user, raw_key: raw_key}
  end

  test "the owner can edit a disabled fixture through the API", ctx do
    conn =
      ctx.conn
      |> authed_with_key(ctx.raw_key)
      |> put_json("/api/agents/#{ctx.agent.id}", %{name: "retired fixture"})

    assert json_response(conn, 200)["data"]["name"] == "retired fixture"
    assert {:error, _} = RuntimeDispatch.for_agent(Agents.get_agent(ctx.agent.id, ctx.user.id))
  end

  test "the owner can delete a disabled fixture through the API", ctx do
    conn = ctx.conn |> authed_with_key(ctx.raw_key) |> delete("/api/agents/#{ctx.agent.id}")
    assert response(conn, 204)
    refute Agents.get_agent(ctx.agent.id, ctx.user.id)
  end

  # Deleting the last fixture agent is not the end of the fixture's footprint:
  # `Agents.delete_agent_row/2` keeps its conversations, which still render
  # `fountain-fixture` here and in their sandbox. The account stays named until
  # that history is gone too, or the served enums disown a value the API
  # returns (#1716). The schema guard checks both responses below against the
  # spec this deployment serves.
  test "a deleted fixture's conversations still validate while the account is named", ctx do
    conversation = insert_conversation(agent: ctx.agent)
    conn = ctx.conn |> authed_with_key(ctx.raw_key) |> delete("/api/agents/#{ctx.agent.id}")
    assert response(conn, 204)

    shown =
      build_conn()
      |> authed_with_key(ctx.raw_key)
      |> get("/api/conversations/#{conversation.id}")

    assert %{"runtime" => "fountain-fixture", "agent_id" => nil} =
             json_response(shown, 200)["data"]

    conn =
      build_conn()
      |> authed_with_key(ctx.raw_key)
      |> get("/api/sandboxes/#{conversation.sandbox_id}")

    assert [%{"runtime" => "fountain-fixture"}] =
             json_response(conn, 200)["data"]["conversations"]

    assert {:ok, _operation} = SchemaGuard.check(shown)

    # Clearing the account is what the retirement guidance forbids: the same
    # response no longer fits the enum this deployment would serve.
    Application.delete_env(:fountain, :deployed_acp_fixture)

    assert {:violation, %{message: message}} = SchemaGuard.check(shown)
    assert message =~ "runtime: Invalid value for enum"
  end

  test "another tenant cannot edit or delete the fixture", ctx do
    {_key, raw_key} = insert_api_key(insert_verified_user())

    conn =
      ctx.conn
      |> authed_with_key(raw_key)
      |> put_json("/api/agents/#{ctx.agent.id}", %{name: "stolen"})

    assert json_response(conn, 404)
    conn = build_conn() |> authed_with_key(raw_key) |> delete("/api/agents/#{ctx.agent.id}")
    assert json_response(conn, 404)
    assert Agents.get_agent(ctx.agent.id, ctx.user.id)
  end
end
