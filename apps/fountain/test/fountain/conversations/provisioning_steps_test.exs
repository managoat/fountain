defmodule Fountain.Conversations.ProvisioningStepsTest do
  @moduledoc """
  The steps that moved out of `ConversationServer` in #1372: recording the
  machine's URL, the user's setup script and the runtime's files. Driven with
  the `Managoat.Sandbox` facade stubbed, no server.
  """
  use Fountain.DataCase, async: true
  use Mimic

  import ExUnit.CaptureLog

  alias Fountain.Conversations
  alias Fountain.Conversations.Provisioning
  alias Managoat.Sandbox.Handle

  defmodule ConfigRuntime do
    def write_config(_handle, agent), do: {:wrote, agent}
    def prepare_sandbox(_handle, agent, sprite_env), do: {:prepared, agent, sprite_env}
  end

  defmodule BareRuntime do
  end

  defp handle(name \\ "s"), do: %Handle{provider: :sprites, name: name}

  # The lease a provision would be holding while its pipeline runs.
  defp claim(sandbox) do
    {:ok, epoch} = Fountain.Machines.Lease.claim(sandbox.id, "test@node", 60_000)
    epoch
  end

  # The stage events of one stage as `{state, meta}` pairs, in order.
  defp stages(conv_id, stage) do
    Fountain.Repo.all(
      from(e in Conversations.LogEvent,
        where: e.conversation_id == ^conv_id and e.kind == "stage" and e.stage == ^stage,
        order_by: e.id
      )
    )
    |> Enum.map(&{&1.state, Jason.decode!(&1.data)})
  end

  # `create_sandbox_handle/2` left this module in ADR 0058 stage 7b, with the
  # discard of an interrupted attempt beside it: both are mutations of a machine
  # rather than steps inside one, and they are `Fountain.Machines.Provision`'s
  # now. `machines/provision_test.exs` covers them where they live.

  describe "record_sandbox_url/3" do
    test "stores the URL on the row and returns it" do
      sandbox = insert_sandbox()
      epoch = claim(sandbox)
      stub(Managoat.Sandbox, :public_url, fn _handle -> {:ok, "https://s.example"} end)

      assert Provisioning.record_sandbox_url(sandbox, handle(), epoch) == "https://s.example"

      assert Conversations._unsafe_get_sandbox(sandbox.id).provider_meta["public_url"] ==
               "https://s.example"
    end

    test "is nil, and touches nothing, when the provider has no URL or fails or raises" do
      sandbox = insert_sandbox()
      epoch = claim(sandbox)

      for reply <- [{:error, :unsupported}, {:error, :timeout}] do
        stub(Managoat.Sandbox, :public_url, fn _handle -> reply end)
        assert Provisioning.record_sandbox_url(sandbox, handle(), epoch) == nil
      end

      stub(Managoat.Sandbox, :public_url, fn _handle -> raise "provider surprise" end)
      assert Provisioning.record_sandbox_url(sandbox, handle(), epoch) == nil

      refute Conversations._unsafe_get_sandbox(sandbox.id).provider_meta["public_url"]
    end

    # The write is a compare-and-set on the provision's lease (stage 7b), so an
    # attempt that has lost the machine records nothing — the URL would name a
    # host it created and then destroyed, on a row another owner is building.
    test "records nothing for an attempt that no longer holds the machine" do
      sandbox = insert_sandbox()
      epoch = claim(sandbox)
      superseded = epoch + 7
      stub(Managoat.Sandbox, :public_url, fn _handle -> {:ok, "https://s.example"} end)

      assert capture_log(fn ->
               assert Provisioning.record_sandbox_url(sandbox, handle(), superseded) ==
                        "https://s.example"
             end) =~ "not recording the machine URL"

      refute Conversations._unsafe_get_sandbox(sandbox.id).provider_meta["public_url"]
    end
  end

  describe "run_setup_script/4" do
    test "is a no-op without a script" do
      assert :ok = Provisioning.run_setup_script(handle(), nil, [], "c")
      assert :ok = Provisioning.run_setup_script(handle(), %{setup_script: ""}, [], "c")
    end

    test "runs the script with the sprite env, logs its output and publishes the stage" do
      conv = insert_conversation()
      sprite_env = [{"A", "1"}]

      stub(Managoat.Sandbox, :exec, fn _handle, "bash", ["-lc", "echo hi"], opts ->
        assert opts[:env] == sprite_env
        assert opts[:stderr_to_stdout]
        assert opts[:timeout] == 120_000
        {:ok, "hi\n", 0}
      end)

      assert :ok =
               Provisioning.run_setup_script(
                 handle(),
                 %{setup_script: "echo hi"},
                 sprite_env,
                 conv.id
               )

      assert [%{data: "hi\n", stage: "setup", stream: "stdout"}] =
               Fountain.Repo.all(
                 from(e in Conversations.LogEvent,
                   where: e.conversation_id == ^conv.id and e.kind == "output"
                 )
               )

      assert stages(conv.id, "setup") == [{"started", %{}}, {"done", %{"exit_code" => 0}}]
    end

    test "a persisted timeout reaches exec and timeout remains failed setup" do
      conv = insert_conversation()
      env = insert_env(setup_script: "install-dependencies", setup_timeout_seconds: 900)

      expect(Managoat.Sandbox, :exec, fn _handle, "bash", ["-lc", "install-dependencies"], opts ->
        assert opts[:timeout] == 900_000
        {:error, :timeout}
      end)

      assert {:error, {:setup_unreachable, :timeout}} =
               Provisioning.run_setup_script(handle(), env, [], conv.id)

      assert stages(conv.id, "setup") == [
               {"started", %{}},
               {"failed", %{"reason" => ":timeout"}}
             ]
    end

    test "a non-zero exit is the step's failure, with the exit code" do
      conv = insert_conversation()
      stub(Managoat.Sandbox, :exec, fn _handle, "bash", _args, _opts -> {:ok, "boom", 3} end)

      assert {:error, {:setup_exit, 3}} =
               Provisioning.run_setup_script(handle(), %{setup_script: "exit 3"}, [], conv.id)

      assert stages(conv.id, "setup") == [{"started", %{}}, {"failed", %{"exit_code" => 3}}]
    end

    test "an unreachable sandbox is the step's failure, with the reason" do
      conv = insert_conversation()
      stub(Managoat.Sandbox, :exec, fn _handle, "bash", _args, _opts -> {:error, :nxdomain} end)

      assert {:error, {:setup_unreachable, :nxdomain}} =
               Provisioning.run_setup_script(handle(), %{setup_script: "true"}, [], conv.id)

      assert stages(conv.id, "setup") == [
               {"started", %{}},
               {"failed", %{"reason" => ":nxdomain"}}
             ]
    end
  end

  describe "write_runtime_config/3" do
    test "delegates to a runtime that writes config, and is :ok for one that does not" do
      assert {:wrote, %{mcp_servers: %{}}} =
               Provisioning.write_runtime_config(handle(), ConfigRuntime, %{mcp_servers: %{}})

      assert :ok = Provisioning.write_runtime_config(handle(), BareRuntime, %{})
    end
  end

  describe "write_instructions/3" do
    test "writes the agent's system prompt into the runtime's instructions file" do
      agent = %{name: "Desk", system: "Be brief."}

      # `Instructions.write/3` calls the facade's arity-3 `write_file`, and
      # Mimic intercepts a function by arity, so that is the one to stub.
      stub(Managoat.Sandbox, :write_file, fn _handle, path, body ->
        assert String.ends_with?(path, "GEMINI.md")
        assert body =~ "Be brief."
        :ok
      end)

      assert :ok = Provisioning.write_instructions(handle(), "gemini", agent)
    end

    test "is best effort: a refused write is still :ok, and no agent is nothing to write" do
      stub(Managoat.Sandbox, :write_file, fn _handle, _path, _body -> {:error, :nope} end)

      assert :ok =
               Provisioning.write_instructions(handle(), "gemini", %{name: "Desk", system: "x"})

      assert :ok = Provisioning.write_instructions(handle(), "gemini", nil)
    end
  end

  describe "prepare_runtime_sprite/5 and prepare_acp_adapter/3" do
    test "a native ACP runtime installs nothing, then the runtime prepares the sandbox" do
      assert {:prepared, :agent, [{"A", "1"}]} =
               Provisioning.prepare_runtime_sprite(handle(), "gemini", ConfigRuntime, :agent, [
                 {"A", "1"}
               ])

      assert :ok = Provisioning.prepare_runtime_sprite(handle(), "opencode", BareRuntime, nil, [])
    end

    test "an adapter runtime installs the adapter first, and its failure is the step's" do
      stub(Managoat.Sandbox, :exec, fn _handle, "bash", ["-lc", script], _opts ->
        assert script =~ "npm install -g"
        {:ok, "", 0}
      end)

      assert :ok = Provisioning.prepare_acp_adapter(handle(), "claude", [])
      assert :ok = Provisioning.prepare_runtime_sprite(handle(), "claude", BareRuntime, nil, [])

      stub(Managoat.Sandbox, :exec, fn _handle, "bash", _args, _opts -> {:error, :nxdomain} end)

      assert {:error, _} =
               Provisioning.prepare_runtime_sprite(handle(), "claude", ConfigRuntime, nil, [])
    end

    test "a runtime that is not ACP-driven installs nothing" do
      assert :ok = Provisioning.prepare_acp_adapter(handle(), "legacy", [])
    end
  end
end
