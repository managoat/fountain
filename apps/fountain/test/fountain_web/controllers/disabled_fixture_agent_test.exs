defmodule FountainWeb.DisabledFixtureAgentTest do
  use FountainWeb.ConnCase, async: false

  alias Fountain.{Agents, RuntimeDispatch}

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
    # and the account stays named, which is what keeps this agent's runtime in
    # the enum this deployment serves while it is still around (#1716).
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
