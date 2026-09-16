defmodule Fountain.Conversations.RehydratorTest do
  # The sweep queries all resumable rows; do not overlap independent-connection
  # admission race fixtures in the async suites.
  use Fountain.DataCase, async: false
  use Mimic

  alias Fountain.Conversations.{ConversationServer, ExecutionAllowance, Rehydrator}

  setup do
    owner = self()

    stub(Horde.DynamicSupervisor, :start_child, fn _, {ConversationServer, args} ->
      send(owner, {:worker_start, args})
      {:ok, owner}
    end)

    :ok
  end

  for status <- ["idle", "running"] do
    test "boot refuses every saved control for a #{status} conversation without mutation" do
      conv = resumable(unquote(status))
      before = Repo.reload!(conv)
      sandbox = Repo.reload!(conv.sandbox)
      turn = if unquote(status == "running"), do: insert_turn(conv, status: "running")

      for {control, limit} <- [
            wall_time_seconds: 30,
            max_model_turns: 2,
            max_estimated_cost_usd: 0.5
          ] do
        allowance = save(conv, %{control => limit})

        for _ <- 1..2 do
          assert sweep() == 0
          assert Repo.reload!(conv) == before
          assert Repo.reload!(conv.sandbox) == sandbox
          assert Repo.reload!(allowance) == allowance
          if turn, do: assert(Repo.reload!(turn) == turn)
          refute_received {:worker_start, _}
        end

        Repo.delete!(allowance)
      end
    end
  end

  for malformed <- [:map, :null] do
    test "boot skips corrupt #{malformed} policy without exposing its contents" do
      conv = resumable("idle")
      allowance = save(conv, %{})

      if unquote(malformed == :map) do
        allowance
        |> Ecto.Changeset.change(limits: %{"private-field" => "private-value"})
        |> Repo.update!()
      else
        Repo.query!(
          "UPDATE execution_allowances SET limits = 'null'::jsonb WHERE conversation_id = $1",
          [Ecto.UUID.dump!(conv.id)]
        )
      end

      log = ExUnit.CaptureLog.capture_log(fn -> assert sweep() == 0 end)
      assert log =~ "execution_limits_invalid"
      refute log =~ "private-field"
      refute log =~ "private-value"
      refute_received {:worker_start, _}
      assert Repo.reload!(conv).status == "idle"
    end
  end

  test "one refused tenant does not block absent or empty allowances, including an existing server" do
    limited = resumable("running")
    save(limited, %{max_model_turns: 2})
    ordinary = resumable("idle")
    existing = resumable("running")
    save(existing, %{})
    owner = self()

    stub(Horde.DynamicSupervisor, :start_child, fn _, {ConversationServer, args} ->
      send(owner, {:worker_start, args})

      if args[:conversation_id] == existing.id,
        do: {:error, {:already_started, owner}},
        else: {:ok, owner}
    end)

    assert sweep() == 2
    assert_received {:worker_start, first}
    assert_received {:worker_start, second}

    assert Enum.sort([first[:conversation_id], second[:conversation_id]]) ==
             Enum.sort([ordinary.id, existing.id])

    assert first[:initial_prompt] == nil
    assert second[:initial_prompt] == nil
    refute_received {:worker_start, _}
    assert Repo.reload!(limited).status == "running"
  end

  # ADR 0058 stage 6a. The sweep reads `ready` rows, and a `ready` row can be
  # one an owner holds between its intent and its finalize: a destroy, a reset,
  # and from stage 6b a park. Starting a server there gives the machine a
  # second writer during the one window the owner exists to prevent. Skipping
  # is right rather than failing: the next boot, or the conversation's own next
  # prompt, comes back after the lease has gone.
  test "boot skips a machine whose owner holds a live lease" do
    conv = resumable("idle")
    conv.sandbox |> Ecto.Changeset.change(held()) |> Repo.update!()

    log = ExUnit.CaptureLog.capture_log(fn -> assert sweep() == 0 end)
    assert log =~ "machine_busy"
    refute_received {:worker_start, _}
    assert Repo.reload!(conv).status == "idle"
  end

  for transition <- ["parking", "destroying", "resuming"] do
    test "boot starts a server on a #{transition} row whose lease died" do
      # Round 1: a stamped transition with no live lease is an owner that died,
      # not one working. Skipping it left the conversation with no server until
      # something else gave up on the row — the hourly reaper, for a teardown.
      conv = resumable("idle")

      conv.sandbox
      |> Ecto.Changeset.change(
        transition: unquote(transition),
        lease_epoch: 1,
        lease_node: nil,
        lease_until: nil
      )
      |> Repo.update!()

      assert sweep() == 1
      assert_received {:worker_start, args}
      assert args[:conversation_id] == conv.id
    end
  end

  test "boot starts a server on an abandoned destroy, as on main" do
    # The one door where the round-0 definition was a live regression today
    # (round 1, behaviour review). `Destroy` fences before it stamps, so a
    # destroy whose owner died carries `reset_requested_at` *and*
    # `teardown_requested_at` beside its `destroying` — and `Wake` and the
    # attach door both answer the fence before they ever ask `busy?`. This
    # sweep does not: its query selects `ready` rows with no reset filter, so
    # it reached `busy?` and skipped a row it had always started a server on.
    conv = resumable("idle")
    now = DateTime.utc_now()

    conv.sandbox
    |> Ecto.Changeset.change(
      reset_requested_at: now,
      teardown_requested_at: now,
      transition: "destroying",
      lease_epoch: 1,
      lease_node: nil,
      lease_until: nil
    )
    |> Repo.update!()

    assert sweep() == 1
    assert_received {:worker_start, args}
    assert args[:conversation_id] == conv.id
  end

  test "a lease claimed after the sweep's own check is refused at the door, and says so" do
    # `check_machine_free/1` reads the row with no lock; the door re-reads it
    # under the per-sandbox advisory lock and can refuse where our check
    # passed. That refusal comes back into the `with`'s *body*, which the
    # `else` below never sees, so before round 2 it left the sweep with no log
    # line at all (round 1, locks review).
    #
    # `RuntimeDispatch.for_agent/1` is the hook: it runs after
    # `check_machine_free/1` and before `register_server/2`, so a lease claimed
    # there is exactly a claim landing in that gap.
    conv = resumable("idle")

    stub(Fountain.RuntimeDispatch, :for_agent, fn c ->
      Repo.get!(Fountain.Conversations.Sandbox, conv.sandbox_id)
      |> Ecto.Changeset.change(held())
      |> Repo.update!()

      Mimic.call_original(Fountain.RuntimeDispatch, :for_agent, [c])
    end)

    log = ExUnit.CaptureLog.capture_log(fn -> assert sweep() == 0 end)

    assert log =~ "skipping conv #{conv.id} (machine_busy)"
    refute_received {:worker_start, _}
  end

  test "boot starts a server once the lease has expired" do
    conv = resumable("idle")

    conv.sandbox
    |> Ecto.Changeset.change(held(-1_000))
    |> Repo.update!()

    assert sweep() == 1
    assert_received {:worker_start, args}
    assert args[:conversation_id] == conv.id
  end

  test "boot still leaves non-ready sandboxes to lazy recovery" do
    for status <- ["pending", "starting", "suspended", "terminated", "failed"] do
      conv = resumable("idle")
      conv.sandbox |> Ecto.Changeset.change(status: status) |> Repo.update!()
    end

    assert sweep() == 0
    refute_received {:worker_start, _}
  end

  # A lease somebody holds (ADR 0058) — the whole of what makes a machine busy
  # to a reader. Written straight onto the row: no changeset casts these
  # columns, which is itself part of the design.
  defp held(ttl_ms \\ 30_000) do
    [
      lease_epoch: 1,
      lease_node: "fountain@other",
      lease_until: DateTime.add(DateTime.utc_now(), ttl_ms, :millisecond)
    ]
  end

  defp resumable(status) do
    agent = insert_agent()
    sandbox = insert_sandbox(user_id: agent.user_id, status: "ready")
    insert_conversation(agent: agent, sandbox: sandbox, status: status)
  end

  defp save(conv, limits),
    do: conv.id |> ExecutionAllowance.new_changeset(limits) |> Repo.insert!()

  defp sweep,
    do: Rehydrator.run(cluster_wait_ms: 0, stabilize_ms: 0, poll_ms: 1)

  describe "leader election" do
    test "a lone node (no peers) is always the leader" do
      assert Rehydrator.leader?(:"fountain_server@10.0.0.1", [])

      assert Rehydrator.leader_node(:"fountain_server@10.0.0.1", []) ==
               :"fountain_server@10.0.0.1"
    end

    test "the lowest node name wins, regardless of discovery order" do
      self_node = :"fountain_server@10.0.0.1"
      peers = [:"fountain_server@10.0.0.2", :"fountain_server@10.0.0.3"]

      assert Rehydrator.leader?(self_node, peers)
      assert Rehydrator.leader_node(self_node, peers) == self_node
    end

    test "a non-lowest node defers to the leader" do
      self_node = :"fountain_server@10.0.0.3"
      peers = [:"fountain_server@10.0.0.1", :"fountain_server@10.0.0.2"]

      refute Rehydrator.leader?(self_node, peers)
      assert Rehydrator.leader_node(self_node, peers) == :"fountain_server@10.0.0.1"
    end

    test "election is consistent across the cluster: exactly one leader" do
      a = :"fountain_server@10.0.0.1"
      b = :"fountain_server@10.0.0.2"
      c = :"fountain_server@10.0.0.3"
      cluster = [a, b, c]

      # Each node evaluates against itself + its peers; all must agree.
      leaders =
        for node <- cluster, Rehydrator.leader?(node, cluster -- [node]), do: node

      assert leaders == [a]
    end
  end
end
