defmodule Fountain.Workers.SandboxResetReconcilerTest do
  use Fountain.DataCase, async: false
  use Mimic

  alias Fountain.Conversations
  alias Fountain.Workers.SandboxResetReconciler

  setup do
    previous = Application.get_env(:managoat_sandbox, Managoat.Sandbox.Sprites)
    Application.put_env(:managoat_sandbox, Managoat.Sandbox.Sprites, token: "test")

    on_exit(fn ->
      if previous,
        do: Application.put_env(:managoat_sandbox, Managoat.Sandbox.Sprites, previous),
        else: Application.delete_env(:managoat_sandbox, Managoat.Sandbox.Sprites)
    end)

    :ok
  end

  defp pending_reset do
    sandbox = insert_sandbox(mode: "persistent", status: "ready")
    stub(Managoat.Sandbox.Sprites, :destroy, fn _ -> {:error, {:unavailable, :timeout}} end)
    assert {:error, :sandbox_reset_pending} = Conversations.reset_sandbox(sandbox)
    Repo.reload!(sandbox)
  end

  test "sweeps discover lost callers and keep one job through retry backoff" do
    sandbox = pending_reset()
    _live = insert_sandbox(mode: "persistent", status: "ready")
    assert :ok = perform_job(SandboxResetReconciler, %{})
    assert :ok = perform_job(SandboxResetReconciler, %{})
    assert [job] = all_enqueued(worker: SandboxResetReconciler)
    assert job.args == %{"sandbox_id" => sandbox.id}

    for state <- ["retryable", "suspended"] do
      Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id), set: [state: state])
      assert :ok = perform_job(SandboxResetReconciler, %{})
      assert Repo.aggregate(from(j in Oban.Job, where: j.worker == ^job.worker), :count) == 1
    end

    Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id), set: [state: "discarded"])
    assert :ok = perform_job(SandboxResetReconciler, %{})
    assert [_] = all_enqueued(worker: SandboxResetReconciler)
    assert Repo.aggregate(from(j in Oban.Job, where: j.worker == ^job.worker), :count) == 2
  end

  test "failed deletes retry with capacity held; confirmed deletion completes the job" do
    sandbox = pending_reset()

    assert {:error, :sandbox_reset_pending} =
             perform_job(SandboxResetReconciler, %{sandbox_id: sandbox.id})

    assert Repo.reload!(sandbox).status == "ready"
    assert Fountain.Quotas.active_sandbox_count(sandbox.user_id) == 1

    expect(Managoat.Sandbox.Sprites, :destroy, fn h ->
      assert h.name == sandbox.machine_name
      refute Repo.in_transaction?()
      :ok
    end)

    assert :ok = perform_job(SandboxResetReconciler, %{sandbox_id: sandbox.id})
    assert Repo.reload!(sandbox).status == "terminated"
    assert Fountain.Quotas.active_sandbox_count(sandbox.user_id) == 0
    assert :ok = perform_job(SandboxResetReconciler, %{sandbox_id: sandbox.id})

    assert [event] =
             Repo.all(
               from a in Fountain.Audit.Event,
                 where: a.resource_id == ^sandbox.id and a.action == "sandbox.reset"
             )

    assert event.actor == "system:sandbox_reset_reconciler"
  end

  test "the sweep leaves a reset whose owner still holds the machine" do
    Mimic.set_mimic_global()

    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      user = insert_verified_user()
      home = insert_sandbox(user_id: user.id, mode: "persistent", status: "ready")
      conv = insert_conversation(user_id: user.id, sandbox: home, status: "idle")
      owner = self()

      stub(Managoat.Sandbox.Sprites, :destroy, fn _ ->
        refute Repo.in_transaction?()

        if Process.get(:hold_original_reset) do
          send(owner, :original_deleting)

          receive do
            :confirmed -> :ok
          after
            5_000 -> flunk("original provider barrier timed out")
          end
        else
          :ok
        end
      end)

      original =
        Task.async(fn ->
          Process.put(:hold_original_reset, true)

          Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
            Conversations.reset_sandbox(home)
          end)
        end)

      try do
        assert_receive :original_deleting, 5_000

        # ADR 0058 stage 5c inverts who wins this race, and the sweep is the
        # first of the two guards that does it. The original reset holds the
        # machine's lease across its provider call, so the row is not an
        # abandoned fence and the sweep does not enqueue a job for it. Before
        # the lease, this sweep reached a machine another caller was halfway
        # through deleting and finished the reset from underneath it — which
        # converged, but by way of a second provider delete and an audit row
        # naming the reconciler for work the original had done.
        assert :ok = perform_job(SandboxResetReconciler, %{})
        assert all_enqueued(worker: SandboxResetReconciler) == []

        # The second guard, for a job enqueued before the lease was taken: the
        # retry refuses rather than calling the provider beside the holder.
        assert {:snooze, 60} = perform_job(SandboxResetReconciler, %{sandbox_id: home.id})

        assert Repo.reload!(home).status == "ready"

        replacement = insert_sandbox(user_id: user.id, status: "ready")
        {:ok, _} = Conversations.update_conversation(conv, %{sandbox_id: replacement.id})
        {:ok, _} = Horde.Registry.register(Fountain.ConversationRegistry, conv.id, nil)
        send(original.pid, :confirmed)

        # The original is the winner now, and the one completion published is
        # its own. The holder rebound while it was at the provider, so the
        # notice it publishes goes to the conversation's live server — which is
        # the replacement's — and that is the `{:sandbox_reset, …}` cast the
        # old assertion refused for the *loser*. The reset happened; this
        # conversation is on the machine it names, and being told the old one
        # was reset is exactly the message.
        assert {:ok, %{status: "terminated"}} = Task.await(original, 5_000)
        assert_receive {:"$gen_cast", {:sandbox_reset, sandbox_id, _reason, _by, _message}}
        assert sandbox_id == home.id

        # And once it is over, a late job for the same row deletes nothing and
        # publishes nothing.
        assert :ok = perform_job(SandboxResetReconciler, %{sandbox_id: home.id})
        refute_received {:"$gen_cast", _}

        assert [event] =
                 Repo.all(
                   from a in Fountain.Audit.Event,
                     where: a.resource_id == ^home.id and a.action == "sandbox.reset"
                 )

        assert event.actor == "self"
      after
        Horde.Registry.unregister(Fountain.ConversationRegistry, conv.id)
        Task.shutdown(original, :brutal_kill)

        Repo.delete_all(
          from j in Oban.Job, where: fragment("?->>'sandbox_id' = ?", j.args, ^home.id)
        )

        Repo.delete_all(from c in Conversations.Conversation, where: c.user_id == ^user.id)
        Repo.delete_all(from s in Conversations.Sandbox, where: s.user_id == ^user.id)
        Repo.delete_all(from a in Fountain.Audit.Event, where: a.user_id == ^user.id)
        Repo.delete_all(from a in Fountain.Agents.Agent, where: a.user_id == ^user.id)
        Repo.delete_all(from u in Fountain.Accounts.User, where: u.id == ^user.id)
      end
    end)
  end

  test "disabled providers wait; stale jobs never delete an unfenced or missing machine" do
    sandbox = pending_reset()
    Application.delete_env(:managoat_sandbox, Managoat.Sandbox.Sprites)
    reject(Managoat.Sandbox.Sprites, :destroy, 1)
    assert {:snooze, 300} = perform_job(SandboxResetReconciler, %{sandbox_id: sandbox.id})
    assert Repo.reload!(sandbox).status == "ready"

    live = insert_sandbox(mode: "persistent", status: "ready")
    assert :ok = perform_job(SandboxResetReconciler, %{sandbox_id: live.id})
    assert :ok = perform_job(SandboxResetReconciler, %{sandbox_id: Ecto.UUID.generate()})
  end
end
