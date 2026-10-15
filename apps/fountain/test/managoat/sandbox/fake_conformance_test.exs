defmodule Managoat.Sandbox.FakeConformanceTest do
  # The Fake adapter passing the shared conformance suite is what proves the
  # suite is contract-shaped rather than Sprites-shaped — and the Fake's
  # frames come from real processes, so the owner-message contract is
  # exercised for real rather than hand-crafted.
  use Managoat.Sandbox.ConformanceCase,
    adapter: Managoat.Sandbox.Fake,
    fixtures: %{
      exec_ok: {"emit", ["out:hello"], "hello"},
      exec_fail: {"emit", ["out:oops", "exit:3"], 3},
      spawn_ok: {"emit", ["out:hello", "exit:0"]},
      spawn_drop: {"emit", ["out:partial", "drop"]},
      spawn_stay: {"emit", ["out:ready", "stay"]}
    }

  setup do
    Managoat.Sandbox.Fake.reset()
    :ok
  end

  # Fake-specific extras that the shared suite cannot assert generically.

  test "fresh creation refuses legacy names without changing their files" do
    alias Managoat.Sandbox.Fake
    {:ok, legacy} = Fake.create("legacy", [])
    :ok = Fake.write_file(legacy, "/proof", "original", [])
    assert {:error, :already_exists} = Fake.create_new("legacy", [])
    assert Fake.file("legacy", "/proof") == "original"
    refute Managoat.Sandbox.Retry.transient?(:already_exists)
  end

  test "fresh identity matches control metadata and only one concurrent create wins" do
    alias Managoat.Sandbox.Fake

    results =
      for _ <- 1..2 do
        Task.async(fn -> Fake.create_new("raced", []) end)
      end
      |> Enum.map(&Task.await/1)

    assert [{:ok, handle}] = Enum.filter(results, &match?({:ok, _}, &1))
    assert [{:error, :already_exists}] = Enum.filter(results, &match?({:error, _}, &1))
    assert {:ok, %{raw: %{"name" => "raced", "id" => id}}} = Fake.get(handle)
    assert id == handle.instance_id
  end

  test "the applied policy is recorded verbatim — allow: [] reaches the backend" do
    {:ok, handle} = Managoat.Sandbox.Fake.create("policy-check", [])

    :ok =
      Managoat.Sandbox.Fake.apply_network_policy(handle, %Managoat.Sandbox.NetworkPolicy{
        allow: []
      })

    assert %Managoat.Sandbox.NetworkPolicy{allow: []} =
             Managoat.Sandbox.Fake.policy("policy-check")
  end

  test "exec answers a dropped transport the same way the stream frame does" do
    {:ok, handle} = Managoat.Sandbox.Fake.create("drop-check", [])

    # Not `{:ok, "partial", 0}`: bytes collected before the transport went
    # away are not a result, and the exit code was never measured.
    assert {:error, {:unavailable, :closed_before_exit}} =
             Managoat.Sandbox.Fake.exec(handle, "emit", ["out:partial", "drop"], [])
  end

  test "attach replays the error verdict of a session that was dropped" do
    {:ok, handle} = Managoat.Sandbox.Fake.create("drop-attach", [])

    assert {:ok, command} =
             Managoat.Sandbox.Fake.spawn(handle, "emit", ["out:partial", "drop"],
               owner: self(),
               stdin: false
             )

    ref = command.ref
    assert_receive {:error, %{ref: ^ref}, :closed_before_exit}, 1_000

    # A late attacher gets the same verdict, not the exit code nobody read.
    [session] = elem(Managoat.Sandbox.Fake.list_sessions(handle), 1)
    assert {:ok, replay} = Managoat.Sandbox.Fake.attach(handle, session.id, owner: self())
    replay_ref = replay.ref

    assert_receive {:stdout, %{ref: ^replay_ref}, "partial"}, 1_000
    assert_receive {:error, %{ref: ^replay_ref}, :closed_before_exit}, 1_000
    refute_receive {:exit, %{ref: ^replay_ref}, _}, 50
  end

  test "write_file stores contents the sandbox can read back" do
    {:ok, handle} = Managoat.Sandbox.Fake.create("fs-check", [])
    :ok = Managoat.Sandbox.Fake.write_file(handle, "/home/sprite/.env", "A=1\n", mode: 0o600)
    assert Managoat.Sandbox.Fake.file("fs-check", "/home/sprite/.env") == "A=1\n"
  end

  test "missing sandboxes and sessions are definitively not found" do
    missing = Managoat.Sandbox.Fake.build_handle("missing")
    assert {:error, :not_found} = Managoat.Sandbox.Fake.public_url(missing)
    assert {:error, :not_found} = Managoat.Sandbox.Fake.suspend(missing)

    {:ok, handle} = Managoat.Sandbox.Fake.create("session-check", [])
    assert {:error, :not_found} = Managoat.Sandbox.Fake.attach(handle, "missing", [])
  end

  test "exec drops stderr unless the caller asks to merge it" do
    {:ok, handle} = Managoat.Sandbox.Fake.create("exec-stderr", [])

    assert {:ok, "out", 0} =
             Managoat.Sandbox.Fake.exec(handle, "emit", ["out:out", "err:noise"], [])
  end

  test "a script without a terminal instruction auto-exits and replays stderr to attachers" do
    {:ok, handle} = Managoat.Sandbox.Fake.create("auto-exit", [])
    assert {:ok, command} = Managoat.Sandbox.Fake.spawn(handle, "emit", ["err:warning"], [])

    ref = command.ref
    assert_receive {:stderr, %{ref: ^ref}, "warning"}, 1_000
    assert_receive {:exit, %{ref: ^ref}, 0}, 1_000

    [session] = elem(Managoat.Sandbox.Fake.list_sessions(handle), 1)
    assert {:ok, replay} = Managoat.Sandbox.Fake.attach(handle, session.id, owner: self())
    replay_ref = replay.ref
    assert_receive {:stderr, %{ref: ^replay_ref}, "warning"}, 1_000
    assert_receive {:exit, %{ref: ^replay_ref}, 0}, 1_000
  end
end
