defmodule Fountain.Conversations.ConversationServerLayerRestoreTest do
  use Fountain.ConversationServerCase
  alias Fountain.Conversations.Provisioning
  alias Fountain.EnvironmentLayers.Restore

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

  test "warm restore precedes configuration and skips reusable work but runs boot" do
    stub_happy_sprite()
    conv = conversation()
    parent = self()

    stub(Restore, :attempt, fn _, _, _, _ ->
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
    expect(Restore, :attempt, fn _, _, _, _ -> :retry_fresh end)

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
    expect(Restore, :attempt, fn _, _, _, _ -> {:warm, [], %{bytes: 123, restore_ms: 5}} end)

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
end
