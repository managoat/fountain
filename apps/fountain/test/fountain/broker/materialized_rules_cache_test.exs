defmodule Fountain.Broker.MaterializedRulesCacheTest do
  use ExUnit.Case, async: true

  alias Fountain.Broker.Native.MaterializedRules

  test "concurrent misses materialize once and cache hits never execute a loader" do
    parent = self()
    key = make_ref()

    load = fn ->
      send(parent, :decrypted)
      {:ok, ["test-value"]}
    end

    tasks = for _ <- 1..32, do: Task.async(fn -> MaterializedRules.fetch(key, load) end)
    assert Enum.all?(Task.await_many(tasks), &(&1 == {:ok, ["test-value"]}))
    assert_receive :decrypted
    refute_receive :decrypted
    assert {:ok, ["test-value"]} = MaterializedRules.fetch(key, fn -> raise "must not load" end)
  end

  test "failed materializations are not cached and exceptions cannot crash the cache" do
    key = make_ref()
    assert :error = MaterializedRules.fetch(key, fn -> raise "private failure" end)
    assert :error = MaterializedRules.fetch(key, fn -> :error end)
    assert {:ok, []} = MaterializedRules.fetch(key, fn -> {:ok, []} end)
  end

  test "large values are served but not retained" do
    parent = self()
    key = make_ref()

    load = fn ->
      send(parent, :load)
      {:ok, String.duplicate("x", 65_537)}
    end

    assert {:ok, _} = MaterializedRules.fetch(key, load)
    assert {:ok, _} = MaterializedRules.fetch(key, load)
    assert_receive :load
    assert_receive :load
  end
end
