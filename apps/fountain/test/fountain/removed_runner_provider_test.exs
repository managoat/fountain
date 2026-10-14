defmodule Fountain.RemovedRunnerProviderTest do
  @moduledoc """
  The self-hosted runner provider is removed (#2676), and rows written before
  that still name it: sandboxes whose provider is `runner`, and agents pinned
  to it. The columns are plain strings, so loading such a row cannot raise the
  way an `Ecto.Enum` would; these tests pin that every read of one keeps
  working, that nothing new can name the provider, that its routes are gone,
  and what `20261014153100_retire_runner_rows` does to the rows it touches.
  """
  use FountainWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Fountain.Accounts
  alias Fountain.Agents
  alias Fountain.Agents.Agent
  alias Fountain.Conversations
  alias Fountain.Conversations.Sandbox
  alias Fountain.Repo
  alias Fountain.Repo.Migrations.RetireRunnerRows, as: Migration

  unless Code.ensure_loaded?(Migration) do
    Code.require_file(
      "../../priv/repo/migrations/20261014153100_retire_runner_rows.exs",
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
    agent = insert_agent(user_id: user.id, name: "Ada")
    sandbox = insert_sandbox(user_id: user.id, agent_id: agent.id, status: "ready")

    sandbox =
      force(Sandbox, sandbox.id,
        provider: "runner",
        machine_name: "runner-0123456789abcdef0123456789abcdef-01234567",
        status: "terminated",
        terminated_at: ~U[2026-09-01 00:00:00Z]
      )

    conv =
      insert_conversation(
        user_id: user.id,
        agent: agent,
        sandbox: sandbox,
        status: "idle",
        channel_id: Fountain.Team.channel()
      )

    %{user: user, raw: raw, agent: agent, sandbox: sandbox, conv: conv}
  end

  describe "reading rows that name the removed provider" do
    setup do
      legacy_rows()
    end

    test "the context reads load them", %{user: user, sandbox: sandbox} do
      assert %Sandbox{provider: "runner"} = Repo.get!(Sandbox, sandbox.id)
      assert Enum.any?(Conversations.list_sandboxes(user.id), &(&1.id == sandbox.id))
    end

    test "the API serves them, with no runner field", %{conn: conn, raw: raw, conv: conv} do
      authed = authed_with_key(conn, raw)

      assert %{"data" => %{"sandbox" => sandbox}} =
               authed |> get("/api/conversations/#{conv.id}") |> json_response(200)

      assert sandbox["provider"] == "runner"
      refute Map.has_key?(sandbox, "runner")

      assert authed |> get("/api/conversations") |> json_response(200)
      assert authed |> get("/api/sandboxes?status=terminated") |> json_response(200)
      assert [entry] = authed |> get("/api/team") |> json_response(200) |> Map.fetch!("data")
      refute Map.has_key?(entry["conversation"]["sandbox"], "runner")
    end

    test "the console renders them", %{conn: conn, user: user, agent: agent} do
      conn = login_user(conn, user)

      assert {:ok, _view, _html} = live(conn, ~p"/agents")
      assert {:ok, _view, _html} = live(conn, ~p"/agents/#{agent.id}/edit")
      assert {:ok, _view, _html} = live(conn, ~p"/dashboard")
    end

    test "the operator pages render them", %{conn: conn, user: user} do
      {:ok, admin} = Accounts.update_user_role(user, "admin")
      conn = login_user(conn, admin)

      assert {:ok, _view, _html} = live(conn, ~p"/admin")
      assert {:ok, _view, _html} = live(conn, ~p"/admin/sandboxes")
    end

    test "the provider reads as :removed, which nothing serves", %{sandbox: sandbox} do
      assert Conversations.sandbox_provider_atom(sandbox) == :removed
      refute Fountain.SandboxProviders.enabled?(:removed)
      refute "runner" in Fountain.SandboxProviders.known_providers()
      refute Map.has_key?(Managoat.Sandbox.adapters(), :runner)
    end
  end

  test "nothing new can name it" do
    user = insert_verified_user()

    assert {:error, changeset} =
             Agents.create_agent(%{
               "name" => "rn",
               "runtime" => "claude",
               "model" => "anthropic/claude-sonnet-5",
               "sandbox_provider" => "runner",
               "user_id" => user.id
             })

    assert %{sandbox_provider: [_]} = Fountain.DataCase.errors_on(changeset)
  end

  test "the runner routes are gone", %{conn: conn} do
    user = insert_verified_user()
    {_key, raw} = insert_api_key(user)

    assert conn |> authed_with_key(raw) |> get("/api/runners") |> response(404)
    assert conn |> authed_with_key(raw) |> get("/api/runners/ws") |> response(404)
  end

  describe "20261014153100_retire_runner_rows" do
    test "unpins agents, terminates live runner sandboxes and leaves the rest" do
      user = insert_verified_user()
      pinned = insert_agent(user_id: user.id)
      pinned = force(Agent, pinned.id, sandbox_provider: "runner")
      e2b = insert_agent(user_id: user.id)
      e2b = force(Agent, e2b.id, sandbox_provider: "e2b")

      live = insert_sandbox(user_id: user.id, status: "ready")

      live =
        force(Sandbox, live.id,
          provider: "runner",
          transition: "suspending",
          transition_reason: "idle",
          updated_at: ~U[2026-08-01 00:00:00Z]
        )

      parked = insert_sandbox(user_id: user.id, status: "suspended")
      parked = force(Sandbox, parked.id, provider: "runner")

      ended = insert_sandbox(user_id: user.id, status: "ready")

      ended =
        force(Sandbox, ended.id,
          provider: "runner",
          status: "failed",
          terminated_at: ~U[2026-07-01 00:00:00Z]
        )

      sprite = insert_sandbox(user_id: user.id, status: "ready")

      Ecto.Migration.Runner.run(
        Repo,
        Repo.config(),
        20_261_014_153_100,
        Migration,
        :forward,
        :up,
        :up,
        log: false
      )

      assert Repo.reload!(pinned).sandbox_provider == nil
      assert Repo.reload!(e2b).sandbox_provider == "e2b"

      live = Repo.reload!(live)
      assert live.provider == "runner"
      assert live.status == "terminated"
      assert live.terminated_at == ~U[2026-08-01 00:00:00Z]
      assert live.transition == nil
      assert live.transition_reason == nil

      assert %Sandbox{status: "terminated"} = Repo.reload!(parked)

      assert %Sandbox{status: "failed", terminated_at: ~U[2026-07-01 00:00:00Z]} =
               Repo.reload!(ended)

      assert %Sandbox{provider: "sprites", status: "ready"} = Repo.reload!(sprite)
    end
  end
end
