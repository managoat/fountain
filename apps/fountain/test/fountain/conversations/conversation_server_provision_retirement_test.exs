defmodule Fountain.Conversations.ConversationServerProvisionRetirementTest do
  use Fountain.ConversationServerCase

  for terminal <- ["terminated", "failed", "reset_pending"] do
    test "retirement to #{terminal} before starting does not provision or fail the replacement" do
      stub_happy_sprite()
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id, runtime: "gemini")
      conv = insert_conversation(user_id: user.id, agent: agent, status: "idle")
      sandbox = Conversations._unsafe_get_sandbox!(conv.sandbox_id)
      test = self()

      stub(Conversations, :update_sandbox, fn row, attrs ->
        if attrs[:status] == "starting" do
          send(test, {:starting_paused, self()})
          receive do: (:resume_starting -> :ok)
        end

        Mimic.call_original(Conversations, :update_sandbox, [row, attrs])
      end)

      reject(Managoat.Sandbox.Sprites, :create, 2)
      reject(Managoat.Sandbox.Sprites, :destroy, 1)
      reject(Fountain.Broker, :prepare, 4)

      {:ok, pid} =
        GenServer.start(ConversationServer,
          conversation_id: conv.id,
          sandbox_id: sandbox.id,
          runtime_module: Managoat.Runtimes.Testing.FakeRuntime
        )

      ref = Process.monitor(pid)
      on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
      assert_receive {:starting_paused, ^pid}, 5_000

      retired =
        if unquote(terminal) == "reset_pending" do
          sandbox
          |> Ecto.Changeset.change(reset_requested_at: DateTime.utc_now())
          |> Fountain.Repo.update!()
        else
          {:ok, retired} = Conversations.update_sandbox(sandbox, %{status: unquote(terminal)})
          retired
        end

      replacement = insert_sandbox(user_id: user.id, status: "ready")
      {:ok, _} = Conversations.update_conversation(conv, %{sandbox_id: replacement.id})
      send(pid, :resume_starting)

      assert :normal = assert_stopped(ref, 5_000)
      assert Fountain.Repo.reload!(sandbox).status == retired.status
      assert Fountain.Repo.reload!(sandbox).terminated_at == retired.terminated_at
      assert Fountain.Repo.reload!(sandbox).reset_requested_at == retired.reset_requested_at
      assert Fountain.Repo.reload!(conv).status == "idle"
      assert Fountain.Repo.reload!(conv).sandbox_id == replacement.id
      assert Fountain.Repo.reload!(replacement).status == "ready"
      assert is_nil(Fountain.Repo.reload!(conv).callback_api_key_id)
      refute Enum.any?(Conversations._unsafe_list_log_events(conv.id), &(&1.stage == "provision"))
    end
  end
end
