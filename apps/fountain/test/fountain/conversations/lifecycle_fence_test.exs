defmodule Fountain.Conversations.LifecycleFenceTest do
  # The server callback reads application-wide lifecycle bounds.
  use Fountain.DataCase, async: false
  use Mimic

  alias Fountain.{Audit, Conversations}
  alias Fountain.Conversations.{ConversationServer, Lifecycle}

  setup do
    bounds = [sandbox_idle_timeout_minutes: 1, sandbox_max_lifetime_hours: 0]
    previous = Enum.map(bounds, fn {key, _} -> {key, Application.fetch_env(:fountain, key)} end)
    Enum.each(bounds, fn {key, value} -> Application.put_env(:fountain, key, value) end)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:fountain, key, value)
        {key, :error} -> Application.delete_env(:fountain, key)
      end)
    end)

    user = insert_verified_user()
    sandbox = insert_sandbox(user_id: user.id, status: "ready")
    conv = insert_conversation(user_id: user.id, sandbox: sandbox, status: "idle")
    handle = Managoat.Sandbox.build_handle(:sprites, sandbox.sprite_name)

    state = %{
      conversation_id: conv.id,
      sandbox_id: sandbox.id,
      user_id: user.id,
      handle: handle,
      sandbox_started_at: DateTime.utc_now(),
      last_activity_at: DateTime.add(DateTime.utc_now(), -120),
      current_turn: nil,
      acp_peer: nil,
      acp_peer_mon: nil,
      current_command: :adapter,
      current_command_ref: nil,
      autonomous_quiet: nil
    }

    stub(Managoat.Sandbox, :supports?, fn :sprites, :suspend -> false end)
    %{user: user, sandbox: sandbox, conv: conv, handle: handle, state: state}
  end

  for capacity <- [1, :unbounded] do
    test "reclaim fences #{inspect(capacity)} admission before provider destruction", ctx do
      expect(Managoat.Sandbox, :destroy, fn handle ->
        assert handle == ctx.handle
        refute Repo.in_transaction?()
        assert Repo.reload!(ctx.sandbox).reset_requested_at
        assert Repo.reload!(ctx.sandbox).status == "ready"
        assert Fountain.Quotas.active_sandbox_count(ctx.user.id) == 1
        assert {:error, :sandbox_unavailable} = admit(ctx, unquote(capacity))
        :ok
      end)

      assert :ok = Lifecycle.destroy(ctx.conv.id, ctx.sandbox.id, ctx.handle, :idle)
      assert Repo.reload!(ctx.sandbox).status == "terminated"
      assert Fountain.Quotas.active_sandbox_count(ctx.user.id) == 0

      assert Repo.aggregate(
               from(t in Conversations.Turn, where: t.conversation_id == ^ctx.conv.id),
               :count
             ) == 0

      assert [event] =
               Audit.list_for_user(ctx.user.id, action_prefix: "sandbox.teardown_requested")

      assert event.actor == "system:conversation_server"
      assert event.metadata["reason"] == "idle"
    end
  end

  test "the server fences before closing its adapter and records one request", ctx do
    expect(Managoat.Sandbox, :close_stdin, fn :adapter ->
      refute Repo.in_transaction?()
      assert Repo.reload!(ctx.sandbox).reset_requested_at
      assert {:error, :sandbox_unavailable} = admit(ctx, :unbounded)
      :ok
    end)

    expect(Managoat.Sandbox, :stop_command, fn :adapter -> :ok end)
    expect(Managoat.Sandbox, :destroy, fn _ -> :ok end)

    assert {:stop, :normal, stopped} = ConversationServer.handle_info(:lifecycle_check, ctx.state)
    assert stopped.current_command == nil
    assert stopped.handle == nil
    assert [_] = Audit.list_for_user(ctx.user.id, action_prefix: "sandbox.teardown_requested")
  end

  for sandbox? <- [true, false] do
    test "an enclosing transaction refuses destruction with sandbox=#{sandbox?}", ctx do
      reject(Managoat.Sandbox, :destroy, 1)
      sandbox_id = if unquote(sandbox?), do: ctx.sandbox.id

      assert {:ok, {:error, :provider_transaction_open}} =
               Repo.transaction(fn ->
                 Lifecycle.destroy(ctx.conv.id, sandbox_id, ctx.handle, :idle)
               end)

      assert Repo.reload!(ctx.sandbox).status == "ready"
      refute Repo.reload!(ctx.sandbox).reset_requested_at
    end
  end

  test "a refused server reclaim retains its adapter and does not report completion", ctx do
    reject(Managoat.Sandbox, :close_stdin, 1)
    reject(Managoat.Sandbox, :destroy, 1)

    assert {:ok, {:noreply, unchanged}} =
             Repo.transaction(fn ->
               ConversationServer.handle_info(:lifecycle_check, ctx.state)
             end)

    assert unchanged == ctx.state
    refute Repo.reload!(ctx.sandbox).reset_requested_at

    refute Repo.exists?(
             from(e in Conversations.LogEvent,
               where:
                 e.conversation_id == ^ctx.conv.id and e.stage == "sandbox" and e.state == "done"
             )
           )
  end

  test "a missing sandbox refuses preparation without touching the adapter", ctx do
    Repo.delete!(ctx.sandbox)
    reject(Managoat.Sandbox, :close_stdin, 1)
    reject(Managoat.Sandbox, :destroy, 1)
    assert {:noreply, unchanged} = ConversationServer.handle_info(:lifecycle_check, ctx.state)
    assert unchanged == ctx.state
  end

  test "a refusal after adapter shutdown keeps the fenced machine for retry", ctx do
    expect(Conversations, :_unsafe_fence_sandbox_for_teardown, fn sandbox, opts ->
      Mimic.call_original(Conversations, :_unsafe_fence_sandbox_for_teardown, [sandbox, opts])
    end)

    expect(Conversations, :_unsafe_fence_sandbox_for_teardown, fn _, _ -> {:error, :not_found} end)

    expect(Managoat.Sandbox, :close_stdin, fn :adapter -> :ok end)
    expect(Managoat.Sandbox, :stop_command, fn :adapter -> :ok end)
    reject(Managoat.Sandbox, :destroy, 1)

    assert {:noreply, retry} = ConversationServer.handle_info(:lifecycle_check, ctx.state)
    assert retry.current_command == nil
    assert retry.handle == ctx.handle
    assert Repo.reload!(ctx.sandbox).reset_requested_at
    assert Repo.reload!(ctx.sandbox).status == "ready"
    assert Fountain.Quotas.active_sandbox_count(ctx.user.id) == 1

    refute Repo.exists?(
             from(e in Conversations.LogEvent,
               where:
                 e.conversation_id == ^ctx.conv.id and e.stage == "sandbox" and e.state == "done"
             )
           )
  end

  defp admit(ctx, capacity) do
    Conversations._unsafe_create_turn_on_sandbox(
      %{conversation_id: ctx.conv.id, turn_number: 1, status: "running", prompt: "late"},
      ctx.sandbox.id,
      capacity
    )
  end
end
