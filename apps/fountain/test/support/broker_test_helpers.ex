defmodule Fountain.BrokerTestHelpers do
  @moduledoc """
  Let a test own the egress broker's processes.

  Every deployment brokers (ADR 0019, amendment of 2026-10-15), so the suite
  runs the application's own listener and request-log writer, as production
  does. A test that starts its own (to read its port, to own the writer's
  pid, or to see the listener down) calls `own_broker/0` first: the
  application's two children stop for the test and start again after it.
  Global state, so the test module that uses it is `async: false`.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  @children [Managoat.Broker, Fountain.Broker.Native.RequestLog]

  @doc "Stop the application's broker children for this test; restart them after."
  def own_broker do
    for id <- @children, do: :ok = Supervisor.terminate_child(Fountain.Supervisor, id)

    on_exit(fn ->
      for id <- Enum.reverse(@children) do
        case Supervisor.restart_child(Fountain.Supervisor, id) do
          {:ok, _} -> :ok
          {:error, :running} -> :ok
        end
      end
    end)

    :ok
  end
end
