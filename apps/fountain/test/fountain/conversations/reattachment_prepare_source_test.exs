defmodule Fountain.Conversations.ReattachmentPrepareSourceTest do
  @moduledoc """
  #2562: a reattach writes the runtime config, the instructions, the env file
  and the broker CA at once, as a fresh provision does, and only the env file
  decides whether the reattach carries on.
  """
  use Fountain.DataCase, async: true
  use Mimic

  alias Fountain.Conversations.{Egress, InferenceBinding, Provisioning, Reapply, Reattachment}
  alias Managoat.Sandbox.Handle

  @receive_timeout 2_000

  setup do
    conv = insert_conversation()

    state = %{
      conversation_id: conv.id,
      user_id: conv.user_id,
      runtime_module: nil,
      callback_token: "t",
      broker: nil,
      inference_source: nil
    }

    stub(Egress, :with_connection_servers, fn agent, _user, _conv, _token -> agent end)
    stub(Provisioning, :write_instructions, fn _handle, _runtime, _agent -> :ok end)
    stub(Provisioning, :write_env_file, fn _handle, _env -> :ok end)
    stub(Reapply, :mount_skills, fn _handle, _conv, _agent -> :ok end)
    stub(InferenceBinding, :reserve, fn _conv, _source -> :ok end)
    stub(Provisioning, :prepare_runtime_sprite, fn _, _, _, _, _, _, _ -> :ok end)

    %{conv: conv, state: state, handle: %Handle{provider: :sprites, name: "s"}}
  end

  test "the config and the CA are written at once", ctx do
    test_pid = self()

    stub(Provisioning, :write_runtime_config, fn _handle, _module, _agent ->
      send(test_pid, {:config, self()})
      receive do: (:go -> :ok)
    end)

    stub(Egress, :install_ca, fn _broker, _handle, _conv_id ->
      send(test_pid, {:ca, self()})
      receive do: (:go -> :ok)
    end)

    task =
      Task.async(fn ->
        Reattachment.prepare_source(ctx.handle, ctx.state, ctx.conv, nil, [])
      end)

    # Both have started while neither has finished: one after another, the
    # second would never begin.
    assert_receive {:config, config}, @receive_timeout
    assert_receive {:ca, ca}, @receive_timeout
    send(config, :go)
    send(ca, :go)

    assert Task.await(task) == :ok
  end

  test "a failed config or CA write is logged and the reattach carries on", ctx do
    stub(Provisioning, :write_runtime_config, fn _, _, _ -> {:error, :refused} end)
    stub(Egress, :install_ca, fn _, _, _ -> {:error, {:broker, :ca_install_exit, 1, ""}} end)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert :ok = Reattachment.prepare_source(ctx.handle, ctx.state, ctx.conv, nil, [])
      end)

    assert log =~ "runtime config write on wake"
    assert log =~ "broker CA install on wake"
  end

  test "a failed env file write is the reattach's answer", ctx do
    stub(Provisioning, :write_runtime_config, fn _, _, _ -> :ok end)
    stub(Egress, :install_ca, fn _, _, _ -> :ok end)
    stub(Provisioning, :write_env_file, fn _, _ -> {:error, :disk_full} end)
    reject(&Provisioning.prepare_runtime_sprite/7)

    assert {:error, :disk_full} =
             Reattachment.prepare_source(ctx.handle, ctx.state, ctx.conv, nil, [])
  end
end
