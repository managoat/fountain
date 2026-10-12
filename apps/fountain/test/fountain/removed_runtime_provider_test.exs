defmodule Fountain.RemovedRuntimeProviderTest do
  @moduledoc """
  The `opencode` runtime and the `daytona` sandbox provider are removed
  (simplify 2/5), and rows written before that still name them: agents and
  conversations whose runtime is `opencode`, and sandboxes whose provider is
  `daytona`. Both columns are plain strings, so loading such a row cannot
  raise the way an `Ecto.Enum` would; these tests pin that every read of one
  keeps working, that a launch on a removed runtime is refused with a reason,
  and what `20261012140000_retire_daytona_rows` does to the rows it touches.
  """
  use FountainWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Fountain.Accounts
  alias Fountain.Agents
  alias Fountain.Agents.Agent
  alias Fountain.Conversations
  alias Fountain.Conversations.Conversation
  alias Fountain.Conversations.Sandbox
  alias Fountain.Repo
  alias Fountain.Repo.Migrations.RetireDaytonaRows, as: Migration

  unless Code.ensure_loaded?(Migration) do
    Code.require_file(
      "../../priv/repo/migrations/20261012140000_retire_daytona_rows.exs",
      __DIR__
    )
  end

  # Writes a value the changesets no longer accept, the way the previous
  # release left it in the table.
  defp force(schema, id, sets) do
    {1, _} = Repo.update_all(from(r in schema, where: r.id == ^id), set: sets)
    Repo.get!(schema, id)
  end

  defp legacy_rows do
    user = insert_verified_user()
    {_key, raw} = insert_api_key(user)
    agent = user_id_agent(user) |> then(&force(Agent, &1.id, runtime: "opencode"))
    sandbox = insert_sandbox(user_id: user.id, agent_id: agent.id, status: "ready")

    sandbox =
      force(Sandbox, sandbox.id,
        provider: "daytona",
        status: "terminated",
        terminated_at: ~U[2026-09-01 00:00:00Z]
      )

    conv = insert_conversation(user_id: user.id, agent: agent, sandbox: sandbox, status: "idle")
    conv = force(Conversation, conv.id, runtime: "opencode")

    %{user: user, raw: raw, agent: agent, sandbox: sandbox, conv: conv}
  end

  defp user_id_agent(user), do: insert_agent(user_id: user.id)

  describe "reading rows that name a removed runtime or provider" do
    setup do
      legacy_rows()
    end

    test "the context reads load them", %{user: user, agent: agent, sandbox: sandbox, conv: conv} do
      assert %Agent{runtime: "opencode"} = Agents.get_agent(agent.id, user.id)
      assert Enum.any?(Agents.list_agents(user.id, []), &(&1.id == agent.id))
      assert %Conversation{runtime: "opencode"} = Conversations.get_conversation(conv.id, user.id)
      assert %Sandbox{provider: "daytona"} = Repo.get!(Sandbox, sandbox.id)
      assert Enum.any?(Conversations.list_sandboxes(user.id), &(&1.id == sandbox.id))
    end

    test "the API serves them", %{conn: conn, raw: raw, agent: agent, conv: conv} do
      authed = authed_with_key(conn, raw)

      assert %{"data" => %{"runtime" => "opencode"}} =
               authed |> get("/api/agents/#{agent.id}") |> json_response(200)

      assert authed |> get("/api/agents") |> json_response(200)

      assert %{"data" => %{"runtime" => "opencode"}} =
               authed |> get("/api/conversations/#{conv.id}") |> json_response(200)

      assert authed |> get("/api/conversations") |> json_response(200)
      assert authed |> get("/api/sandboxes?status=terminated") |> json_response(200)
    end

    test "the console renders them", %{conn: conn, user: user, agent: agent} do
      conn = login_user(conn, user)

      {:ok, _view, html} = live(conn, ~p"/agents")
      assert html =~ agent.name
      assert html =~ "opencode"

      assert {:ok, _view, _html} = live(conn, ~p"/agents/#{agent.id}/edit")
      assert {:ok, _view, _html} = live(conn, ~p"/dashboard")
    end

    test "the operator pages render them", %{conn: conn, user: user} do
      {:ok, admin} = Accounts.update_user_role(user, "admin")
      conn = login_user(conn, admin)

      assert {:ok, _view, _html} = live(conn, ~p"/admin")
      assert {:ok, _view, _html} = live(conn, ~p"/admin/sandboxes")
    end

    test "a removed provider reads as :removed, which nothing serves", %{sandbox: sandbox} do
      assert Conversations.sandbox_provider_atom(sandbox) == :removed
      refute Fountain.SandboxProviders.enabled?(:removed)
      refute "daytona" in Fountain.SandboxProviders.known_providers()
    end
  end

  describe "running an agent on a removed runtime" do
    setup do
      legacy_rows()
    end

    test "dispatch refuses it with what to change", %{agent: agent} do
      assert {:error, message} = Fountain.RuntimeDispatch.for_agent(agent)
      assert message =~ "unsupported runtime: opencode"
      assert message =~ "change the agent's runtime"
    end

    test "a launch is refused before anything is reserved", %{conn: conn, raw: raw, agent: agent} do
      before = Repo.aggregate(Conversation, :count)

      body =
        conn
        |> authed_with_key(raw)
        |> put_req_header("content-type", "application/json")
        |> post("/api/conversations", %{"agent_id" => agent.id, "prompt" => "hi"})
        |> json_response(400)

      assert body["error"] =~ "unsupported runtime: opencode"
      assert Repo.aggregate(Conversation, :count) == before
    end

    test "the agent can be moved to a runtime that exists", %{user: user, agent: agent} do
      assert {:ok, %Agent{runtime: "claude"}} =
               Agents.update_agent(agent, %{"runtime" => "claude"}, user_id: user.id)
    end

    test "nothing new can name it" do
      user = insert_verified_user()

      assert {:error, changeset} =
               Agents.create_agent(%{
                 "name" => "oc",
                 "runtime" => "opencode",
                 "model" => "anthropic/claude-sonnet-5",
                 "user_id" => user.id
               })

      assert %{runtime: [_]} = Fountain.DataCase.errors_on(changeset)

      assert {:error, changeset} =
               Agents.create_agent(%{
                 "name" => "dt",
                 "runtime" => "claude",
                 "model" => "anthropic/claude-sonnet-5",
                 "sandbox_provider" => "daytona",
                 "user_id" => user.id
               })

      assert %{sandbox_provider: [_]} = Fountain.DataCase.errors_on(changeset)
    end
  end

  describe "20261012140000_retire_daytona_rows" do
    test "unpins agents, terminates live Daytona sandboxes and leaves the rest" do
      user = insert_verified_user()
      pinned = insert_agent(user_id: user.id)
      pinned = force(Agent, pinned.id, sandbox_provider: "daytona")
      e2b = insert_agent(user_id: user.id)
      e2b = force(Agent, e2b.id, sandbox_provider: "e2b")

      live = insert_sandbox(user_id: user.id, status: "suspended")

      live =
        force(Sandbox, live.id,
          provider: "daytona",
          transition: "resuming",
          transition_reason: "wake",
          updated_at: ~U[2026-08-01 00:00:00Z]
        )

      ended = insert_sandbox(user_id: user.id, status: "ready")

      ended =
        force(Sandbox, ended.id,
          provider: "daytona",
          status: "failed",
          terminated_at: ~U[2026-07-01 00:00:00Z]
        )

      sprite = insert_sandbox(user_id: user.id, status: "ready")

      Ecto.Migration.Runner.run(
        Repo,
        Repo.config(),
        20_261_012_140_000,
        Migration,
        :forward,
        :up,
        :up,
        log: false
      )

      assert Repo.reload!(pinned).sandbox_provider == nil
      assert Repo.reload!(e2b).sandbox_provider == "e2b"

      live = Repo.reload!(live)
      assert live.provider == "daytona"
      assert live.status == "terminated"
      assert live.terminated_at == ~U[2026-08-01 00:00:00Z]
      assert live.transition == nil
      assert live.transition_reason == nil

      assert %Sandbox{status: "failed", terminated_at: ~U[2026-07-01 00:00:00Z]} =
               Repo.reload!(ended)

      assert %Sandbox{provider: "sprites", status: "ready"} = Repo.reload!(sprite)
    end
  end
end
