defmodule Fountain.Conversations.LifecycleActionsTest do
  @moduledoc """
  The reclaim actions that moved out of `ConversationServer` in #1376: the
  sandbox clock, what each bound does to the machine, the park and the
  destroy, and what the co-tenants on it are told. Driven with the
  `Managoat.Sandbox` facade stubbed and no server — a co-tenant is a plain
  process registered under its conversation id, which is all `whereis/1`
  looks for.

  The policy half of `Lifecycle` is pinned by `lifecycle_test.exs`; this file
  only asserts the consequences.
  """
  use Fountain.DataCase, async: true
  use Mimic

  alias Fountain.Conversations
  alias Fountain.Conversations.Lifecycle
  alias Managoat.Sandbox.Handle

  defp handle(name \\ "s"), do: %Handle{provider: :sprites, name: name}

  setup do
    user = insert_verified_user()
    sandbox = insert_sandbox(user_id: user.id, status: "ready")
    conv = insert_conversation(user_id: user.id, sandbox_id: sandbox.id, status: "running")
    {:ok, user: user, sandbox: sandbox, conv: conv}
  end

  # The stage events of one stage as `{state, meta}` pairs, in order.
  defp stages(conv_id, stage) do
    Fountain.Repo.all(
      from(e in Conversations.LogEvent,
        where: e.conversation_id == ^conv_id and e.kind == "stage" and e.stage == ^stage,
        order_by: e.id
      )
    )
    |> Enum.map(&{&1.state, Jason.decode!(&1.data)})
  end

  # Collect one telemetry event into this process's mailbox.
  defp listen(event) do
    ref = make_ref()
    test = self()
    id = "lifecycle-actions-#{inspect(ref)}"

    :telemetry.attach(
      id,
      event,
      fn _e, measurements, meta, _ -> send(test, {ref, measurements, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(id) end)
    ref
  end

  describe "provider/1 and clock_start/1" do
    test "the provider tag comes off the live handle, and defaults to sprites" do
      assert Lifecycle.provider(%Handle{provider: :daytona, name: "d"}) == :daytona
      assert Lifecycle.provider(nil) == :sprites
    end

    test "the clock starts at the last wake, else at creation" do
      created = ~U[2026-01-01 00:00:00Z]
      woke = ~U[2026-01-02 00:00:00Z]

      assert Lifecycle.clock_start(%{last_resumed_at: nil, inserted_at: created}) == created
      assert Lifecycle.clock_start(%{last_resumed_at: woke, inserted_at: created}) == woke
    end
  end

  describe "schedule_check/0" do
    test "arms :lifecycle_check in the calling process" do
      ref = Lifecycle.schedule_check()
      assert is_reference(ref)
      # The default is a minute; the point is that a timer exists and carries
      # the message the server's handle_info matches on.
      assert Process.read_timer(ref) > 0
      assert Process.cancel_timer(ref) > 0
    end
  end

  describe "home?/1" do
    test "a persistent sandbox is a home; an ephemeral one and nil are not", ctx do
      {:ok, home} = Conversations.update_sandbox(ctx.sandbox, %{mode: "persistent"})

      assert Lifecycle.home?(home.id)
      refute Lifecycle.home?(insert_sandbox(user_id: ctx.user.id).id)
      refute Lifecycle.home?(nil)
    end
  end

  describe "busy_elsewhere?/2" do
    test "false when this conversation is alone on the machine", ctx do
      refute Lifecycle.busy_elsewhere?(ctx.sandbox.id, ctx.conv.id)
    end

    test "true when a co-tenant is mid-turn", ctx do
      other =
        insert_conversation(user_id: ctx.user.id, sandbox_id: ctx.sandbox.id, status: "running")

      insert_turn(other, status: "running", started_at: DateTime.utc_now())

      assert Lifecycle.busy_elsewhere?(ctx.sandbox.id, ctx.conv.id)
    end

    test "a terminated co-tenant does not hold the machine", ctx do
      other =
        insert_conversation(user_id: ctx.user.id, sandbox_id: ctx.sandbox.id, status: "running")

      insert_turn(other, status: "running", started_at: DateTime.utc_now())
      {:ok, _} = Conversations.update_conversation(other, %{status: "terminated"})

      refute Lifecycle.busy_elsewhere?(ctx.sandbox.id, ctx.conv.id)
    end
  end

  describe "suspend/1" do
    test "no handle is nothing to park" do
      assert Lifecycle.suspend(nil) == :ok
    end

    test "a handle goes to the provider" do
      expect(Managoat.Sandbox, :suspend, fn %Handle{name: "s"} -> :ok end)
      assert Lifecycle.suspend(handle()) == :ok
    end
  end

  describe "idle_machine_action/2" do
    test "parks when the provider can and the call succeeds", ctx do
      expect(Managoat.Sandbox, :suspend, fn _ -> :ok end)
      assert Lifecycle.idle_machine_action(ctx.conv.id, handle()) == :park
    end

    test "destroys where the provider cannot park", ctx do
      stub(Managoat.Sandbox, :supports?, fn :sprites, :suspend -> false end)
      # No suspend call at all: there is nothing to park onto.
      reject(&Managoat.Sandbox.suspend/1)

      assert Lifecycle.idle_machine_action(ctx.conv.id, handle()) == :destroy
    end

    test "destroys when the park call fails — an unparked sandbox keeps billing", ctx do
      expect(Managoat.Sandbox, :suspend, fn _ -> {:error, {:unavailable, :timeout}} end)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert Lifecycle.idle_machine_action(ctx.conv.id, handle()) == :destroy
        end)

      assert log =~ "suspend call failed for conv #{ctx.conv.id}"
      assert log =~ "an unparked sandbox keeps billing"
    end
  end

  describe "max_lifetime_action/2" do
    test "an ephemeral sandbox is destroyed at the ceiling", ctx do
      reject(&Managoat.Sandbox.suspend/1)
      assert Lifecycle.max_lifetime_action(ctx.sandbox.id, handle()) == :destroy
    end

    test "a home is parked at the ceiling instead (ADR 0023)", ctx do
      {:ok, home} = Conversations.update_sandbox(ctx.sandbox, %{mode: "persistent"})
      expect(Managoat.Sandbox, :suspend, fn _ -> :ok end)

      assert Lifecycle.max_lifetime_action(home.id, handle()) == :park
    end

    test "a home whose park call fails is destroyed as an ephemeral one would be", ctx do
      {:ok, home} = Conversations.update_sandbox(ctx.sandbox, %{mode: "persistent"})
      expect(Managoat.Sandbox, :suspend, fn _ -> {:error, :nope} end)

      assert Lifecycle.max_lifetime_action(home.id, handle()) == :destroy
    end
  end

  describe "park/4" do
    test "parks the row, idles the conversation, and says so on the stream", ctx do
      ref = listen([:fountain, :sandbox, :suspended])

      assert Lifecycle.park(ctx.conv.id, ctx.sandbox.id, handle(), :idle) == :ok

      assert Repo.reload(ctx.sandbox).status == "suspended"
      assert Repo.reload(ctx.conv).status == "idle"

      assert [{"done", meta}] = stages(ctx.conv.id, "sandbox")
      assert meta["event"] == "suspended"
      assert meta["reason"] == "idle"
      assert meta["message"] == Lifecycle.explain(:idle, :suspend)

      assert_received {^ref, %{count: 1}, %{provider: :sprites}}
    end

    test "the ceiling's park says which bound it was", ctx do
      assert Lifecycle.park(ctx.conv.id, ctx.sandbox.id, handle(), :max_lifetime) == :ok

      assert [{"done", meta}] = stages(ctx.conv.id, "sandbox")
      assert meta["reason"] == "max_lifetime"
      assert meta["message"] == Lifecycle.explain(:max_lifetime, :suspend)
    end

    test "a row already terminated or failed is left alone", ctx do
      {:ok, sandbox} = Conversations.update_sandbox(ctx.sandbox, %{status: "failed"})

      assert Lifecycle.park(ctx.conv.id, sandbox.id, handle(), :idle) == :ok
      assert Repo.reload(sandbox).status == "failed"
      assert Repo.reload(ctx.conv).status == "running"
      assert stages(ctx.conv.id, "sandbox") == []
    end

    for terminal <- ["terminated", "failed"] do
      @tag park_retirement: true
      test "retirement to #{terminal} during checkpoint does not park the replacement", ctx do
        {:ok, home} = Conversations.update_sandbox(ctx.sandbox, %{mode: "persistent"})
        test = self()

        stub(Managoat.Sandbox, :supports?, fn :sprites, :checkpoint -> true end)

        stub(Managoat.Sandbox, :create_checkpoint, fn _handle, _opts ->
          send(test, {:checkpoint_paused, self()})
          receive do: (:resume_checkpoint -> {:ok, "checkpoint"})
        end)

        pid =
          spawn(fn ->
            receive do
              :park ->
                result =
                  try do
                    Lifecycle.park(ctx.conv.id, home.id, handle(), :idle)
                  rescue
                    error -> {:raised, error}
                  end

                send(test, {:park_result, result})
            end
          end)

        on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
        Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), pid)
        Mimic.allow(Managoat.Sandbox, self(), pid)
        send(pid, :park)
        assert_receive {:checkpoint_paused, ^pid}, 5_000

        {:ok, retired} = Conversations.update_sandbox(home, %{status: unquote(terminal)})
        replacement = insert_sandbox(user_id: ctx.user.id, status: "ready")
        {:ok, _} = Conversations.update_conversation(ctx.conv, %{sandbox_id: replacement.id})
        send(pid, :resume_checkpoint)

        assert_receive {:park_result, :ok}, 5_000
        assert Repo.reload!(home).status == unquote(terminal)
        assert Repo.reload!(home).terminated_at == retired.terminated_at
        assert Repo.reload!(ctx.conv).sandbox_id == replacement.id
        assert Repo.reload!(ctx.conv).status == "running"
        assert Repo.reload!(replacement).status == "ready"
        assert stages(ctx.conv.id, "sandbox") == []
      end
    end

    test "unrelated park-write errors still raise", ctx do
      rejection =
        {:error,
         Ecto.Changeset.change(ctx.sandbox) |> Ecto.Changeset.add_error(:status, "other failure")}

      stub(Conversations, :update_sandbox, fn _row, _attrs -> rejection end)

      assert_raise MatchError, fn ->
        Lifecycle.park(ctx.conv.id, ctx.sandbox.id, handle(), :idle)
      end

      assert Repo.reload!(ctx.sandbox).status == "ready"
      assert Repo.reload!(ctx.conv).status == "running"
      assert stages(ctx.conv.id, "sandbox") == []
    end

    test "a conversation that is not running keeps its status", ctx do
      {:ok, conv} = Conversations.update_conversation(ctx.conv, %{status: "terminated"})

      assert Lifecycle.park(conv.id, ctx.sandbox.id, handle(), :idle) == :ok
      assert Repo.reload(conv).status == "terminated"
    end
  end

  describe "destroy/5" do
    test "tears the sandbox down, terminates the row and idles the conversation", ctx do
      ref = listen([:fountain, :sandbox, :reclaimed])
      test = self()

      expect(Managoat.Sandbox, :destroy, fn %Handle{name: "s"} ->
        send(test, :destroyed) && :ok
      end)

      assert Lifecycle.destroy(ctx.conv.id, ctx.sandbox.id, handle(), :max_lifetime) ==
               :ok

      assert_received :destroyed

      reloaded = Repo.reload(ctx.sandbox)
      assert reloaded.status == "terminated"
      assert reloaded.terminated_at
      assert Repo.reload(ctx.conv).status == "idle"

      assert [{"done", meta}] = stages(ctx.conv.id, "sandbox")
      assert meta["event"] == "reclaimed"
      assert meta["reason"] == "max_lifetime"
      assert meta["message"] == Lifecycle.reclaim_message(:max_lifetime)

      assert_received {^ref, %{count: 1}, %{reason: :max_lifetime, provider: :sprites}}
    end

    test "no handle is nothing to tear down, and the rows still move", ctx do
      reject(&Managoat.Sandbox.destroy/1)

      assert Lifecycle.destroy(ctx.conv.id, ctx.sandbox.id, nil, :idle) == :ok

      assert Repo.reload(ctx.sandbox).status == "terminated"
      assert [{"done", meta}] = stages(ctx.conv.id, "sandbox")
      assert meta["message"] == Lifecycle.reclaim_message(:idle)
      # The provider tag falls back with the handle.
      assert meta["reason"] == "idle"
    end
  end

  describe "stop_cotenants/5" do
    test "casts :machine_gone to every other live server on the machine", ctx do
      other =
        insert_conversation(user_id: ctx.user.id, sandbox_id: ctx.sandbox.id, status: "running")

      test = self()

      # A plain process standing in for the co-tenant's server: `whereis/1`
      # only asks the registry, and a cast is a message.
      {:ok, stand_in} =
        Task.start_link(fn ->
          {:ok, _} = Horde.Registry.register(Fountain.ConversationRegistry, other.id, nil)
          send(test, :registered)

          receive do
            msg -> send(test, {:cotenant, msg})
          end
        end)

      assert_receive :registered

      assert Lifecycle.stop_cotenants(ctx.sandbox.id, ctx.conv.id, "suspended", "idle", "why") ==
               :ok

      assert_receive {:cotenant, {:"$gen_cast", {:machine_gone, "suspended", "idle", "why"}}}
      assert is_pid(stand_in)
    end

    test "a co-tenant with no live server is not an error", ctx do
      insert_conversation(user_id: ctx.user.id, sandbox_id: ctx.sandbox.id, status: "running")

      assert Lifecycle.stop_cotenants(ctx.sandbox.id, ctx.conv.id, "reclaimed", "idle", "why") ==
               :ok
    end
  end

  describe "reclaim_message/1" do
    test "names the bound that destroyed the sandbox" do
      assert Lifecycle.reclaim_message(:max_lifetime) == Lifecycle.explain(:max_lifetime)
      assert Lifecycle.reclaim_message(:idle) == Lifecycle.explain(:idle, :destroy)
    end
  end
end
