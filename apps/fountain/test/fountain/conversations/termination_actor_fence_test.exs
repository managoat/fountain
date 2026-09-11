defmodule Fountain.Conversations.TerminationActorFenceTest do
  use Fountain.DataCase, async: true
  use Mimic

  alias Fountain.{Audit, Conversations}
  alias Fountain.Conversations.ConversationServer

  setup do
    user = insert_verified_user()
    agent = insert_agent(user_id: user.id)
    sandbox = insert_sandbox(user_id: user.id, agent_id: agent.id, status: "ready")
    conv = insert_conversation(user_id: user.id, agent: agent, sandbox: sandbox, status: "idle")
    handle = Managoat.Sandbox.build_handle(:sprites, sandbox.sprite_name)

    state = %{
      conversation_id: conv.id,
      sandbox_id: sandbox.id,
      user_id: user.id,
      handle: handle,
      current_turn: nil,
      acp_peer: nil,
      acp_peer_mon: nil,
      current_command: :adapter,
      current_command_ref: nil,
      autonomous_quiet: nil
    }

    stub(Managoat.Sandbox, :close_stdin, fn :adapter -> :ok end)
    stub(Managoat.Sandbox, :stop_command, fn :adapter -> :ok end)
    %{user: user, agent: agent, sandbox: sandbox, conv: conv, handle: handle, state: state}
  end

  for capacity <- [1, :unbounded] do
    test "legacy termination fences #{inspect(capacity)} admission before adapter/provider work",
         ctx do
      expect(Managoat.Sandbox, :close_stdin, fn :adapter ->
        refute Repo.in_transaction?()
        assert Repo.reload!(ctx.sandbox).reset_requested_at
        :ok
      end)

      expect(Managoat.Sandbox, :destroy, fn handle ->
        assert handle == ctx.handle
        refute Repo.in_transaction?()
        assert Repo.reload!(ctx.sandbox).reset_requested_at
        assert Fountain.Quotas.active_sandbox_count(ctx.user.id) == 1
        assert {:error, :sandbox_unavailable} = admit(ctx, unquote(capacity))
        :ok
      end)

      assert {:stop, :normal, :ok, stopped} = terminate(ctx, :terminate_conv)
      assert stopped.current_command == nil
      assert Repo.reload!(ctx.conv).status == "terminated"
      assert Repo.reload!(ctx.sandbox).status == "terminated"
      assert Fountain.Quotas.active_sandbox_count(ctx.user.id) == 0
      assert [event] = events(ctx)
      assert event.actor == "self"
      assert event.metadata["reason"] == "conversation_terminated"
    end
  end

  test "the attributed request records the caller on the committed fence", ctx do
    expect(Managoat.Sandbox, :destroy, fn _ -> :ok end)

    assert {:stop, :normal, :ok, _} =
             terminate(ctx, {:terminate_conv, [actor: "ui", request_ip: "192.0.2.3"]})

    assert [event] = events(ctx)
    assert event.actor == "ui"
    assert event.request_ip == "192.0.2.3"
  end

  for retained <- [:persistent, :shared] do
    test "#{retained} machines are kept without an admission fence", ctx do
      case unquote(retained) do
        :persistent ->
          ctx.sandbox |> Ecto.Changeset.change(mode: "persistent") |> Repo.update!()

        :shared ->
          insert_conversation(
            user_id: ctx.user.id,
            agent: ctx.agent,
            sandbox: ctx.sandbox,
            status: "idle"
          )
      end

      reject(Managoat.Sandbox, :destroy, 1)
      assert {:stop, :normal, :ok, stopped} = terminate(ctx, :terminate_conv)
      assert stopped.handle == nil
      assert Repo.reload!(ctx.conv).status == "terminated"
      assert Repo.reload!(ctx.sandbox).status == "ready"
      refute Repo.reload!(ctx.sandbox).reset_requested_at
      assert events(ctx) == []
    end
  end

  test "a moved conversation refuses before touching the old adapter or machine", ctx do
    replacement = insert_sandbox(user_id: ctx.user.id, status: "ready")
    {:ok, _} = Conversations.update_conversation(ctx.conv, %{sandbox_id: replacement.id})
    reject(Managoat.Sandbox, :close_stdin, 1)
    reject(Managoat.Sandbox, :destroy, 1)
    assert {:reply, {:error, :sandbox_unavailable}, unchanged} = terminate(ctx, :terminate_conv)
    assert unchanged == ctx.state
    assert Repo.reload!(ctx.conv).status == "idle"
    refute Repo.reload!(ctx.sandbox).reset_requested_at
    refute Repo.reload!(replacement).reset_requested_at
  end

  for cleanup <- [:destroy, :keep] do
    @tag cleanup: cleanup
    test "reassignment during #{cleanup} cleanup preserves the replacement conversation", ctx do
      replacement = insert_sandbox(user_id: ctx.user.id, status: "ready")
      owner = self()

      reassign = fn ->
        {:ok, moved} =
          Conversations.update_conversation(ctx.conv, %{
            sandbox_id: replacement.id,
            status: "running"
          })

        send(owner, {:replacement_turn, insert_turn(moved, status: "running")})
        :ok
      end

      if ctx.cleanup == :keep do
        ctx.sandbox |> Ecto.Changeset.change(mode: "persistent") |> Repo.update!()
        expect(Managoat.Sandbox, :close_stdin, fn :adapter -> reassign.() end)
        reject(Managoat.Sandbox, :destroy, 1)
      else
        expect(Managoat.Sandbox, :destroy, fn handle ->
          assert handle == ctx.handle
          reassign.()
        end)
      end

      assert {:stop, :normal, {:error, :sandbox_unavailable}, _} = terminate(ctx, :terminate_conv)
      assert_received {:replacement_turn, turn}
      assert Repo.reload!(turn) == turn
      assert Repo.reload!(ctx.conv).sandbox_id == replacement.id
      assert Repo.reload!(ctx.conv).status == "running"
      assert Repo.reload!(replacement).status == "ready"
      refute Repo.reload!(replacement).reset_requested_at
      expected_old_status = if ctx.cleanup == :keep, do: "ready", else: "terminated"
      assert Repo.reload!(ctx.sandbox).status == expected_old_status
      assert termination_stages(ctx) == []
    end
  end

  test "a conversation deleted during provider cleanup does not crash final bookkeeping", ctx do
    expect(Managoat.Sandbox, :destroy, fn _ ->
      Repo.delete!(ctx.conv)
      :ok
    end)

    assert {:stop, :normal, {:error, :sandbox_unavailable}, _} = terminate(ctx, :terminate_conv)
    assert Repo.reload(ctx.conv) == nil
    assert Repo.reload!(ctx.sandbox).status == "terminated"
    assert termination_stages(ctx) == []
  end

  test "an enclosing transaction refuses termination before side effects", ctx do
    reject(Managoat.Sandbox, :close_stdin, 1)
    reject(Managoat.Sandbox, :destroy, 1)

    assert {:ok, {:reply, {:error, :provider_transaction_open}, unchanged}} =
             Repo.transaction(fn -> terminate(ctx, :terminate_conv) end)

    assert unchanged == ctx.state
    assert Repo.reload!(ctx.conv).status == "idle"
    refute Repo.reload!(ctx.sandbox).reset_requested_at
  end

  test "a missing machine returns refusal without closing the adapter", ctx do
    Repo.delete!(ctx.sandbox)
    reject(Managoat.Sandbox, :close_stdin, 1)
    reject(Managoat.Sandbox, :destroy, 1)
    assert {:reply, {:error, :sandbox_unavailable}, unchanged} = terminate(ctx, :terminate_conv)
    assert unchanged == ctx.state
  end

  test "a provider error still retires the fenced row for reconciliation", ctx do
    expect(Managoat.Sandbox, :destroy, fn _ -> {:error, :unavailable} end)
    assert {:stop, :normal, :ok, _} = terminate(ctx, :terminate_conv)
    assert Repo.reload!(ctx.sandbox).status == "terminated"
    assert Repo.reload!(ctx.sandbox).reset_requested_at
  end

  defp terminate(ctx, message),
    do: ConversationServer.handle_call(message, {self(), make_ref()}, ctx.state)

  defp termination_stages(ctx) do
    Repo.all(
      from e in Conversations.LogEvent,
        where: e.conversation_id == ^ctx.conv.id and e.stage == "terminate" and e.state == "done"
    )
  end

  defp events(ctx),
    do: Audit.list_for_user(ctx.user.id, action_prefix: "sandbox.teardown_requested")

  defp admit(ctx, capacity) do
    Conversations._unsafe_create_turn_on_sandbox(
      %{conversation_id: ctx.conv.id, turn_number: 1, status: "running", prompt: "late"},
      ctx.sandbox.id,
      capacity
    )
  end
end
