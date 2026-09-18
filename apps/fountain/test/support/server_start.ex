defmodule Fountain.ServerStart do
  @moduledoc """
  Stub the start of a conversation server, and only that.

  Tests that do not want a real `ConversationServer` stub
  `Horde.DynamicSupervisor.start_child/2`. Every machine owner
  (`Fountain.Machines.Machine`, ADR 0058) is started through the same function,
  into `Fountain.MachineSupervisor`, and since stage 9b deleted
  `MACHINE_OWNER_ENABLED` every destroy, park, resume, admission, attach and
  detach runs in one. A blanket stub therefore handed those verbs a dummy pid
  that exited at once, and each answered `sandbox_unavailable`.

  These helpers stub the conversation supervisor and pass a start into
  `Fountain.MachineSupervisor` to the real function, so a test keeps its fake
  server and gets a real owner. Imported by `Fountain.DataCase` and
  `FountainWeb.ConnCase`.
  """

  @doc """
  `Mimic.stub/3` on `Horde.DynamicSupervisor.start_child/2`, for every
  supervisor but the machine owners'.
  """
  def stub_server_start(fun) when is_function(fun, 2) do
    Mimic.stub(Horde.DynamicSupervisor, :start_child, fn
      Fountain.MachineSupervisor, child -> start_owner(child)
      supervisor, child -> fun.(supervisor, child)
    end)
  end

  @doc """
  `Mimic.expect/4` on the same function, counting only the starts that are not
  a machine owner's: `fun` must run exactly `times` times by the end of the
  test. Mimic's own `expect` cannot tell the two supervisors apart, so the count
  is kept here and checked `on_exit`.
  """
  def expect_server_start(times \\ 1, fun) when is_function(fun, 2) do
    calls = :counters.new(1, [])

    stub_server_start(fn supervisor, child ->
      :counters.add(calls, 1, 1)
      fun.(supervisor, child)
    end)

    ExUnit.Callbacks.on_exit(fn ->
      count = :counters.get(calls, 1)

      unless count == times do
        raise ExUnit.AssertionError,
          message:
            "expected Horde.DynamicSupervisor.start_child/2 to start a conversation " <>
              "server #{times} time(s), it was called #{count} time(s)"
      end
    end)
  end

  @doc """
  `Mimic.reject/3`'s intent for a conversation server: fail the test if one is
  started. A machine owner still starts.
  """
  def reject_server_start do
    stub_server_start(fn supervisor, child ->
      raise ExUnit.AssertionError,
        message:
          "a conversation server was started (#{inspect(supervisor)}, " <>
            "#{inspect(child, limit: 3)}) where the test rejects one"
    end)
  end

  @doc """
  Run the pool in manual mode for the rest of an `async: false` test, as a
  `setup` callback.

  For a test that drives a race across real connections, every side of it
  inside `Ecto.Adapters.SQL.Sandbox.unboxed_run/2`. The machine owner serves
  each call as its caller (`Fountain.Machines.Machine`'s `$callers`), and in
  manual mode the pool follows that chain to the caller's own connection —
  where the verb ran when it ran inline, before stage 9b deleted
  `MACHINE_OWNER_ENABLED`. In shared mode the pool looks at the asking process
  alone and hands the owner the shared sandbox connection instead: a
  transaction that never commits, whose row locks then outlast the race and
  block its cleanup.

  Switching to manual checks the shared connection in, so nothing the test
  does may sit outside `unboxed_run`.
  """
  def manual_pool(_context \\ %{}) do
    :ok = Ecto.Adapters.SQL.Sandbox.mode(Fountain.Repo, :manual)
  end

  defp start_owner(child),
    do:
      Mimic.call_original(Horde.DynamicSupervisor, :start_child, [
        Fountain.MachineSupervisor,
        child
      ])
end
