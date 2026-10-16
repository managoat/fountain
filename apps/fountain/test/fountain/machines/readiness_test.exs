defmodule Fountain.Machines.ReadinessTest do
  use ExUnit.Case, async: true
  use Mimic

  alias Fountain.Machines.Readiness
  alias Managoat.Sandbox.Handle

  test "transient handshake failure retries before accepting a zero exit" do
    expect(Managoat.Sandbox, :exec, fn _, "true", [], _ -> {:error, {:unavailable, :timeout}} end)
    expect(Managoat.Sandbox, :exec, fn _, "true", [], _ -> {:ok, "", 0} end)
    assert :ok = Readiness.wait(%Handle{provider: :sprites, name: "probe"}, readiness_retry_ms: 1)
  end

  test "nonzero exit and permanent errors do not prove readiness or retry" do
    for result <- [{:ok, "", 7}, {:error, :not_found}, {:error, {:denied, :token}}] do
      expect(Managoat.Sandbox, :exec, fn _, _, _, _ -> result end)
      assert {:error, _} = Readiness.wait(%Handle{provider: :sprites, name: "probe"}, [])
    end
  end

  test "adapter raises and exits exhaust the retry budget" do
    for failure <- [fn -> raise "offline" end, fn -> exit(:offline) end] do
      stub(Managoat.Sandbox, :exec, fn _, _, _, _ -> failure.() end)

      assert {:error, :readiness_timeout} =
               Readiness.wait(%Handle{provider: :sprites, name: "probe"},
                 readiness_timeout_ms: 20,
                 readiness_retry_ms: 1
               )
    end
  end

  test "startup that exhausts the budget cannot retry or publish a late success" do
    for result <- [{:ok, "", 0}, {:error, {:unavailable, :timeout}}] do
      expect(Managoat.Sandbox, :exec, fn _, _, _, opts ->
        Process.sleep(opts[:timeout] + 5)
        result
      end)

      assert {:error, :readiness_timeout} =
               Readiness.wait(%Handle{provider: :sprites, name: "probe"},
                 readiness_timeout_ms: 10
               )
    end
  end

  test "providers with explicit resume do not get a second exec" do
    reject(&Managoat.Sandbox.exec/4)
    assert :ok = Readiness.wait(%Handle{provider: :e2b, name: "probe"}, [])
  end
end
