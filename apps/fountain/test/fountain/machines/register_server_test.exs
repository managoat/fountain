defmodule Fountain.Machines.RegisterServerTest do
  @moduledoc """
  The wake-registration marker (ADR 0058 stage 6a, #2307 constraint 4).

  Horde's registry is an asynchronous CRDT, so "no live server" read on one
  node is not evidence that none was started on another, and the reaper decides
  on exactly that reading. `Conversations.register_server/2` is the durable
  half: `woken_at` on the sandbox row, committed under the per-sandbox advisory
  lock **before** Horde is asked for a child.

  What these pin is the ordering (the child sees the marker already written),
  the lock (a holder of the per-sandbox lock delays the registration, proven
  with PostgreSQL's own wait report rather than with timing), the two refusals
  the door makes — an enclosing transaction, and a machine whose owner holds a
  live lease, the latter decided *inside* the lock so a claim landing after the
  caller's own read still wins (round 1, locks review) — that every starter
  comes through the door, and that Horde's own answer is passed back unchanged:
  the two callers do not agree on what `{:already_started, _}` means and
  normalizing it here would break one of them (#717).

  `async: false`: the lock case runs unboxed, on real connections, because the
  SQL sandbox puts every process on one transaction and a lock taken there is
  one the test already holds.
  """
  use Fountain.DataCase, async: false

  alias Fountain.Conversations
  alias Fountain.Conversations.Sandbox
  alias Fountain.Machines.Lease

  # `Fountain.Conversations`' per-sandbox advisory namespace, which
  # `with_sandbox_lock/2` and so `register_server/2` take.
  @sandbox_lock_namespace 4316

  setup do
    user = insert_verified_user()
    %{user: user, sandbox: insert_sandbox(user_id: user.id, status: "ready")}
  end

  # A child that reports what the database said about its own machine at the
  # moment it started. Not a stand-in for a `ConversationServer` — it exists to
  # read one column from inside `start_child`, which is the only place the
  # ordering this module promises can be observed.
  defmodule Probe do
    @moduledoc false
    use GenServer

    def start_link(opts) do
      case Keyword.get(opts, :name) do
        nil -> GenServer.start_link(__MODULE__, opts)
        name -> GenServer.start_link(__MODULE__, opts, name: name)
      end
    end

    @impl GenServer
    def init(opts) do
      owner = Keyword.fetch!(opts, :owner)

      case Keyword.get(opts, :sandbox_id) do
        nil ->
          send(owner, {:started, self(), :no_sandbox})

        sandbox_id ->
          Ecto.Adapters.SQL.Sandbox.allow(Fountain.Repo, owner, self())

          send(
            owner,
            {:started, self(), Fountain.Repo.get!(Fountain.Conversations.Sandbox, sandbox_id)}
          )
      end

      {:ok, opts}
    end
  end

  defp probe_spec(opts) do
    %{
      id: {__MODULE__, System.unique_integer()},
      start: {Probe, :start_link, [Keyword.put(opts, :owner, self())]},
      restart: :temporary
    }
  end

  defp stop(pid) do
    Horde.DynamicSupervisor.terminate_child(Fountain.ConversationSupervisor, pid)
  end

  describe "the marker and the child" do
    test "the marker is committed before the child starts", ctx do
      refute Repo.reload!(ctx.sandbox).woken_at, "a fresh row is not woken"

      assert {:ok, pid} =
               Conversations.register_server(
                 ctx.sandbox.id,
                 probe_spec(sandbox_id: ctx.sandbox.id)
               )

      # Read from inside `start_child`: the ordering, not the outcome. A marker
      # written after the child would arrive here as `nil` and the child would
      # still be running, which is the whole registry-lag race.
      assert_receive {:started, ^pid, %Sandbox{woken_at: seen}}, 5_000
      assert seen, "the child started before its machine was marked woken"
      assert DateTime.compare(seen, Repo.reload!(ctx.sandbox).woken_at) == :eq

      stop(pid)
    end

    test "a second registration moves the marker forward", ctx do
      assert {:ok, first} =
               Conversations.register_server(
                 ctx.sandbox.id,
                 probe_spec(sandbox_id: ctx.sandbox.id)
               )

      assert_receive {:started, ^first, _}, 5_000
      before = Repo.reload!(ctx.sandbox).woken_at
      stop(first)

      assert {:ok, second} =
               Conversations.register_server(
                 ctx.sandbox.id,
                 probe_spec(sandbox_id: ctx.sandbox.id)
               )

      assert_receive {:started, ^second, _}, 5_000
      assert DateTime.compare(Repo.reload!(ctx.sandbox).woken_at, before) == :gt
      stop(second)
    end

    test "the marker is a control-plane write: no status, no lease, no revival guard", ctx do
      assert {:ok, pid} =
               Conversations.register_server(
                 ctx.sandbox.id,
                 probe_spec(sandbox_id: ctx.sandbox.id)
               )

      assert_receive {:started, ^pid, _}, 5_000
      stop(pid)

      row = Repo.reload!(ctx.sandbox)
      assert row.status == "ready"
      assert row.lease_epoch == 0
      refute row.lease_node
      refute Lease.live?(row)
      assert row.updated_at == ctx.sandbox.updated_at
    end

    test "a terminal row is marked too: the marker says nothing about the machine", ctx do
      # `woken_at` is not a status and carries no policy — the readers decide
      # what a row means, and every one of them looks at the status first. A
      # door that refused here would be a second, silent status rule.
      terminal = insert_sandbox(user_id: ctx.user.id, status: "terminated")

      assert {:ok, pid} =
               Conversations.register_server(terminal.id, probe_spec(sandbox_id: terminal.id))

      assert_receive {:started, ^pid, %Sandbox{woken_at: seen, status: "terminated"}}, 5_000
      assert seen
      stop(pid)
    end

    test "a nil sandbox_id starts the child and marks nothing", ctx do
      assert {:ok, pid} = Conversations.register_server(nil, probe_spec([]))
      assert_receive {:started, ^pid, :no_sandbox}, 5_000
      refute Repo.reload!(ctx.sandbox).woken_at
      stop(pid)
    end

    test "a vanished sandbox does not stop the child starting", ctx do
      id = Ecto.UUID.generate()

      assert {:ok, pid} = Conversations.register_server(id, probe_spec([]))
      assert_receive {:started, ^pid, :no_sandbox}, 5_000
      refute Repo.reload!(ctx.sandbox).woken_at
      stop(pid)
    end

    test "Horde's answer comes back verbatim, including {:already_started, _}", ctx do
      # The two callers read this tuple differently: the rehydrator as success
      # (another node already started the server it wanted), `Wake` as a race
      # it has to compensate for (its own fresh sandbox row must be retired and
      # the prompt handed to the winner, #717/#330). The door must not choose
      # for them.
      # A named child, because that is how a real duplicate arises: a
      # `ConversationServer` registers under its conversation id, and the
      # second start of one is refused by the name, not by the supervisor.
      spec =
        probe_spec(
          sandbox_id: ctx.sandbox.id,
          name: :"probe_#{System.unique_integer([:positive])}"
        )

      assert {:ok, pid} = Conversations.register_server(ctx.sandbox.id, spec)
      assert_receive {:started, ^pid, _}, 5_000

      # The second call still marks the row — it asked to register, and the
      # marker is about the intent, not about which caller won.
      assert {:error, {:already_started, ^pid}} =
               Conversations.register_server(ctx.sandbox.id, spec)

      assert Repo.reload!(ctx.sandbox).woken_at
      stop(pid)
    end
  end

  describe "the door's refusals" do
    test "an enclosing transaction is refused before the lock is taken", ctx do
      # `with_sandbox_lock/2` is a plain `Repo.transaction`, so nested it joins
      # the caller's through a savepoint and holds the advisory lock until the
      # *outer* commit — across `start_child`, breaking both of the door's
      # promises with nothing failing (#2307 constraint 3). The same guard
      # `Machines.Destroy.run/2` carries.
      assert {:ok, {:error, :transaction_open}} =
               Repo.transaction(fn ->
                 Conversations.register_server(
                   ctx.sandbox.id,
                   probe_spec(sandbox_id: ctx.sandbox.id)
                 )
               end)

      refute_received {:started, _, _}
      refute Repo.reload!(ctx.sandbox).woken_at
    end

    test "a machine whose owner holds a live lease is refused, and starts nothing", ctx do
      {:ok, 1} = Lease.claim(ctx.sandbox.id, "fountain@other", 30_000)

      assert {:error, :sandbox_unavailable} =
               Conversations.register_server(
                 ctx.sandbox.id,
                 probe_spec(sandbox_id: ctx.sandbox.id)
               )

      refute_received {:started, _, _}
      refute Repo.reload!(ctx.sandbox).woken_at
    end

    test "an expired lease is not a refusal", ctx do
      {:ok, 1} = Lease.claim(ctx.sandbox.id, "fountain@other", 30_000)

      ctx.sandbox
      |> Ecto.Changeset.change(
        lease_until: DateTime.add(DateTime.utc_now(), -1_000, :millisecond)
      )
      |> Repo.update!()

      assert {:ok, pid} =
               Conversations.register_server(
                 ctx.sandbox.id,
                 probe_spec(sandbox_id: ctx.sandbox.id)
               )

      assert_receive {:started, ^pid, _}, 5_000
      assert Repo.reload!(ctx.sandbox).woken_at
      stop(pid)
    end
  end

  describe "under the per-sandbox lock" do
    test "a holder of the sandbox lock delays the marker and the child with it" do
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        tenant = committed_tenant()
        owner = self()

        blocker =
          independent(fn ->
            Repo.transaction(fn ->
              Repo.query!("SELECT pg_advisory_xact_lock($1, $2)", [
                @sandbox_lock_namespace,
                :erlang.phash2(tenant.sandbox.id)
              ])

              send(owner, :locked)

              receive do
                :commit -> :ok
              after
                10_000 -> raise "advisory lock release timed out"
              end
            end)
          end)

        try do
          assert_receive {:backend, blocker_pid, _}, 5_000
          assert blocker_pid == blocker.pid
          assert_receive :locked, 5_000

          # The probe here touches no database: this case runs unboxed, and
          # what it observes is *when* the child starts, not what it can read.
          registering =
            independent(fn ->
              Conversations.register_server(
                tenant.sandbox.id,
                %{
                  id: {__MODULE__, :locked_probe},
                  start: {Probe, :start_link, [[owner: owner]]},
                  restart: :temporary
                }
              )
            end)

          try do
            assert_receive {:backend, registering_pid, registering_backend}, 5_000
            assert registering_pid == registering.pid

            # Proof it serialized rather than merely finished second:
            # PostgreSQL reports the marker's backend waiting on another one.
            await_blocked(registering_backend, System.monotonic_time(:millisecond) + 5_000)

            # And the load-bearing half: no child exists yet. If the marker
            # were written after `start_child`, or outside the lock, the server
            # would already be running while another writer holds the machine.
            refute_received {:started, _, _}
            assert Task.yield(registering, 0) == nil

            send(blocker.pid, :commit)
            assert {:ok, :ok} = Task.await(blocker, 15_000)
            assert {:ok, pid} = Task.await(registering, 15_000)
            assert_receive {:started, ^pid, :no_sandbox}, 5_000
            stop(pid)

            assert Repo.get!(Sandbox, tenant.sandbox.id).woken_at
          after
            Task.shutdown(registering, :brutal_kill)
          end
        after
          Task.shutdown(blocker, :brutal_kill)
          discard(tenant)
        end
      end)
    end

    test "a lease taken while the door waits on the lock is still seen" do
      # The window the in-lock re-check closes (round 1, locks review).
      # `Wake.maybe_reuse_sandbox/1` reads the row with no lock at all, so a
      # `Lease.claim/4` landing between that read and this call would otherwise
      # get a `ConversationServer` started on a machine somebody is destroying.
      # Here the lease is taken *after* the door has already blocked on the
      # advisory lock, which is as late as a claim can possibly be: a verdict
      # made before the lock would miss it, and this one does not.
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        tenant = committed_tenant()
        owner = self()

        blocker =
          independent(fn ->
            Repo.transaction(fn ->
              Repo.query!("SELECT pg_advisory_xact_lock($1, $2)", [
                @sandbox_lock_namespace,
                :erlang.phash2(tenant.sandbox.id)
              ])

              send(owner, :locked)

              receive do
                :claim -> :ok
              after
                10_000 -> raise "claim barrier timed out"
              end

              # Straight onto the row rather than through `Lease.claim/4`,
              # which refuses to run inside this open transaction — the same
              # columns it would write.
              Repo.update_all(
                from(s in Sandbox, where: s.id == ^tenant.sandbox.id),
                set: [
                  lease_epoch: 1,
                  lease_node: "fountain@other",
                  lease_until: DateTime.add(DateTime.utc_now(), 30_000, :millisecond)
                ]
              )
            end)
          end)

        try do
          assert_receive {:backend, _, _}, 5_000
          assert_receive :locked, 5_000

          registering =
            independent(fn ->
              Conversations.register_server(tenant.sandbox.id, %{
                id: {__MODULE__, :late_claim_probe},
                start: {Probe, :start_link, [[owner: owner]]},
                restart: :temporary
              })
            end)

          try do
            assert_receive {:backend, _, registering_backend}, 5_000
            await_blocked(registering_backend, System.monotonic_time(:millisecond) + 5_000)

            send(blocker.pid, :claim)
            assert {:ok, {1, nil}} = Task.await(blocker, 15_000)

            assert {:error, :sandbox_unavailable} = Task.await(registering, 15_000)
            refute_received {:started, _, _}
            refute Repo.get!(Sandbox, tenant.sandbox.id).woken_at
          after
            Task.shutdown(registering, :brutal_kill)
          end
        after
          Task.shutdown(blocker, :brutal_kill)
          discard(tenant)
        end
      end)
    end
  end

  describe "the door is the only way in" do
    # Every file that may name the supervisor at all: the one that starts it,
    # the one that terminates a child of it, and the door. `launch.ex`,
    # `wake.ex` and `rehydrator.ex` named it before stage 6a and do not now.
    @starters [
      "apps/fountain/lib/fountain/application.ex",
      "apps/fountain/lib/fountain/conversations.ex",
      "apps/fountain/lib/fountain/conversations/provision_watchdog.ex"
    ]

    test "nothing outside Conversations.register_server/2 starts a conversation server" do
      root = Path.expand("../../../../..", __DIR__)
      files = source_files(root)
      relative = MapSet.new(files, &Path.relative_to(&1, root))

      # The scan has to be shown to reach the files that legitimately name the
      # supervisor, or a broken climb would pass by finding nothing — the
      # failure mode `machine_bounds_test.exs` was written with in round 2 of
      # stage 5a.
      for expected <- @starters do
        assert expected in relative,
               "the scan missed #{expected} (#{MapSet.size(relative)} files seen); it cannot " <>
                 "pin who starts a conversation server if it does not read them"
      end

      naming =
        files
        |> Enum.filter(
          &String.contains?(strip_docs_and_comments(File.read!(&1)), "ConversationSupervisor")
        )
        |> Enum.map(&Path.relative_to(&1, root))
        |> Enum.sort()

      assert naming == Enum.sort(@starters),
             "`Fountain.ConversationSupervisor` is named outside the door by:\n  " <>
               Enum.join(naming, "\n  ") <>
               "\n\nOne door starts a conversation server (ADR 0058 stage 6a, #2307 " <>
               "constraint 4), because the marker that makes the registration visible to " <>
               "the reaper is written there. `application.ex` starts the supervisor, " <>
               "`provision_watchdog.ex` terminates a child; a new *starter* is a decision."

      starting =
        files
        |> Enum.filter(fn file ->
          content = strip_docs_and_comments(File.read!(file))

          Regex.match?(
            ~r/Horde\.DynamicSupervisor\.start_child\(\s*Fountain\.ConversationSupervisor/,
            content
          )
        end)
        |> Enum.map(&Path.relative_to(&1, root))

      assert starting == ["apps/fountain/lib/fountain/conversations.ex"]
    end

    defp source_files(root) do
      top_level =
        ["apps/fountain/lib", "ee/lib"]
        |> Enum.map(&Path.join(root, &1))
        |> Enum.filter(&File.dir?/1)

      buzz = root |> Path.join("apps/fountain_*/lib") |> Path.wildcard()

      (top_level ++ buzz)
      |> Enum.flat_map(&Path.wildcard(Path.join(&1, "**/*.ex")))
      |> Enum.sort()
    end

    defp strip_docs_and_comments(content) do
      content
      |> then(&Regex.replace(~r/@(?:module)?doc\s+"""[\s\S]*?"""/, &1, ""))
      |> String.split("\n")
      |> Enum.map_join("\n", fn line ->
        if String.trim_leading(line) |> String.starts_with?("#"), do: "", else: line
      end)
    end
  end

  # ── unboxed helpers (the shape `lease_test.exs` established) ──────────────

  defp committed_tenant do
    user =
      Repo.insert!(%Fountain.Accounts.User{
        email: "register-server-#{Ecto.UUID.generate()}@example.test",
        credit_balance_cents: 0
      })

    sandbox =
      %Sandbox{}
      |> Sandbox.changeset(%{
        machine_name: "register-#{Ecto.UUID.generate()}",
        status: "ready",
        user_id: user.id
      })
      |> Repo.insert!()

    %{user: user, sandbox: sandbox}
  end

  defp discard(%{user: user, sandbox: sandbox}) do
    Repo.delete_all(from e in Fountain.Audit.Event, where: e.user_id == ^user.id)
    Repo.delete!(sandbox)
    Repo.delete!(user)
  end

  defp independent(fun) do
    owner = self()

    Task.async(fn ->
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
        send(owner, {:backend, self(), backend})
        fun.()
      end)
    end)
  end

  defp await_blocked(backend, deadline) do
    %{rows: [[blocked]]} = Repo.query!("SELECT cardinality(pg_blocking_pids($1)) > 0", [backend])

    unless blocked do
      assert System.monotonic_time(:millisecond) < deadline,
             "no PostgreSQL advisory-lock wait observed"

      Process.sleep(5)
      await_blocked(backend, deadline)
    end
  end

  describe "a stale operation stamp" do
    test "is cleared on the way past when no owner holds the machine", ctx do
      # ADR 0058 stage 6b, from the protocol review. Nothing else clears a
      # `transition` off a row whose lease has expired: `Machine.busy?/2`
      # ignores it by 6a's design, and the reaper's sweeps only ever look at
      # machines with no server. So an abandoned park on a machine that is then
      # woken kept its stamp for ever, and the next owner to claim that machine
      # read it as its own interrupted operation.
      Repo.update_all(from(s in Sandbox, where: s.id == ^ctx.sandbox.id),
        set: [
          lease_epoch: 1,
          lease_node: "dead-pod@node",
          lease_until: DateTime.add(DateTime.utc_now(), -60, :second),
          transition: "parking",
          transition_reason: "idle"
        ]
      )

      assert {:ok, pid} =
               Conversations.register_server(
                 ctx.sandbox.id,
                 probe_spec(sandbox_id: ctx.sandbox.id)
               )

      on_exit(fn -> stop(pid) end)

      row = Repo.reload!(ctx.sandbox)
      assert is_nil(row.transition), "the stamp outlived the operation that wrote it"
      assert is_nil(row.transition_reason)
      assert row.woken_at
    end

    test "is left alone while an owner still holds the lease", ctx do
      # The other half: a live lease is an operation in flight, and this door
      # refuses rather than tidying up after it.
      Repo.update_all(from(s in Sandbox, where: s.id == ^ctx.sandbox.id),
        set: [
          lease_epoch: 1,
          lease_node: "live@node",
          lease_until: DateTime.add(DateTime.utc_now(), 60, :second),
          transition: "parking",
          transition_reason: "idle"
        ]
      )

      assert {:error, :sandbox_unavailable} =
               Conversations.register_server(
                 ctx.sandbox.id,
                 probe_spec(sandbox_id: ctx.sandbox.id)
               )

      assert Repo.reload!(ctx.sandbox).transition == "parking"
    end
  end
end
