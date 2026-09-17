defmodule Fountain.Machines.SupervisionTest do
  @moduledoc """
  How much crashing the machine owners are allowed between them (ADR 0058
  stage 7a).

  Horde's `DynamicSupervisor` takes `Supervisor`'s default — three restarts in
  five seconds — and that budget is **shared by every child on the node**. One
  machine whose owner crashes deterministically exhausts it in under a second,
  and exceeding it terminates the supervisor and with it every *other* machine's
  owner: with the gate on, every destroy, park and resume on the node failing at
  once because of one bad row. That is the opposite of what a per-machine owner
  is for, and #2348's review said to size it when the owner started doing work.

  Read off `Fountain.Application.children/0` rather than off the running
  supervisor, because that is where the decision is written and Horde exposes no
  way to ask a started one.
  """

  use ExUnit.Case, async: true

  defp options(name) do
    Fountain.Application.children()
    |> Enum.find_value(fn
      {Horde.DynamicSupervisor, opts} -> if opts[:name] == name, do: opts
      _ -> nil
    end)
  end

  test "the machine supervisor's restart budget is sized, not Horde's default" do
    opts = options(Fountain.MachineSupervisor)

    assert opts, "Fountain.MachineSupervisor is not a Horde.DynamicSupervisor child any more"

    assert opts[:max_restarts] == 100,
           "the owner now holds a lease and calls a provider; three restarts across every " <>
             "machine on the node is one bad row away from taking them all down"

    assert opts[:max_seconds] == 10
  end

  test "it is sized the same way as the conversation supervisor beside it" do
    # Same shape of burst on both: a provider outage failing many operations at
    # the same moment must not read as a loop. Asserted as equality so the two
    # cannot drift silently — if one moves, somebody has to say why the other
    # did not.
    machines = options(Fountain.MachineSupervisor)
    conversations = options(Fountain.ConversationSupervisor)

    assert machines[:max_restarts] == conversations[:max_restarts]
    assert machines[:max_seconds] == conversations[:max_seconds]
  end

  test "the owner pair still starts before the conversation pair" do
    # Reverse termination stops it *after* the conversation supervisor, so a
    # server shutting down can still ask its machine who is here. Pinned because
    # the ordering is a comment in `application.ex` and comments do not fail.
    names =
      for {Horde.DynamicSupervisor, opts} <- Fountain.Application.children(),
          do: opts[:name]

    assert Enum.find_index(names, &(&1 == Fountain.MachineSupervisor)) <
             Enum.find_index(names, &(&1 == Fountain.ConversationSupervisor))
  end
end
