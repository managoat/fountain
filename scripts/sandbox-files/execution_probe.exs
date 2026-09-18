# Offline characterization, not a passing acceptance suite for #2394.
# Run: MIX_ENV=test mise exec -- mix run --no-start scripts/sandbox-files/execution_probe.exs
# No Fountain application, database, credentials or live provider is used.
unless Mix.env() == :test, do: raise("run with MIX_ENV=test")

{:ok, _} = Application.ensure_all_started(:mimic)

for mod <- [
      Sprites,
      Managoat.Sandbox.Sprites.Client,
      Managoat.Sandbox.E2B.Api,
      Managoat.Sandbox.E2B.CommandServer,
      Managoat.Sandbox.Daytona.Api,
      Managoat.Sandbox.Daytona.Toolbox
    ] do
  Mimic.copy(mod)
end

ExUnit.start(autorun: false, seed: 0)

defmodule Fountain.FilesExecutionProbe do
  use ExUnit.Case, async: false
  use Mimic

  alias Managoat.Sandbox
  alias Managoat.Sandbox.{Daytona, E2B, Handle}
  alias Managoat.Sandbox.Sprites, as: SpriteAdapter

  # These tests assert existing gaps. Passing is evidence that the current
  # implementation cannot supply the desired absolute execution guarantee.
  setup :set_mimic_global
  setup :verify_on_exit!

  setup do
    stub(Managoat.Sandbox.Sprites.Client, :get!, fn -> %Sprites.Client{token: "unused"} end)
    stub(E2B.Api, :find_by_name, fn "probe" -> {:ok, %{"sandboxID" => "offline"}} end)
    :ok
  end

  for provider <- [:sprites, :e2b], stream <- [:stdout, :stderr] do
    test "#{provider}: continuous #{stream} extends the supplied timeout" do
      timeout = 300
      test_pid = self()
      ref = make_ref()

      # A finite stub stream: every interval is shorter than the inactivity
      # timeout, while the whole command takes more than twice that timeout.
      sender =
        spawn(fn ->
          receive do
            {:start, owner} ->
              for _ <- 1..10 do
                send(owner, {unquote(stream), %{ref: ref}, "x"})
                Process.sleep(90)
              end

              send(owner, {:exit, %{ref: ref}, 0})
          end
        end)

      on_exit(fn -> if Process.alive?(sender), do: Process.exit(sender, :kill) end)

      case unquote(provider) do
        :sprites ->
          expect(Sprites, :spawn, fn _, "probe", [], opts ->
            send(sender, {:start, opts[:owner]})
            {:ok, %Sprites.Command{ref: ref, pid: sender}}
          end)

        :e2b ->
          expect(E2B.CommandServer, :start, fn opts ->
            # exec's collector keys frames by the ref supplied to this seam.
            bridge = spawn(fn -> bridge(sender, opts[:owner], ref, opts[:ref]) end)
            send(test_pid, {:bridge, bridge})
            send(sender, {:start, bridge})
            {:ok, sender}
          end)
      end

      started = System.monotonic_time(:millisecond)

      result =
        adapter(unquote(provider)).exec(handle(unquote(provider)), "probe", [], timeout: timeout)

      elapsed = System.monotonic_time(:millisecond) - started
      assert {:ok, _, 0} = result
      assert elapsed > timeout * 2

      IO.puts(
        "EVIDENCE #{unquote(provider)} #{unquote(stream)}: timeout=#{timeout}ms elapsed=#{elapsed}ms result=exit_0"
      )

      receive do
        {:bridge, bridge} -> if Process.alive?(bridge), do: Process.exit(bridge, :kill)
      after
        0 -> :ok
      end
    end
  end

  test "Sprites startup is outside the exec timeout" do
    expect(Sprites, :spawn, fn _, "probe", [], _ ->
      Process.sleep(100)
      ref = make_ref()
      send(self(), {:exit, %{ref: ref}, 0})
      {:ok, %Sprites.Command{ref: ref}}
    end)

    started = System.monotonic_time(:millisecond)
    assert {:ok, "", 0} = SpriteAdapter.exec(handle(:sprites), "probe", [], timeout: 10)
    elapsed = System.monotonic_time(:millisecond) - started
    assert elapsed >= 100
    IO.puts("EVIDENCE sprites startup: timeout=10ms elapsed=#{elapsed}ms result=exit_0")
  end

  test "E2B exec explicitly resumes a provider-paused sandbox" do
    expect(E2B.Api, :find_by_name, fn "probe" ->
      {:ok, %{"sandboxID" => "offline", "state" => "paused"}}
    end)

    expect(E2B.Api, :connect, fn "offline" -> :ok end)

    expect(E2B.CommandServer, :start, fn opts ->
      send(opts[:owner], {:exit, %{ref: opts[:ref]}, 0})
      {:ok, self()}
    end)

    assert {:ok, "", 0} = E2B.exec(handle(:e2b), "probe", [], timeout: 10)
    IO.puts("EVIDENCE e2b: paused lookup -> connect -> exec")
  end

  test "Daytona exec explicitly starts a provider-stopped sandbox" do
    expect(Daytona.Api, :get_sandbox, fn "probe" -> {:ok, %{"state" => "stopped"}} end)
    expect(Daytona.Api, :start, fn "probe" -> :ok end)
    expect(Daytona.Api, :toolbox_url, fn "probe" -> {:ok, "https://unused.invalid"} end)

    expect(Daytona.Toolbox, :execute, fn "https://unused.invalid", "'probe'", opts ->
      assert opts[:timeout] == 30_000
      {:ok, "", 0}
    end)

    assert {:ok, "", 0} = Daytona.exec(handle(:daytona), "probe", [], timeout: 30_000)
    IO.puts("EVIDENCE daytona: stopped lookup -> start -> exec (remote timeout not exercised)")
  end

  test "only Sprites among the shipped providers exposes confirmed termination" do
    assert Sandbox.supports?(:sprites, :terminate_session)

    for provider <- [:e2b, :daytona, :runner] do
      refute Sandbox.supports?(provider, :terminate_session)
      assert {:error, :not_supported} = Sandbox.terminate_session(handle(provider), "probe")
    end

    IO.puts("EVIDENCE termination capability: sprites=yes e2b=no daytona=no runner=no")
  end

  defp adapter(:sprites), do: SpriteAdapter
  defp adapter(:e2b), do: E2B
  defp handle(provider), do: %Handle{provider: provider, name: "probe"}

  defp bridge(sender, owner, source_ref, target_ref) do
    monitor = Process.monitor(sender)
    bridge_loop(owner, source_ref, target_ref, monitor)
  end

  defp bridge_loop(owner, source_ref, target_ref, monitor) do
    receive do
      {stream, %{ref: ^source_ref}, data} when stream in [:stdout, :stderr, :exit] ->
        send(owner, {stream, %{ref: target_ref}, data})
        if stream != :exit, do: bridge_loop(owner, source_ref, target_ref, monitor)

      {:DOWN, ^monitor, :process, _, _} ->
        :ok
    after
      5_000 -> :ok
    end
  end
end

result = ExUnit.run()
System.halt(if result.failures == 0, do: 0, else: 1)
