defmodule Managoat.Runtimes.ACPConcurrencyTest do
  use ExUnit.Case, async: true

  alias Managoat.Runtimes.ACP

  # ADR 0023 step 4: how many turns one sandbox takes at once is a property
  # of the runtime, not of the machine.

  test "claude and codex run several turns at once on one sandbox" do
    assert ACP.concurrency("claude") == :unbounded
    assert ACP.concurrency("codex") == :unbounded
  end

  test "gemini takes one turn at a time" do
    assert ACP.concurrency("gemini") == 1
  end

  test "a runtime with no adapter has nothing to collide with" do
    assert ACP.concurrency("no-such-runtime") == :unbounded
  end

  test "every supported runtime has a capacity" do
    for runtime <- ACP.supported_runtimes() do
      assert ACP.concurrency(runtime) == :unbounded or
               (is_integer(ACP.concurrency(runtime)) and ACP.concurrency(runtime) > 0)
    end
  end
end
