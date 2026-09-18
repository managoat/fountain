# Opt-in characterization of the UNFIXED #2394 race, outside normal test paths.
# Run from apps/fountain as documented in this directory's README.
# Passing means the defect was observed; invert/move these assertions with the fix.
config = Fountain.Repo.config()
url = URI.parse(config[:url] || "")
host = config[:hostname] || url.host
database = config[:database] || String.trim_leading(url.path || "", "/")

unless Mix.env() == :test and host in ["localhost", "127.0.0.1"] and
         database == "fountain_2394_test" do
  raise "This probe requires the dedicated local fountain_2394_test database"
end

defmodule Fountain.SandboxFilesRaceProbe do
  @moduledoc false
  # Both the owner gate and Mimic's provider stubs are global state.
  use Fountain.DataCase, async: false
  use Mimic

  alias Fountain.Machines.Lease
  alias Fountain.Machines.Machine
  alias Fountain.SandboxFiles

  setup :set_mimic_global

  setup ctx do
    previous = Application.fetch_env(:fountain, :machine_owner_enabled)
    Application.put_env(:fountain, :machine_owner_enabled, ctx.gate)

    user = insert_verified_user()
    agent = insert_agent(user_id: user.id, runtime: "claude")
    sandbox = insert_sandbox(user_id: user.id, agent_id: agent.id, status: "ready")

    on_exit(fn ->
      stop_machine(sandbox.id)

      case previous do
        {:ok, value} -> Application.put_env(:fountain, :machine_owner_enabled, value)
        :error -> Application.delete_env(:fountain, :machine_owner_enabled)
      end
    end)

    stub(Managoat.Sandbox, :supports?, fn :sprites, capability -> capability == :suspend end)
    reject(&Managoat.Sandbox.create/2)
    reject(&Managoat.Sandbox.destroy/1)
    reject(&Managoat.Sandbox.resume/1)
    reject(&Managoat.Sandbox.get/1)
    reject(&Managoat.Sandbox.create_checkpoint/2)

    {:ok, sandbox: sandbox}
  end

  for gate <- [false, true], operation <- [:list, :read, :diff, :status] do
    @tag gate: gate, operation: operation
    test "#{operation}, owner=#{gate}: stale ready struct executes after completed park", ctx do
      test_pid = self()
      stub(Managoat.Sandbox, :suspend, fn _ -> :ok end)
      expect_read(ctx, fn row -> send(test_pid, {:read_row, row.status}) end)

      park = Task.async(fn -> park(ctx.sandbox) end)
      assert {:ok, :parked} = Task.await(park)
      assert Repo.reload!(ctx.sandbox).status == "suspended"
      assert ctx.sandbox.status == "ready"

      # Defect: the supplied ready snapshot still authorizes provider exec.
      assert {:ok, _} = read(ctx)
      assert_received {:read_row, "suspended"}
    end

    @tag gate: gate, operation: operation
    test "#{operation}, owner=#{gate}: a read enters while park owns the live lease", ctx do
      test_pid = self()

      stub(Managoat.Sandbox, :suspend, fn _ ->
        refute Repo.in_transaction?()
        send(test_pid, {:park_entered, self()})
        await_release()
        :ok
      end)

      expect_read(ctx, fn row ->
        send(test_pid, {:read_row, row.status, row.transition, Lease.live?(row)})
      end)

      park = Task.async(fn -> park(ctx.sandbox) end)
      assert_receive {:park_entered, provider_pid}, 2_000

      try do
        # Defect: even the committed parking stamp plus live lease is ignored.
        assert {:ok, _} = read(ctx)
        assert_received {:read_row, "ready", "parking", true}
      after
        send(provider_pid, :release)
      end

      assert {:ok, :parked} = Task.await(park)
      assert is_nil(Repo.reload!(ctx.sandbox).lease_node)
    end

    @tag gate: gate, operation: operation
    test "#{operation}, owner=#{gate}: park completes while read provider call is held", ctx do
      test_pid = self()

      expect_read(ctx, fn row ->
        send(test_pid, {:read_entered, self(), row.status})
        await_release()
      end)

      stub(Managoat.Sandbox, :suspend, fn _ ->
        refute Repo.in_transaction?()
        send(test_pid, :park_entered)
        :ok
      end)

      read = Task.async(fn -> read(ctx) end)
      assert_receive {:read_entered, provider_pid, "ready"}, 2_000

      try do
        park = Task.async(fn -> park(ctx.sandbox) end)
        assert {:ok, :parked} = Task.await(park)
        assert_received :park_entered
        assert Repo.reload!(ctx.sandbox).status == "suspended"
        # The read remains inside its provider call until explicitly released.
        assert Process.alive?(provider_pid)
      after
        send(provider_pid, :release)
      end

      assert {:ok, _} = Task.await(read)
    end
  end

  defp read(%{operation: :list, sandbox: sandbox}), do: SandboxFiles.list(sandbox, nil)
  defp read(%{operation: :read, sandbox: sandbox}), do: SandboxFiles.read(sandbox, "note.txt")
  defp read(%{operation: :diff, sandbox: sandbox}), do: SandboxFiles.diff(sandbox, nil)
  defp read(%{operation: :status, sandbox: sandbox}), do: SandboxFiles.status(sandbox, nil)

  defp park(sandbox),
    do: Machine.park(sandbox.id, actor: "system:sandbox_reaper", reason: :idle)

  defp expect_read(ctx, at_exec) do
    expect(Managoat.Sandbox, :exec, fn handle,
                                       "bash",
                                       ["-c", _script, "fountain-files" | _args],
                                       opts ->
      refute Repo.in_transaction?()
      assert handle.name == ctx.sandbox.machine_name
      assert opts[:timeout] == 30_000
      at_exec.(Repo.reload!(ctx.sandbox))
      {:ok, output(ctx.operation), 0}
    end)
  end

  defp output(:list), do: "file\t4\tnote.txt\0"
  defp output(:read), do: "4\n" <> Base.encode64("test")
  defp output(:diff), do: "/home/sprite\0" <> Base.encode64("diff")
  defp output(:status), do: "/home/sprite\0main\0?? note.txt\0"

  defp await_release do
    receive do
      :release -> :ok
    after
      5_000 -> raise "provider barrier was not released"
    end
  end

  defp stop_machine(sandbox_id) do
    case Machine.whereis(sandbox_id) do
      nil ->
        :ok

      pid ->
        ref = Process.monitor(pid)
        Horde.DynamicSupervisor.terminate_child(Fountain.MachineSupervisor, pid)

        receive do
          {:DOWN, ^ref, :process, ^pid, _} -> :ok
        after
          2_000 -> Process.demonitor(ref, [:flush])
        end
    end
  end
end
