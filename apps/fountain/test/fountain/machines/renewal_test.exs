defmodule Fountain.Machines.RenewalTest do
  @moduledoc """
  Keeping a lease alive across a provider call (ADR 0058 stage 7a).

  Two properties, and they are the two the 6b review asked for. A provider call
  slower than the lease TTL must not leave the lease expired behind it, because
  an expired lease is an invitation to take the operation over while it is still
  running. And a renewal that finds the lease *already* taken over must stop the
  operation before it writes, rather than letting the finalize discover it a
  round trip later.

  The TTLs here are milliseconds, so "slower than the TTL" is a `Process.sleep`
  rather than a minute. Each protocol's own suite drives the same thing through
  a real `Destroy`, `Park` and `Resume`; this file is the mechanism on its own.

  `async: false`: the renewer runs in a process of its own and shares this
  test's database connection through `$callers`.
  """

  use Fountain.DataCase, async: false
  use Mimic

  import ExUnit.CaptureLog

  alias Fountain.Machines.Lease
  alias Fountain.Machines.Renewal

  setup do
    user = insert_verified_user()
    sandbox = insert_sandbox(user_id: user.id, status: "ready")
    {:ok, epoch} = Lease.claim(sandbox.id, "fountain@test", 300)

    {:ok, user: user, sandbox: sandbox, epoch: epoch}
  end

  defp deadline(ctx), do: Repo.reload!(ctx.sandbox).lease_until

  describe "a provider call slower than the TTL" do
    test "still holds the lease at the end of it", ctx do
      before = deadline(ctx)

      assert {:ok, :done} =
               Renewal.around(ctx.sandbox.id, ctx.epoch, 300, fn ->
                 Process.sleep(500)
                 :done
               end)

      after_ = deadline(ctx)

      assert DateTime.compare(after_, before) == :gt,
             "the lease was never renewed; it expired underneath the provider call"

      assert Lease.live?(Repo.reload!(ctx.sandbox)),
             "the lease had expired by the time the call returned, so any reaper " <>
               "passing in the meantime was entitled to take the operation over"
    end

    test "and no takeover is possible while it runs", ctx do
      test = self()

      task =
        Task.async(fn ->
          Renewal.around(ctx.sandbox.id, ctx.epoch, 300, fn ->
            send(test, :in_call)
            Process.sleep(600)
            :done
          end)
        end)

      assert_receive :in_call, 2_000

      # Well past the original 300ms deadline, and the machine is still not
      # claimable: this is the window the 6b review found open.
      Process.sleep(450)

      assert {:error, {:held, "fountain@test", _}} =
               Lease.claim(ctx.sandbox.id, "reaper@node", 60_000)

      assert {:ok, :done} = Task.await(task, 5_000)
    end
  end

  describe "a lease that was taken over" do
    test "stops the operation at :superseded rather than at the finalize", ctx do
      assert capture_log(fn ->
               assert {:error, :superseded, :finished_anyway} =
                        Renewal.around(ctx.sandbox.id, ctx.epoch, 200, fn ->
                          # Somebody takes the machine over while the provider
                          # call is in flight: the release is what `Lease.renew/4`
                          # answers `:lost` to, and it is the shape a takeover
                          # leaves behind.
                          :ok = Lease.release(ctx.sandbox.id, ctx.epoch)
                          Process.sleep(400)
                          :finished_anyway
                        end)
             end) =~ "taken over while the provider call was in flight"
    end

    test "hands the result back, because the caller may still have to unwind it", ctx do
      # **Changed in stage 7b** (round 1, behaviour review). This used to assert
      # that `{:error, :superseded}` carried no result at all, on the grounds
      # that a protocol must have no way to finalize from a call it no longer
      # owns. The first half of that is still true and is pinned where it
      # belongs — `Destroy`, `Park` and `Resume` each drop the result at their
      # own call site, and their suites pin their answers — but the second half
      # did not follow from it.
      #
      # `fun` has already returned by the time the verdict is collected, so a
      # superseded operation is one that *did the work*. `Machines.Provision`'s
      # callback mints a broker session and rotates a conversation's callback
      # key inside it; throwing the result away left both live on exactly the
      # contention path the lease exists for.
      result =
        capture_log(fn ->
          send(
            self(),
            {:answer,
             Renewal.around(ctx.sandbox.id, ctx.epoch, 200, fn ->
               :ok = Lease.release(ctx.sandbox.id, ctx.epoch)
               Process.sleep(400)
               {:ok, :the_machine_is_gone}
             end)}
          )
        end)

      assert result =~ "the row is another owner's from here"
      assert_received {:answer, {:error, :superseded, {:ok, :the_machine_is_gone}}}
    end
  end

  describe "what is not a takeover" do
    test "a call that finishes inside the TTL is never renewed and still holds", ctx do
      before = deadline(ctx)

      assert {:ok, :quick} =
               Renewal.around(ctx.sandbox.id, ctx.epoch, 60_000, fn -> :quick end)

      # A 60s TTL renews at 20s, so nothing happened; the point is that nothing
      # *had* to, and the lease is exactly as the claim left it.
      assert DateTime.compare(deadline(ctx), before) == :eq
    end

    test "a renewer that dies reports the lease held, and the CAS decides", ctx do
      # It has no evidence of a takeover, and inventing one would abandon work
      # the compare-and-set would have completed. This module can only ever turn
      # a failure found at the finalize into one found before it.
      renewer = Renewal.start(ctx.sandbox.id, ctx.epoch, 60_000)
      ref = Process.monitor(renewer)
      Process.exit(renewer, :kill)
      assert_receive {:DOWN, ^ref, :process, ^renewer, :killed}, 2_000

      assert capture_log(fn -> assert :held = Renewal.stop(renewer) end) =~
               "exited before it was stopped"
    end
  end

  # The renewer runs in a process of its own, so a stub set on this one does not
  # reach it: global mode is what lets a test drive `Lease.renew/4`'s answer.
  describe "a renewal the database refused" do
    setup :set_mimic_global

    test "is retried rather than read as a takeover", ctx do
      # `Lease.renew/4` answers `:lost` for one reason — this caller is not the
      # holder — and a connection fault says nothing about who is. Reading one
      # as a takeover would abandon an operation nobody had taken.
      # Arity three, not four: `Renewal` calls `Lease.renew/3` and lets the
      # clock default, and a stub on the four-arity head would never fire —
      # silently, with the real renewal succeeding underneath it.
      expect(Lease, :renew, fn _id, _epoch, _ttl -> {:error, {:database, :connection_error}} end)
      stub(Lease, :renew, fn _id, _epoch, _ttl -> :ok end)

      assert capture_log(fn ->
               assert {:ok, :done} =
                        Renewal.around(ctx.sandbox.id, ctx.epoch, 150, fn ->
                          Process.sleep(400)
                          :done
                        end)
             end) =~ "could not renew the lease"
    end
  end

  describe "an operating process that dies without telling anybody" do
    # Round 1, protocol review, and it is why the monitor exists.
    # `around/4`'s `try/catch` covers a raise, a throw and a trappable exit; it
    # covers nothing that kills the caller outright — Horde redistributing an
    # owner that does not trap exits, an Oban job killed at its timeout, a
    # `:kill`. Before the monitor, the renewer went on renewing a lease for work
    # nobody was doing, and nothing could ever take that machine: `Lease` cannot
    # evict a live holder and no sweep looks at a lease that keeps moving.
    test "the renewer stops, and the lease lapses on its own TTL", ctx do
      test = self()

      caller =
        spawn(fn ->
          renewer = Renewal.start(ctx.sandbox.id, ctx.epoch, 150)
          send(test, {:renewing, renewer})
          Process.sleep(:infinity)
        end)

      assert_receive {:renewing, renewer}, 2_000
      ref = Process.monitor(renewer)

      # Renewing, and demonstrably so: the deadline has moved past the claim's.
      Process.sleep(250)
      assert Lease.live?(Repo.reload!(ctx.sandbox))

      Process.exit(caller, :kill)

      assert_receive {:DOWN, ^ref, :process, ^renewer, _},
                     2_000,
                     "the renewer outlived the process it was renewing for"

      # And within one TTL of the last renewal the machine is claimable again,
      # which is the state it would have been in had the renewer never existed.
      Process.sleep(200)
      refute Lease.live?(Repo.reload!(ctx.sandbox))
      assert {:ok, _epoch} = Lease.claim(ctx.sandbox.id, "next@node", 60_000)
    end
  end

  describe "an operating process that is alive and stuck" do
    test "renewals stop at the total deadline rather than holding the machine for ever", ctx do
      # The monitor covers a caller that dies. This covers one that is alive and
      # wedged — a provider call with no timeout of its own — where renewing
      # forever holds the machine just as hard. Ten TTLs; at 20 ms that is
      # 200 ms, and the lease is claimable one TTL after the last renewal.
      renewer = Renewal.start(ctx.sandbox.id, ctx.epoch, 20)

      Process.sleep(400)

      refute Lease.live?(Repo.reload!(ctx.sandbox)),
             "the renewer is still holding the machine past its total deadline"

      # It is still there to answer, because the caller may still ask.
      assert Process.alive?(renewer)
      assert :held = Renewal.stop(renewer)
    end
  end

  describe "the renewer is not the operating process's problem" do
    test "it is unlinked, so a renewal that blows up does not take the caller down", ctx do
      # A link here would let a database fault kill a `ConversationServer`, an
      # Oban worker or a `Machines.Machine` in the middle of a provider call.
      parent = self()
      renewer = Renewal.start(ctx.sandbox.id, ctx.epoch, 60_000)

      {:links, links} = Process.info(parent, :links)
      refute renewer in links

      Process.exit(renewer, :kill)
      Process.sleep(20)
      assert Process.alive?(parent)
    end

    test "it sends the caller nothing it would have to handle", ctx do
      # A GenServer's `handle_info/2` has clauses for the messages it expects
      # and a `FunctionClauseError` for the rest, so an unsolicited renewal
      # message would crash the owner. The verdict is pulled at `stop/1`.
      renewer = Renewal.start(ctx.sandbox.id, ctx.epoch, 50)
      Process.sleep(200)
      refute_received _anything
      assert :held = Renewal.stop(renewer)
    end
  end

  describe "the lease it renews" do
    test "a renewal does not move updated_at", ctx do
      # A heartbeat every few seconds would make the column mean nothing to
      # anyone reading the table. `Lease.cas_update/4` says so; this proves the
      # renew path agrees.
      before = Repo.reload!(ctx.sandbox).updated_at

      assert {:ok, :done} =
               Renewal.around(ctx.sandbox.id, ctx.epoch, 200, fn ->
                 Process.sleep(450)
                 :done
               end)

      assert Repo.reload!(ctx.sandbox).updated_at == before
    end

    test "it renews this epoch and no other", ctx do
      # A renewal that matched on the id alone would re-arm a lease its taker
      # now holds.
      :ok = Lease.release(ctx.sandbox.id, ctx.epoch)
      {:ok, taker} = Lease.claim(ctx.sandbox.id, "taker@node", 60_000)
      refute taker == ctx.epoch

      held_until = deadline(ctx)

      capture_log(fn ->
        assert {:error, :superseded, :done} =
                 Renewal.around(ctx.sandbox.id, ctx.epoch, 100, fn ->
                   Process.sleep(250)
                   :done
                 end)
      end)

      assert Repo.reload!(ctx.sandbox).lease_until == held_until
      assert Repo.reload!(ctx.sandbox).lease_node == "taker@node"
    end
  end
end
