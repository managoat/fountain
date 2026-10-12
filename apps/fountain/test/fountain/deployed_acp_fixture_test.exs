defmodule Fountain.DeployedACPFixtureTest do
  # Enabling this runtime changes application-wide admission and catalog state.
  use ExUnit.Case, async: false
  use Mimic

  alias Fountain.Agents.Agent
  alias Fountain.DeployedACPFixture
  alias Fountain.RuntimeDispatch

  @owner "aaaaaaaa-1111-4111-8111-111111111111"
  @other "bbbbbbbb-2222-4222-8222-222222222222"

  setup do
    previous = Application.get_env(:fountain, :deployed_acp_fixture)
    Application.delete_env(:fountain, :deployed_acp_fixture)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:fountain, :deployed_acp_fixture, previous),
        else: Application.delete_env(:fountain, :deployed_acp_fixture)
    end)

    :ok
  end

  defp attrs(user_id \\ @owner) do
    %{
      name: "fixture",
      runtime: "fountain-fixture",
      model: "fixture/deterministic-v1",
      user_id: user_id
    }
  end

  defp enable do
    Application.put_env(:fountain, :deployed_acp_fixture, %{enabled: true, user_id: @owner})
  end

  test "fixture is absent and denied by default, and requires a valid configured account" do
    refute DeployedACPFixture.enabled?()
    refute "fountain-fixture" in Agent.runtimes()
    refute Agent.changeset(%Agent{}, attrs()).valid?
    assert {:error, _} = RuntimeDispatch.for_agent(attrs())

    Application.put_env(:fountain, :deployed_acp_fixture, %{enabled: true, user_id: "invalid"})
    refute DeployedACPFixture.enabled?()
  end

  test "explicit fixture admission is restricted at creation and runtime dispatch" do
    enable()
    assert "fountain-fixture" in Agent.runtimes()
    assert Agent.changeset(%Agent{}, attrs()).valid?
    assert {:ok, DeployedACPFixture} = RuntimeDispatch.for_agent(attrs())
    refute Agent.changeset(%Agent{}, attrs(@other)).valid?
    assert {:error, _} = RuntimeDispatch.for_agent(attrs(@other))

    assert {:error, :fixture_disabled} =
             DeployedACPFixture.prepare_sandbox(nil, attrs(@other), [])

    Application.put_env(:fountain, :deployed_acp_fixture, %{enabled: false, user_id: @owner})
    assert {:error, _} = RuntimeDispatch.for_agent(attrs())
  end

  test "fixture cannot present a real model, ignored persona, skill or MCP configuration as working" do
    enable()

    for additions <- [
          %{model: "anthropic/claude-haiku-4-5"},
          %{system: "ignored persona"},
          %{skills: [%{"name" => "ignored"}]},
          %{mcp_servers: %{"ignored" => %{"command" => "echo"}}}
        ] do
      refute Agent.changeset(%Agent{}, Map.merge(attrs(), additions)).valid?
    end

    assert DeployedACPFixture.default_env(attrs(), %{anthropic_api_key: "not-exported"}) == []
  end

  test "an existing fixture can be maintained after disabling it without granting admission" do
    enable()
    agent = Agent.changeset(%Agent{}, attrs()) |> Ecto.Changeset.apply_changes()
    agent = Ecto.put_meta(agent, state: :loaded)
    Application.delete_env(:fountain, :deployed_acp_fixture)

    assert Agent.changeset(agent, %{name: "retired fixture"}).valid?
    assert Agent.changeset(agent, %{runtime: "fountain-fixture", description: "retired"}).valid?
    refute Agent.changeset(agent, %{user_id: @other}).valid?
    refute Agent.changeset(agent, %{skills: [%{"name" => "ignored"}]}).valid?
    refute Agent.changeset(%Agent{}, attrs()).valid?
    ordinary = %{agent | runtime: "claude", model: "anthropic/claude-sonnet-5"}
    refute Agent.changeset(ordinary, %{runtime: "fountain-fixture", model: agent.model}).valid?
    assert {:error, _} = RuntimeDispatch.for_agent(agent)
    assert {:error, :fixture_disabled} = DeployedACPFixture.prepare_sandbox(nil, agent, [])

    assert Agent.changeset(agent, %{runtime: "claude", model: "anthropic/claude-sonnet-5"}).valid?
  end

  test "packaged runtimes retain their dispatcher, ACP command and concurrency" do
    enable()

    for runtime <- ~w(claude codex gemini) do
      assert RuntimeDispatch.for_agent(%{runtime: runtime}) ==
               Managoat.Runtimes.for_runtime(runtime)

      assert RuntimeDispatch.command(runtime) == Managoat.Runtimes.ACP.command(runtime)
      assert RuntimeDispatch.concurrency(runtime) == Managoat.Runtimes.ACP.concurrency(runtime)
    end

    assert RuntimeDispatch.command("fountain-fixture") == {"node", [".fountain-acp-fixture.mjs"]}
    assert RuntimeDispatch.concurrency("fountain-fixture") == 1
    assert RuntimeDispatch.acp_enabled?("fountain-fixture")
  end

  test "the installed source matches the pinned fixture digest" do
    enable()
    digest = "0ce5a31f8a5b4a6bd3679f1fcb4818faa21b3c93238334f29c9e39ec16973751"

    expect(Managoat.Sandbox, :write_file, fn :fixture_handle, path, source ->
      assert path == "/home/sprite/.fountain-acp-fixture.mjs"
      assert Base.encode16(:crypto.hash(:sha256, source), case: :lower) == digest
      :ok
    end)

    assert :ok = DeployedACPFixture.prepare_sandbox(:fixture_handle, attrs(), [])
    assert DeployedACPFixture.sha256() == digest
  end
end
