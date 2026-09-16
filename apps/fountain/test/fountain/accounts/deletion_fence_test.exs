defmodule Fountain.Accounts.DeletionFenceTest do
  use Fountain.DataCase, async: true
  use Mimic

  alias Fountain.Accounts.{Deletion, User}
  alias Fountain.{Audit, Conversations, Principals}
  import Ecto.Query, only: [where: 3]
  alias Fountain.Conversations.ConversationServer
  alias Fountain.Conversations.Lifecycle
  alias Fountain.Conversations.Termination
  alias Fountain.Machines.Destroy

  setup do
    user = insert_verified_user()
    sandbox = insert_sandbox(user_id: user.id, status: "ready")
    conv = insert_conversation(user_id: user.id, sandbox: sandbox, status: "idle")
    stub(ConversationServer, :whereis, fn _ -> nil end)
    %{user: user, sandbox: sandbox, conv: conv}
  end

  for capacity <- [1, :unbounded] do
    test "account deletion fences #{inspect(capacity)} admission before provider deletion", ctx do
      expect(Managoat.Sandbox.Sprites, :destroy, fn _ ->
        refute Repo.in_transaction?()
        assert Repo.reload!(ctx.sandbox).reset_requested_at
        assert Fountain.Quotas.active_sandbox_count(ctx.user.id) == 1
        assert {:error, :sandbox_unavailable} = admit(ctx, unquote(capacity))
        assert [event] = events(ctx.user.id)
        assert event.actor == "ui"
        assert event.request_ip == "192.0.2.1"
        assert event.metadata["reason"] == "account_deleted"
        :ok
      end)

      assert {:ok, %{sprites_destroyed: 1}} =
               Deletion.delete_user(ctx.user, actor: "ui", request_ip: "192.0.2.1")

      refute Repo.get(User, ctx.user.id)
      assert Repo.reload!(ctx.sandbox).status == "terminated"
    end
  end

  test "all known machines are fenced before the first actor is stopped", ctx do
    other = insert_sandbox(user_id: ctx.user.id, status: "ready")
    stub(ConversationServer, :whereis, fn _ -> self() end)

    expect(Termination, :terminate_conversation, fn id, _ ->
      # Cleanup catches actor failures, so assert this snapshot after it returns.
      send(
        self(),
        {:actor_boundary, id, Repo.in_transaction?(),
         Repo.reload!(ctx.sandbox).reset_requested_at, Repo.reload!(other).reset_requested_at}
      )

      :ok
    end)

    expect(Managoat.Sandbox.Sprites, :destroy, 2, fn _ -> :ok end)
    assert Deletion.destroy_sprites(ctx.user) == 2
    assert_received {:actor_boundary, id, false, %DateTime{}, %DateTime{}}
    assert id == ctx.conv.id
    assert length(events(ctx.user.id)) == 2
  end

  test "a machine found after actor shutdown is also fenced before provider deletion", ctx do
    stub(ConversationServer, :whereis, fn _ -> self() end)

    expect(Termination, :terminate_conversation, fn _, _ ->
      late = insert_sandbox(user_id: ctx.user.id, status: "ready")
      send(self(), {:late_sandbox, late.id})
      :ok
    end)

    expect(Managoat.Sandbox.Sprites, :destroy, 2, fn handle ->
      sandbox = Repo.get_by!(Conversations.Sandbox, machine_name: handle.name)
      refute Repo.in_transaction?()
      assert sandbox.reset_requested_at
      :ok
    end)

    assert Deletion.destroy_sprites(ctx.user.id) == 2
    assert_received {:late_sandbox, late_id}
    assert Repo.get!(Conversations.Sandbox, late_id).status == "terminated"
    assert length(events(ctx.user.id)) == 2
  end

  test "a refused fence is logged and the account is still deleted", ctx do
    # Halting here would strand this row: `reset_requested_at` set on a `ready`
    # sandbox whose account survives is invisible to every SandboxReaper pass
    # and keeps burning a quota slot forever. ADR 0009 decision 2 keeps sprite
    # teardown best-effort for exactly this reason.
    stub(Lifecycle, :fence_sandbox_for_teardown, fn _, _ ->
      {:error, :fixture_refusal}
    end)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, %{sprites_destroyed: 0}} = Deletion.delete_user(ctx.user)
      end)

    assert log =~ "fencing #{ctx.sandbox.id} refused"
    assert log =~ ":fixture_refusal"
    refute Repo.get(User, ctx.user.id)
    assert deleted_event(ctx.user.id)
  end

  test "principal cleanup forwards the closing caller's attribution", ctx do
    assert {:ok, %{claimable: claimable}} =
             Principals.create_claimable(ctx.user, %{"application_id" => "fence-test"})

    sandbox = insert_sandbox(user_id: claimable.user_id, status: "ready")

    expect(Managoat.Sandbox.Sprites, :destroy, fn _ ->
      assert Repo.reload!(sandbox).reset_requested_at
      refute Repo.in_transaction?()
      :ok
    end)

    assert {:ok, _} =
             Principals.release(claimable,
               actor: "system:principal_sweep",
               request_ip: "192.0.2.2"
             )

    assert [event] = events(claimable.user_id)
    assert event.actor == "system:principal_sweep"
    assert event.request_ip == "192.0.2.2"
    assert event.metadata["reason"] == "principal_closed"
    assert Repo.reload!(sandbox).status == "terminated"
    refute Repo.reload!(ctx.sandbox).reset_requested_at
  end

  test "provider failure still retires the fenced row and still counts the machine", ctx do
    # The count changed meaning in ADR 0058 stage 5b and this is the test that
    # pinned the old one. It used to be "provider destroys this run confirmed",
    # because this module made the provider call itself and could see the
    # answer. The call is now `Fountain.Machines.Destroy`'s, which logs a
    # provider error and retires the fenced row anyway — deliberately, so a
    # machine is never left in a live status nobody can find — so what reaches
    # here is "the machine was torn down", which is also what
    # `account.deleted`'s `sprites_destroyed` has always read as. The row going
    # terminal is what the reaper reconciles the leftover sprite against, and
    # the provider failure is in the log either way.
    expect(Managoat.Sandbox.Sprites, :destroy, fn _ -> {:error, :unavailable} end)
    assert Deletion.destroy_sprites(ctx.user) == 1
    assert Repo.reload!(ctx.sandbox).status == "terminated"
    assert Repo.reload!(ctx.sandbox).reset_requested_at
    assert Fountain.Quotas.active_sandbox_count(ctx.user.id) == 0
  end

  test "a refused destroy does not count the machine and does not abort the run", ctx do
    # The shape that is still zero: not a provider that answered badly, but a
    # destroy that never ran. `Machines.Destroy` refuses while another owner
    # holds the machine's lease (`:machine_busy`, which the door renders as
    # `:sandbox_unavailable`), and the deletion has to walk on — ADR 0009
    # decision 2 — leaving the fenced row to
    # `SandboxReaper.sweep_fenced_teardowns/0` and destroying the rest now.
    other = insert_sandbox(user_id: ctx.user.id, status: "ready")
    busy = ctx.sandbox.id

    stub(Destroy, :run, fn
      ^busy, _opts -> {:error, :machine_busy}
      id, opts -> Mimic.call_original(Destroy, :run, [id, opts])
    end)

    expect(Managoat.Sandbox.Sprites, :destroy, fn handle ->
      assert handle.name == other.machine_name
      :ok
    end)

    log = ExUnit.CaptureLog.capture_log(fn -> assert Deletion.destroy_sprites(ctx.user) == 1 end)

    assert log =~ "destroy #{ctx.sandbox.machine_name} refused"
    assert log =~ ":sandbox_unavailable"
    assert Repo.reload!(ctx.sandbox).status == "ready"
    assert Repo.reload!(ctx.sandbox).teardown_requested_at
    assert Repo.reload!(other).status == "terminated"
  end

  test "an actor-retired machine is not destroyed or counted again", ctx do
    stub(ConversationServer, :whereis, fn _ -> self() end)

    expect(Termination, :terminate_conversation, fn _, _ ->
      {:ok, _} = Conversations.update_sandbox(ctx.sandbox, %{status: "terminated"})
      :ok
    end)

    reject(Managoat.Sandbox.Sprites, :destroy, 1)
    assert Deletion.destroy_sprites(ctx.user) == 0
    assert [_] = events(ctx.user.id)
  end

  test "refusing a newly discovered machine's fence retains the account", ctx do
    stub(ConversationServer, :whereis, fn _ -> self() end)

    expect(Termination, :terminate_conversation, fn _, _ ->
      late = insert_sandbox(user_id: ctx.user.id, status: "ready")
      send(self(), {:late_sandbox, late.id})
      :ok
    end)

    stub(Lifecycle, :fence_sandbox_for_teardown, fn sandbox, opts ->
      if sandbox.id == ctx.sandbox.id do
        Mimic.call_original(Lifecycle, :fence_sandbox_for_teardown, [sandbox, opts])
      else
        {:error, :late_fence_refused}
      end
    end)

    stub(Managoat.Sandbox.Sprites, :destroy, fn handle ->
      send(self(), {:destroyed, handle.name})
      :ok
    end)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, %{sprites_destroyed: 1}} = Deletion.delete_user(ctx.user)
      end)

    # The refusal is recorded and skipped; the machine that did fence is still
    # destroyed, and the account still goes.
    assert log =~ "late fence refused"
    assert log =~ ":late_fence_refused"
    assert_received {:late_sandbox, late_id}
    late = Repo.get!(Conversations.Sandbox, late_id)
    late_name = late.machine_name
    refute_received {:destroyed, ^late_name}
    refute late.reset_requested_at
    assert late.status == "ready"
    original_name = ctx.sandbox.machine_name
    assert_received {:destroyed, ^original_name}
    refute Repo.get(User, ctx.user.id)
    assert deleted_event(ctx.user.id)
  end

  test "the teardown event still names the tenant after the delete nilifies the column", ctx do
    expect(Managoat.Sandbox.Sprites, :destroy, fn _ -> :ok end)

    assert {:ok, _} = Deletion.delete_user(ctx.user)
    refute Repo.get(User, ctx.user.id)

    # `audit_events.user_id` and `sandboxes.user_id` are both nilified by the
    # delete, so the column cannot answer whose machine this was. The metadata
    # can, the same way `account.deleted` carries email and user id (#1977).
    event =
      Fountain.Audit.Event
      |> where([e], e.action == "sandbox.teardown_requested")
      |> Repo.one!()

    assert is_nil(event.user_id)
    assert event.metadata["user_id"] == ctx.user.id
    assert event.metadata["reason"] == "account_deleted"
  end

  test "an operator's teardown records the plain admin actor (ADR 0013)", ctx do
    expect(Managoat.Sandbox.Sprites, :destroy, fn _ -> :ok end)

    assert Deletion.destroy_sprites(ctx.user, actor: "admin:operator-7") == 1
    assert [event] = events(ctx.user.id)
    assert event.actor == "admin"
  end

  defp admit(ctx, capacity) do
    Conversations._unsafe_create_turn_on_sandbox(
      %{conversation_id: ctx.conv.id, turn_number: 1, status: "running", prompt: "late"},
      ctx.sandbox.id,
      capacity
    )
  end

  defp events(user_id),
    do: Audit.list_for_user(user_id, action_prefix: "sandbox.teardown_requested")

  # After the delete, `audit_events.user_id` is nil, so `list_for_user/2` can no
  # longer find the row. The tenant only survives in the denormalised metadata,
  # which is the whole point of recording it there.
  defp deleted_event(user_id) do
    Fountain.Audit.Event
    |> where([e], e.action == "account.deleted")
    |> Repo.all()
    |> Enum.find(&(&1.metadata["user_id"] == user_id))
  end
end
