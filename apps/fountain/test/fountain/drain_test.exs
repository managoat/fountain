defmodule Fountain.DrainTest do
  @moduledoc """
  A node that is shutting down is left out when Horde places a conversation
  or a machine owner (`Fountain.Drain`). The registry metadata it writes is
  cluster-wide, so these tests mark nodes that do not exist and clean up
  after themselves.
  """
  use ExUnit.Case, async: false

  alias Fountain.Drain
  alias Fountain.Drain.Distribution

  @registry Fountain.ConversationRegistry
  @spec_ %{id: :x, start: {Task, :start_link, [:x]}}

  setup do
    on_exit(fn ->
      for node <- [:a@test, :b@test, node()],
          do: Horde.Registry.delete_meta(@registry, {:draining, node})
    end)
  end

  defp member(node), do: %{name: {Fountain.ConversationSupervisor, node}, status: :alive}

  test "a node is not draining until it says so" do
    refute Drain.draining?(:a@test)
    :ok = Horde.Registry.put_meta(@registry, {:draining, :a@test}, true)
    assert Drain.draining?(:a@test)
  end

  test "stopping the marker marks this node draining" do
    refute Drain.draining?(node())
    Drain.terminate(:shutdown, nil)
    assert Drain.draining?(node())
  end

  test "a booting marker clears a mark its node name inherited" do
    :ok = Horde.Registry.put_meta(@registry, {:draining, node()}, true)
    assert {:ok, nil} = Drain.init([])
    refute Drain.draining?(node())
  end

  test "children are placed only on nodes that are not draining" do
    members = [member(:a@test), member(:b@test)]
    :ok = Horde.Registry.put_meta(@registry, {:draining, :a@test}, true)

    # Whatever the hash would pick, the draining node is never chosen.
    for i <- 1..50 do
      assert {:ok, %{name: {_, :b@test}}} =
               Distribution.choose_node(
                 %{@spec_ | id: i, start: {Task, :start_link, [i]}},
                 members
               )
    end
  end

  test "when every node is draining, a child is still placed" do
    members = [member(:a@test), member(:b@test)]

    for node <- [:a@test, :b@test],
        do: :ok = Horde.Registry.put_meta(@registry, {:draining, node}, true)

    assert {:ok, %{name: {_, node}}} = Distribution.choose_node(@spec_, members)
    assert node in [:a@test, :b@test]
  end

  test "with nothing draining it places exactly as the uniform strategy does" do
    members = [member(:a@test), member(:b@test)]

    for i <- 1..20 do
      spec = %{@spec_ | id: i, start: {Task, :start_link, [i]}}

      assert Distribution.choose_node(spec, members) ==
               Horde.UniformDistribution.choose_node(spec, members)
    end
  end
end
