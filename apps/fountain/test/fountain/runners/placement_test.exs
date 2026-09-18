defmodule Fountain.Runners.PlacementTest do
  @moduledoc """
  A conversation on an agent pinned to the runner provider is placed on the
  user's online runner at start — the runner id rides in the sandbox name
  (ADR 0022) — and is refused plainly when no runner is online.
  """

  # `runners_enabled` is global application env (off in test config), so this
  # cannot share a partition with anything reading provider enabledness.
  use Fountain.DataCase, async: false
  use Mimic

  alias Fountain.Conversations
  alias Fountain.Runners
  alias Managoat.Runner.FakeDaemon
  alias Fountain.Conversations.Launch

  setup do
    previous = Application.get_env(:fountain, :runners_enabled)
    Application.put_env(:fountain, :runners_enabled, true)
    on_exit(fn -> Application.put_env(:fountain, :runners_enabled, previous) end)
    stub_server_start(fn _s, _spec -> {:ok, spawn(fn -> :ok end)} end)
    :ok
  end

  test "an agent can pin the runner provider once runners are enabled" do
    user = insert_verified_user()
    agent = insert_agent(user_id: user.id)
    assert {:ok, agent} = Fountain.Agents.update_agent(agent, %{"sandbox_provider" => "runner"})
    assert agent.sandbox_provider == "runner"
  end

  test "start_conversation refuses when no runner is online, allocating nothing" do
    user = insert_verified_user()
    agent = insert_agent(user_id: user.id, sandbox_provider: "runner")
    before = Fountain.Quotas.active_sandbox_count(user.id)

    assert {:error, :no_runner_online} =
             Launch.start_conversation(%{"agent_id" => agent.id, "user_id" => user.id})

    assert Fountain.Quotas.active_sandbox_count(user.id) == before
  end

  test "start_conversation places the sandbox on the online runner" do
    user = insert_verified_user()
    agent = insert_agent(user_id: user.id, sandbox_provider: "runner")
    {:ok, runner} = Runners.register(user.id, %{"name" => "mini"})
    {:ok, daemon} = FakeDaemon.start(runner.id, meta: %{user_id: user.id}, name: "mini")
    on_exit(fn -> FakeDaemon.stop(daemon) end)

    assert {:ok, conv} =
             Launch.start_conversation(%{"agent_id" => agent.id, "user_id" => user.id})

    sandbox = Conversations._unsafe_get_sandbox!(conv.sandbox_id)
    assert sandbox.provider == "runner"
    assert {:ok, runner_id} = Runners.parse_sandbox_name(sandbox.machine_name)
    assert runner_id == runner.id
  end

  test "an explicit sprite_name is refused on the runner provider" do
    # The name is the placement here: it carries the runner id, and an
    # account-scoped name cannot also be a runner name. Refusing beats minting
    # a sandbox `Runners.parse_sandbox_name/1` cannot read back (#1632).
    user = insert_verified_user()
    agent = insert_agent(user_id: user.id, sandbox_provider: "runner")
    {:ok, runner} = Runners.register(user.id, %{"name" => "mini"})
    {:ok, daemon} = FakeDaemon.start(runner.id, meta: %{user_id: user.id}, name: "mini")
    on_exit(fn -> FakeDaemon.stop(daemon) end)

    before = Fountain.Quotas.active_sandbox_count(user.id)

    assert {:error, :sprite_name_not_supported} =
             Launch.start_conversation(%{
               "agent_id" => agent.id,
               "user_id" => user.id,
               "sprite_name" => "pinned-name"
             })

    assert Fountain.Quotas.active_sandbox_count(user.id) == before
  end

  test "an empty sprite_name on the runner provider mints rather than refusing" do
    # Load-bearing on clause order: the `""` clause sits before the runner
    # refusal, so an empty override is no override here too and placement
    # still happens. Consistent with `sandbox_mode`, and worth pinning —
    # reordering the two clauses would turn every empty string into a 422.
    user = insert_verified_user()
    agent = insert_agent(user_id: user.id, sandbox_provider: "runner")
    {:ok, runner} = Runners.register(user.id, %{"name" => "mini"})
    {:ok, daemon} = FakeDaemon.start(runner.id, meta: %{user_id: user.id}, name: "mini")
    on_exit(fn -> FakeDaemon.stop(daemon) end)

    assert {:ok, conv} =
             Launch.start_conversation(%{
               "agent_id" => agent.id,
               "user_id" => user.id,
               "sprite_name" => ""
             })

    sandbox = Conversations._unsafe_get_sandbox!(conv.sandbox_id)
    assert {:ok, runner_id} = Runners.parse_sandbox_name(sandbox.machine_name)
    assert runner_id == runner.id
  end

  test "a runner sandbox's own name does not round-trip, it is refused" do
    # The reason the round-trip claim is scoped to the hosted providers: a
    # runner name is 48 characters and carries no account prefix, so handing
    # one back is the refusal above rather than an adoption of that machine.
    user = insert_verified_user()
    agent = insert_agent(user_id: user.id, sandbox_provider: "runner")
    {:ok, runner} = Runners.register(user.id, %{"name" => "mini"})
    {:ok, daemon} = FakeDaemon.start(runner.id, meta: %{user_id: user.id}, name: "mini")
    on_exit(fn -> FakeDaemon.stop(daemon) end)

    assert {:ok, conv} =
             Launch.start_conversation(%{"agent_id" => agent.id, "user_id" => user.id})

    minted = Conversations._unsafe_get_sandbox!(conv.sandbox_id).machine_name

    assert {:error, :sprite_name_not_supported} =
             Launch.start_conversation(%{
               "agent_id" => agent.id,
               "user_id" => user.id,
               "sprite_name" => minted
             })
  end

  test "an explicit sprite_name is honored regardless of provider, under this account's prefix" do
    user = insert_verified_user()
    agent = insert_agent(user_id: user.id)

    assert {:ok, conv} =
             Launch.start_conversation(%{
               "agent_id" => agent.id,
               "user_id" => user.id,
               "sprite_name" => "pinned-name"
             })

    # The override still decides the name; it decides only the suffix (#1632).
    assert Conversations._unsafe_get_sandbox!(conv.sandbox_id).machine_name ==
             "fountain-" <> binary_part(user.id, 0, 8) <> "-pinned-name"
  end
end
