defmodule FountainWeb.OrphanedHomeDoorTest do
  # #1084 at the doors: the three requests that move a home's identity key out
  # from under it answer 409 rather than 500 or a silent orphan.
  use FountainWeb.ConnCase, async: true
  use Mimic

  import Phoenix.LiveViewTest

  alias Fountain.Conversations
  alias Fountain.Environments
  alias Fountain.Repo
  alias Fountain.Vaults

  setup do
    user = insert_active_user()
    {:ok, user} = Fountain.Accounts.update_sandbox_limit(user, 10)
    {_key_record, raw_key} = insert_api_key(user)
    env = insert_env(user_id: user.id)
    other_env = insert_env(user_id: user.id)
    vault = insert_vault(user_id: user.id)

    agent =
      insert_agent(
        user_id: user.id,
        runtime: "claude",
        environment_id: env.id,
        sandbox_mode: "persistent"
      )

    home =
      insert_sandbox(
        user_id: user.id,
        status: "ready",
        mode: "persistent",
        agent_id: agent.id,
        environment_id: env.id,
        vault_id: vault.id,
        provider: "sprites"
      )

    conv = insert_conversation(user_id: user.id, agent: agent, sandbox: home, status: "idle")
    stub(Managoat.Sandbox.Sprites, :destroy, fn _h -> :ok end)
    stub(Horde.DynamicSupervisor, :start_child, fn _s, _spec -> {:ok, spawn(fn -> :ok end)} end)

    {:ok,
     user: user,
     raw_key: raw_key,
     env: env,
     other_env: other_env,
     vault: vault,
     agent: agent,
     home: home,
     conv: conv}
  end

  defp authed(ctx), do: authed_with_key(ctx.conn, ctx.raw_key)

  # The spec-validated PATCH refuses a body without a declared content type.
  defp patch_agent(ctx, attrs) do
    ctx
    |> authed()
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> patch("/api/agents/#{ctx.agent.id}", attrs)
  end

  describe "PATCH /api/agents/:id" do
    test "200: moving the environment retires the home built on the old one", ctx do
      conn = patch_agent(ctx, %{"environment_id" => ctx.other_env.id})

      assert json_response(conn, 200)["data"]["environment_id"] == ctx.other_env.id
      assert Conversations._unsafe_get_sandbox!(ctx.home.id).status == "terminated"
      # The transcript is the point of a reset over a teardown.
      assert Conversations._unsafe_get_conversation!(ctx.conv.id).status == "idle"
    end

    test "409 sandbox_mid_turn while a conversation on the home is running a turn", ctx do
      insert_turn(ctx.conv, status: "running")

      conn = patch_agent(ctx, %{"environment_id" => ctx.other_env.id})

      assert json_response(conn, 409)["error"] == "sandbox_mid_turn"
      assert Conversations._unsafe_get_sandbox!(ctx.home.id).status == "ready"
      assert Fountain.Agents._unsafe_get_agent(ctx.agent.id).environment_id == ctx.env.id
    end

    test "an unrelated field still updates while a turn runs", ctx do
      insert_turn(ctx.conv, status: "running")

      conn = patch_agent(ctx, %{"name" => "renamed"})

      assert json_response(conn, 200)["data"]["name"] == "renamed"
    end
  end

  describe "persistent home runtime changes" do
    test "PATCH then repeated POST creates and reuses the new runtime home, preserving the old",
         ctx do
      assert ctx |> patch_agent(%{"runtime" => "opencode"}) |> json_response(200)

      attrs = %{"agent_id" => ctx.agent.id, "vault_id" => ctx.vault.id}

      first =
        ctx
        |> authed()
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> post("/api/conversations", attrs)
        |> json_response(201)

      first = Conversations.get_conversation(first["data"]["id"], ctx.user.id)
      refute first.sandbox_id == ctx.home.id
      assert first.runtime == "opencode"
      new_home = Conversations._unsafe_get_sandbox!(first.sandbox_id)
      assert new_home.runtime == "opencode"
      {:ok, _} = Conversations.update_sandbox(new_home, %{status: "ready"})

      second =
        ctx
        |> authed()
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> post("/api/conversations", attrs)
        |> json_response(201)

      second = Conversations.get_conversation(second["data"]["id"], ctx.user.id)
      assert second.sandbox_id == first.sandbox_id
      assert Repo.reload!(ctx.home).status == "ready"
      assert Repo.reload!(ctx.conv).sandbox_id == ctx.home.id
    end

    test "explicit wrong-runtime attachment explains the reset and fresh-launch escape", ctx do
      assert ctx |> patch_agent(%{"runtime" => "opencode"}) |> json_response(200)

      body =
        ctx
        |> authed()
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> post("/api/conversations", %{
          "agent_id" => ctx.agent.id,
          "vault_id" => ctx.vault.id,
          "sandbox_id" => ctx.home.id
        })
        |> json_response(422)

      assert body["error"] == "sandbox_runtime_mismatch"
      assert body["message"] =~ "without sandbox_id"
      assert body["message"] =~ "reset"
    end
  end

  describe "DELETE /api/vaults/:id" do
    test "204: the home built on the vault is retired first", ctx do
      assert ctx |> authed() |> delete("/api/vaults/#{ctx.vault.id}") |> response(204)
      refute Vaults.get_vault(ctx.vault.id, ctx.user.id)
      assert Conversations._unsafe_get_sandbox!(ctx.home.id).status == "terminated"
    end

    test "409 while a conversation on that home is mid-turn, and the vault stays", ctx do
      insert_turn(ctx.conv, status: "running")

      conn = ctx |> authed() |> delete("/api/vaults/#{ctx.vault.id}")

      assert json_response(conn, 409)["error"] == "sandbox_mid_turn"
      assert Vaults.get_vault(ctx.vault.id, ctx.user.id)
      assert Conversations._unsafe_get_sandbox!(ctx.home.id).status == "ready"
    end
  end

  describe "DELETE /api/environments/:id" do
    test "204: the home built on the environment is retired first", ctx do
      assert ctx |> authed() |> delete("/api/environments/#{ctx.env.id}") |> response(204)
      refute Environments.get_environment(ctx.env.id, ctx.user.id)
      assert Conversations._unsafe_get_sandbox!(ctx.home.id).status == "terminated"
    end

    test "409 while a conversation on that home is mid-turn, and the environment stays", ctx do
      insert_turn(ctx.conv, status: "running")

      conn = ctx |> authed() |> delete("/api/environments/#{ctx.env.id}")

      assert json_response(conn, 409)["error"] == "sandbox_mid_turn"
      assert Environments.get_environment(ctx.env.id, ctx.user.id)
      assert Conversations._unsafe_get_sandbox!(ctx.home.id).status == "ready"
    end
  end

  # The console's three doors. Each hard-matched `{:ok, _}` before #1084, so a
  # refusal was a MatchError and a dead LiveView rather than a flash.
  describe "the operator console" do
    setup ctx do
      {:ok, conn: login_user(ctx.conn, ctx.user)}
    end

    test "deleting a vault mid-turn flashes instead of crashing the LiveView", ctx do
      insert_turn(ctx.conv, status: "running")

      {:ok, lv, _html} = live(ctx.conn, ~p"/vaults")
      html = render_click(lv, "delete", %{"id" => ctx.vault.id})

      assert html =~ "running a turn"
      assert Vaults.get_vault(ctx.vault.id, ctx.user.id)
    end

    test "deleting an environment mid-turn flashes instead of crashing the LiveView", ctx do
      insert_turn(ctx.conv, status: "running")

      {:ok, lv, _html} = live(ctx.conn, ~p"/environments")
      html = render_click(lv, "delete", %{"id" => ctx.env.id})

      assert html =~ "running a turn"
      assert Environments.get_environment(ctx.env.id, ctx.user.id)
    end

    test "a delete with no turn running still succeeds and says so", ctx do
      {:ok, lv, _html} = live(ctx.conn, ~p"/vaults")
      html = render_click(lv, "delete", %{"id" => ctx.vault.id})

      assert html =~ "Deleted"
      refute Vaults.get_vault(ctx.vault.id, ctx.user.id)
      assert Conversations._unsafe_get_sandbox!(ctx.home.id).status == "terminated"
    end

    test "moving an agent's environment mid-turn flashes on the form", ctx do
      insert_turn(ctx.conv, status: "running")

      {:ok, lv, _html} = live(ctx.conn, ~p"/agents/#{ctx.agent.id}/edit")

      html =
        render_submit(lv, "submit", %{
          "agent" => %{
            "name" => ctx.agent.name,
            "runtime" => ctx.agent.runtime,
            "model" => ctx.agent.model,
            "environment_id" => ctx.other_env.id
          }
        })

      assert html =~ "running a turn"
      assert Fountain.Agents._unsafe_get_agent(ctx.agent.id).environment_id == ctx.env.id
    end
  end
end
