defmodule Fountain.Conversations.ConversationServerLayerRestoreTest do
  use Fountain.ConversationServerCase
  alias Fountain.Conversations.Provisioning
  alias Fountain.EnvironmentLayers.{Economics, Restore}

  setup context do
    unless context[:real_policy] do
      stub(Economics, :prepare, fn _ ->
        %{attempt: true, reason: "bounded_trial", evidence: %{}}
      end)
    end

    :ok
  end

  defp conversation do
    user = insert_verified_user()

    env =
      insert_env(
        user_id: user.id,
        cache_enabled: true,
        build_script: "reusable",
        setup_script: "boot"
      )

    agent = insert_agent(user_id: user.id, runtime: "gemini", environment_id: env.id)
    insert_conversation(user_id: user.id, agent_id: agent.id)
  end

  @tag :real_policy
  test "identical fresh launches accumulate true cold controls before any restore probe" do
    stub_happy_sprite()
    user = insert_verified_user()
    env = insert_env(user_id: user.id, cache_enabled: true, build_script: "reusable")
    agent = insert_agent(user_id: user.id, runtime: "gemini", environment_id: env.id)
    stub(Fountain.EnvironmentLayers.Store, :identity, fn -> {:ok, "private-store"} end)
    parent = self()

    expect(Restore, :measure, fn _, _, _, _ ->
      send(parent, :cache_attempt)
      {:warm, [], %{bytes: 123, restore_ms: 5}}
    end)

    for n <- 1..4 do
      conv = insert_conversation(user_id: user.id, agent_id: agent.id)
      {pid, _ref, :alive} = start_server(conv)

      if n <= 3 do
        refute_received :cache_attempt
        state = Repo.get_by!(Fountain.EnvironmentLayers.EconomicsState, environment_id: env.id)
        assert length(state.samples) == n
        assert Enum.all?(state.samples, &(&1["mode"] == "cold"))
      else
        assert_received :cache_attempt
      end

      GenServer.call(pid, {:terminate_conv, []}, 30_000)
    end
  end

  test "warm restore precedes configuration and skips reusable work but runs boot" do
    stub_happy_sprite()
    conv = conversation()
    parent = self()

    stub(Restore, :measure, fn _, _, _, _ ->
      send(parent, :restored)
      {:warm, [], %{bytes: 123, restore_ms: 5}}
    end)

    stub(Provisioning, :write_env_file, fn _, _ ->
      send(parent, :configured)
      :ok
    end)

    reject(&Provisioning.install_packages/4)
    reject(&Provisioning.clone_repositories/5)
    reject(&Provisioning.run_build_script/4)

    expect(Provisioning, :run_setup_script, fn _, _, _, _ ->
      send(parent, :boot)
      :ok
    end)

    {pid, _ref, :alive} = start_server(conv)
    assert_receive :restored
    assert_receive :configured
    assert_receive :boot
    events = Conversations._unsafe_list_log_events(conv.id)
    assert Enum.any?(events, &(&1.stage == "checkpoint_restore" and &1.state == "done"))
    GenServer.call(pid, {:terminate_conv, []}, 30_000)
  end

  test "failed restore destroys the machine and runs cold setup once without reprobe" do
    stub_happy_sprite()
    conv = conversation()
    parent = self()
    expect(Restore, :measure, fn _, _, _, _ -> {:retry_fresh, %{restore_ms: 5}} end)

    stub(Managoat.Sandbox.Sprites, :destroy, fn _ ->
      send(parent, :destroyed)
      :ok
    end)

    expect(Provisioning, :run_build_script, fn _, _, _, _ ->
      send(parent, :cold_build)
      :ok
    end)

    {pid, _ref, :alive} = start_server(conv)
    assert_receive :destroyed
    assert_receive :cold_build
    assert Conversations._unsafe_get_sandbox!(conv.sandbox_id).status == "ready"
    GenServer.call(pid, {:terminate_conv, []}, 30_000)
  end

  test "a boot failure after extraction gets exactly one fresh cold attempt" do
    stub_happy_sprite()
    conv = conversation()
    parent = self()
    expect(Restore, :measure, fn _, _, _, _ -> {:warm, [], %{bytes: 123, restore_ms: 5}} end)

    stub(Managoat.Sandbox.Sprites, :destroy, fn _ ->
      send(parent, :destroyed)
      :ok
    end)

    expect(Provisioning, :run_setup_script, fn _, _, _, _ -> {:error, :boot_failed} end)
    expect(Provisioning, :run_setup_script, fn _, _, _, _ -> :ok end)

    expect(Provisioning, :run_build_script, fn _, _, _, _ ->
      send(parent, :cold_build)
      :ok
    end)

    {pid, _ref, :alive} = start_server(conv)
    assert_receive :destroyed
    assert_receive :cold_build

    refute Enum.any?(
             Conversations._unsafe_list_log_events(conv.id),
             &(&1.stage == "checkpoint_restore" and &1.state == "done")
           )

    assert Conversations._unsafe_get_sandbox!(conv.sandbox_id).status == "ready"
    GenServer.call(pid, {:terminate_conv, []}, 30_000)
  end

  test "fallback retains the original configuration snapshot when another actor reassigns it" do
    stub_happy_sprite()
    conv = conversation()
    replacement = insert_agent(user_id: conv.user_id, runtime: "gemini")
    expect(Restore, :measure, fn _, _, _, _ -> {:warm, [], %{bytes: 123, restore_ms: 5}} end)

    expect(Provisioning, :run_setup_script, fn _, _, _, _ ->
      conv |> Ecto.Changeset.change(agent_id: replacement.id) |> Repo.update!()
      {:error, :boot_failed}
    end)

    stub(Provisioning, :run_setup_script, fn _, _, _, _ -> :ok end)
    {_pid, ref, :stopped} = start_server(conv)
    assert :normal = assert_stopped(ref)
    assert Repo.reload!(conv).agent_id == replacement.id

    refute Enum.any?(
             Conversations._unsafe_list_log_events(conv.id),
             &(&1.stage == "checkpoint_restore" and &1.state == "done")
           )
  end
end
