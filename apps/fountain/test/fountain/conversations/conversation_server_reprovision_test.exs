defmodule Fountain.Conversations.ConversationServerReprovisionTest do
  # A server killed mid-provision (a deploy, a Horde rebalance) is restarted
  # into handle_continue(:provision) with the sandbox row still `starting`.
  # `Sandbox.create` adopts the existing sprite by name, so without care the
  # restart re-runs every step on a half-built machine — and `git clone`
  # refuses a checkout that already exists. Seen in production the first
  # time a deploy landed during an environment's `setup` stage.
  use Fountain.ConversationServerCase

  alias Fountain.Conversations

  test "a row already `starting` gets its half-built sprite destroyed before a fresh create" do
    stub_happy_sprite()
    test_pid = self()

    Mimic.stub(Managoat.Sandbox.Sprites, :destroy, fn handle ->
      send(test_pid, {:sprite_destroyed, handle.name})
      :ok
    end)

    Mimic.stub(Managoat.Sandbox.Sprites, :create, fn name, _opts ->
      send(test_pid, {:sprite_created, name})
      {:ok, Managoat.Sandbox.Sprites.build_handle(name)}
    end)

    user = insert_verified_user()
    agent = insert_agent(user_id: user.id, runtime: "gemini")
    conv = insert_conversation(user_id: user.id, agent_id: agent.id)
    sandbox = Conversations._unsafe_get_sandbox!(conv.sandbox_id)
    {:ok, _} = update_sandbox(sandbox, %{status: "starting"})

    {pid, _ref, :alive} = start_server(conv)

    name = sandbox.machine_name
    assert_receive {:sprite_destroyed, ^name}, 5_000
    assert_receive {:sprite_created, ^name}, 5_000
    assert Conversations._unsafe_get_sandbox!(conv.sandbox_id).status == "ready"

    GenServer.call(pid, {:terminate_conv, []}, 30_000)
  end

  test "a `pending` row provisions without destroying anything" do
    stub_happy_sprite()
    test_pid = self()

    Mimic.stub(Managoat.Sandbox.Sprites, :destroy, fn _handle ->
      send(test_pid, :sprite_destroyed)
      :ok
    end)

    user = insert_verified_user()
    agent = insert_agent(user_id: user.id, runtime: "gemini")
    conv = insert_conversation(user_id: user.id, agent_id: agent.id)
    assert Conversations._unsafe_get_sandbox!(conv.sandbox_id).status == "pending"

    {pid, _ref, :alive} = start_server(conv)
    assert Conversations._unsafe_get_sandbox!(conv.sandbox_id).status == "ready"
    refute_received :sprite_destroyed

    GenServer.call(pid, {:terminate_conv, []}, 30_000)
  end

  test "a destroy that fails does not block the rebuild" do
    stub_happy_sprite()
    Mimic.stub(Managoat.Sandbox.Sprites, :destroy, fn _handle -> {:error, :not_found} end)

    user = insert_verified_user()
    agent = insert_agent(user_id: user.id, runtime: "gemini")
    conv = insert_conversation(user_id: user.id, agent_id: agent.id)
    sandbox = Conversations._unsafe_get_sandbox!(conv.sandbox_id)
    {:ok, _} = update_sandbox(sandbox, %{status: "starting"})

    {pid, _ref, :alive} = start_server(conv)
    assert Conversations._unsafe_get_sandbox!(conv.sandbox_id).status == "ready"

    GenServer.call(pid, {:terminate_conv, []}, 30_000)
  end
end
