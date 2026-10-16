defmodule Managoat.Sandbox.ExecDeadlineTest do
  use ExUnit.Case, async: true

  alias Managoat.Sandbox.ExecDeadline

  test "finite deadlines keep the original timeout and use monotonic milliseconds" do
    before = System.monotonic_time(:millisecond)
    # Long enough that a loaded test VM cannot pass it between the lines.
    assert {60_000, expires_at} = deadline = ExecDeadline.new(60_000)
    assert expires_at >= before + 60_000
    assert expires_at <= System.monotonic_time(:millisecond) + 60_000
    assert ExecDeadline.remaining(deadline) in 1..60_000
    assert ExecDeadline.check(deadline) == :ok
    assert ExecDeadline.error(deadline) == {:error, {:unavailable, {:exec_timeout, 60_000}}}
  end

  test "zero and expired deadlines refuse work while infinity stays unbounded" do
    assert ExecDeadline.remaining(ExecDeadline.new(0)) == 0

    assert ExecDeadline.check({10, System.monotonic_time(:millisecond) - 1}) ==
             {:error, {:unavailable, {:exec_timeout, 10}}}

    deadline = ExecDeadline.new(:infinity)
    assert ExecDeadline.remaining(deadline) == :infinity
    assert ExecDeadline.check(deadline) == :ok
  end
end

defmodule Managoat.Sandbox.ExecCollectionDeadlineTest do
  use ExUnit.Case, async: true
  use Mimic

  alias Managoat.Sandbox.E2B
  alias Managoat.Sandbox.E2B.Api
  alias Managoat.Sandbox.E2B.CommandServer
  alias Managoat.Sandbox.ExecDeadline
  alias Managoat.Sandbox.Sprites, as: SpritesAdapter

  for adapter <- [SpritesAdapter, E2B] do
    @adapter adapter

    for {frame, merge_stderr} <- [{:stdout, false}, {:stderr, false}, {:stderr, true}] do
      @frame frame
      @merge_stderr merge_stderr
      test "#{inspect(adapter)} #{@frame} output (merge=#{@merge_stderr}) cannot renew timeout" do
        # Startup must not consume the collection budget under scheduler load.
        # Once started, advance the same deadline after each received frame;
        # queued output and success must not win against the expired budget.
        deadline = {40, 0}
        expect(ExecDeadline, :new, fn 40 -> deadline end)
        {:ok, frames} = Agent.start_link(fn -> :starting end)

        stub(ExecDeadline, :remaining, fn ^deadline ->
          Agent.get_and_update(frames, fn
            :starting -> {40, :starting}
            3 -> {0, 3}
            n -> {40 - n * 10, n + 1}
          end)
        end)

        stub_start(@adapter, fn owner, ref ->
          send(owner, {:output_ref, ref})
          for _ <- 1..10, do: send(owner, {@frame, %{ref: ref}, "queued"})
          send(owner, {:exit, %{ref: ref}, 0})
          Agent.update(frames, fn :starting -> 0 end)
          spawn(fn -> Process.sleep(:infinity) end)
        end)

        assert {:error, {:unavailable, {:exec_timeout, 40}}} =
                 @adapter.exec(@adapter.build_handle("deadline-test"), "probe", [],
                   timeout: 40,
                   stderr_to_stdout: @merge_stderr
                 )

        assert Agent.get(frames, & &1) == 3
        assert_receive {:output_ref, ref}
        for _ <- 1..7, do: assert_receive({@frame, %{ref: ^ref}, "queued"})
        assert_receive {:exit, %{ref: ^ref}, 0}
        assert_receive {:collector, pid, monitor}
        assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}
      end
    end

    test "#{inspect(adapter)} does not accept queued success after startup exhausts the deadline" do
      stub_start(@adapter, fn owner, ref ->
        Process.sleep(20)
        send(owner, {:stdout, %{ref: ref}, "too late"})
        send(owner, {:exit, %{ref: ref}, 0})
        spawn(fn -> Process.sleep(:infinity) end)
      end)

      assert {:error, {:unavailable, {:exec_timeout, 1}}} =
               @adapter.exec(@adapter.build_handle("deadline-test"), "probe", [], timeout: 1)
    end

    test "#{inspect(adapter)} rechecks the deadline after receiving terminal success" do
      # The terminal frame can become runnable before the deadline and only be
      # handled after it. Neither startup nor a successful receive grants time.
      {:ok, checks} = Agent.start_link(fn -> 0 end)
      initial_checks = if @adapter == E2B, do: 2, else: 1

      stub(ExecDeadline, :check, fn deadline ->
        n = Agent.get_and_update(checks, &{&1, &1 + 1})
        if n < initial_checks, do: :ok, else: ExecDeadline.error(deadline)
      end)

      stub_start(@adapter, fn owner, ref ->
        send(owner, {:exit, %{ref: ref}, 0})
        spawn(fn -> Process.sleep(:infinity) end)
      end)

      assert {:error, {:unavailable, {:exec_timeout, 1_000}}} =
               @adapter.exec(@adapter.build_handle("deadline-test"), "probe", [], timeout: 1_000)
    end

    test "#{inspect(adapter)} zero timeout does not dispatch" do
      stub(Sprites, :spawn, fn _, _, _, _ -> flunk("must not dispatch") end)
      stub(Api, :find_by_name, fn _ -> flunk("must not begin lookup") end)
      stub(CommandServer, :start, fn _ -> flunk("must not dispatch") end)

      assert {:error, {:unavailable, {:exec_timeout, 0}}} =
               @adapter.exec(@adapter.build_handle("deadline-test"), "probe", [], timeout: 0)
    end

    test "#{inspect(adapter)} accepts timely finite success and preserves infinity" do
      stub_start(@adapter, fn owner, ref ->
        send(owner, {:stdout, %{ref: ref}, "out"})
        send(owner, {:stderr, %{ref: ref}, "err"})
        send(owner, {:exit, %{ref: ref}, 3})
        spawn(fn -> :ok end)
      end)

      for timeout <- [1_000, :infinity] do
        assert {:ok, "outerr", 3} =
                 @adapter.exec(@adapter.build_handle("deadline-test"), "probe", [],
                   timeout: timeout,
                   stderr_to_stdout: true
                 )
      end
    end
  end

  test "E2B does not dispatch when name lookup exhausts the execution budget" do
    stub(Api, :find_by_name, fn "deadline-test" ->
      Process.sleep(20)
      {:ok, %{"sandboxID" => "sbx1", "state" => "running"}}
    end)

    stub(Api, :get_sandbox, fn "sbx1" -> {:ok, %{}} end)
    stub(CommandServer, :start, fn _ -> flunk("must not dispatch") end)

    assert {:error, {:unavailable, {:exec_timeout, 1}}} =
             E2B.exec(E2B.build_handle("deadline-test"), "probe", [], timeout: 1)
  end

  defp stub_start(SpritesAdapter, start) do
    stub(Managoat.Sandbox.Sprites.Client, :get!, fn -> %Sprites.Client{token: "test-token"} end)

    stub(Sprites, :spawn, fn _sprite, _command, _args, opts ->
      ref = make_ref()
      pid = start.(opts[:owner], ref)
      track_collector(pid)
      {:ok, %Sprites.Command{ref: ref, pid: pid}}
    end)
  end

  defp stub_start(E2B, start) do
    stub(Api, :find_by_name, fn "deadline-test" ->
      {:ok, %{"sandboxID" => "sbx1", "state" => "running"}}
    end)

    stub(Api, :get_sandbox, fn "sbx1" -> {:ok, %{}} end)

    stub(CommandServer, :start, fn opts ->
      pid = start.(opts[:owner], opts[:ref])
      track_collector(pid)
      {:ok, pid}
    end)
  end

  defp track_collector(pid) do
    send(self(), {:collector, pid, Process.monitor(pid)})
    on_exit(fn -> Process.exit(pid, :kill) end)
  end
end
