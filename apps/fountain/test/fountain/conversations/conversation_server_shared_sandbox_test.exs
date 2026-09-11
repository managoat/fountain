defmodule Fountain.Conversations.ConversationServerSharedSandboxTest do
  # A ConversationServer on a machine other conversations also hold
  # (ADR 0023 steps 4 and 5): a turn is refused at the runtime's capacity,
  # terminating one conversation leaves the sprite to the others, and the
  # idle verdict is taken over everyone's activity, not one server's clock.
  use Fountain.ConversationServerCase

  alias Fountain.Repo

  defp with_bounds(pairs, fun) do
    previous = Enum.map(pairs, fn {k, _} -> {k, Application.get_env(:fountain, k)} end)
    Enum.each(pairs, fn {k, v} -> Application.put_env(:fountain, k, v) end)

    try do
      fun.()
    after
      Enum.each(previous, fn {k, v} -> Application.put_env(:fountain, k, v) end)
    end
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  # Two idle conversations of one agent on one `ready` sandbox. Starting a
  # server for either takes the reattach path, which the shared harness's
  # `get/1` probe stub already satisfies.
  defp shared_machine(runtime) do
    user = insert_verified_user()
    agent = insert_agent(user_id: user.id, runtime: runtime)
    sandbox = insert_sandbox(user_id: user.id, status: "ready")
    a = insert_conversation(user_id: user.id, agent: agent, sandbox: sandbox, status: "idle")
    b = insert_conversation(user_id: user.id, agent: agent, sandbox: sandbox, status: "idle")
    %{user: user, agent: agent, sandbox: sandbox, a: a, b: b}
  end

  defp stub_turn_boundary do
    test = self()
    ref = make_ref()

    Mimic.stub(Managoat.Sandbox.Sprites, :spawn, fn _h, cmd, args, opts ->
      send(test, {:spawned, cmd, args, opts})
      {:ok, %Managoat.Sandbox.Command{provider: :sprites, ref: ref}}
    end)

    Mimic.stub(Managoat.Sandbox.Sprites, :write_stdin, fn _c, _data -> :ok end)
    Mimic.stub(Managoat.Sandbox.Sprites, :close_stdin, fn _c -> :ok end)
    Mimic.stub(Managoat.Sandbox.Sprites, :stop_command, fn _c -> :ok end)
    ref
  end

  defp start(conv) do
    {pid, ref, :alive} = start_server(conv)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    {pid, ref}
  end

  defp sandbox_stages(conv_id) do
    conv_id
    |> Conversations._unsafe_list_log_events()
    |> Enum.filter(&(&1.kind == "stage" and &1.stage == "sandbox"))
    |> Enum.map(&Jason.decode!(&1.data))
  end

  describe "capacity" do
    test "a second prompt on an opencode machine is refused while another turn runs" do
      %{a: a, b: b} = shared_machine("opencode")
      insert_turn(a, %{status: "running", prompt: "busy", started_at: now()})

      stub_happy_sprite()
      _ref = stub_turn_boundary()
      {pid, _} = start(b)

      assert {:error, :sandbox_at_capacity} = GenServer.call(pid, {:send_prompt, "hi", []})
      assert Conversations._unsafe_list_turns(b.id) == []
      assert Conversations._unsafe_get_conversation!(b.id).status == "idle"
      refute_received {:spawned, _, _, _}
    end

    test "claude conversations run at the same time on one machine" do
      %{a: a, b: b} = shared_machine("claude")
      insert_turn(a, %{status: "running", prompt: "busy", started_at: now()})

      stub_happy_sprite()
      _ref = stub_turn_boundary()
      {pid, _} = start(b)

      assert :ok = GenServer.call(pid, {:send_prompt, "hi", []})
      assert_receive {:spawned, "env", _, _}, 2_000
      assert [%{status: "running"}] = Conversations._unsafe_list_turns(b.id)
    end

    test "the locked insert refuses on the path that has no gate, and says so" do
      # The API door reads the gate first; the initial prompt (a cast, no
      # caller to answer) goes straight to the insert, which checks under the
      # sandbox's advisory lock. Refused there means: no turn row, a stage
      # event on the transcript, the conversation still idle.
      %{a: a, b: b} = shared_machine("opencode")
      insert_turn(a, %{status: "running", prompt: "busy", started_at: now()})

      stub_happy_sprite()
      _ref = stub_turn_boundary()
      {pid, _mon, :alive} = start_server(b, initial_prompt: "hi")
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
      _ = :sys.get_state(pid)

      assert Conversations._unsafe_list_turns(b.id) == []
      assert Conversations._unsafe_get_conversation!(b.id).status == "idle"
      refute_received {:spawned, _, _, _}

      assert Enum.any?(sandbox_stages(b.id), &(&1["event"] == "at_capacity"))
    end
  end

  describe "terminate" do
    test "keeps the sprite while another conversation holds it, destroys it when last" do
      %{a: a, b: b, sandbox: sandbox} = shared_machine("claude")
      stub_happy_sprite()
      test = self()
      Mimic.stub(Managoat.Sandbox.Sprites, :destroy, fn _h -> send(test, :destroyed) && :ok end)

      {pid_a, ref_a} = start(a)
      assert :ok = GenServer.call(pid_a, :terminate_conv)
      assert :normal = assert_stopped(ref_a)

      refute_received :destroyed
      assert Repo.reload(sandbox).status == "ready"
      assert Conversations._unsafe_get_conversation!(a.id).status == "terminated"

      {pid_b, ref_b} = start(b)
      assert :ok = GenServer.call(pid_b, :terminate_conv)
      assert :normal = assert_stopped(ref_b)

      assert_received :destroyed
      assert Repo.reload(sandbox).status == "terminated"
    end
  end

  describe "idle" do
    test "an idle conversation does not park a machine another one is using" do
      %{a: a, b: b, sandbox: sandbox} = shared_machine("claude")
      stub_happy_sprite()
      reject(&Managoat.Sandbox.Sprites.destroy/1)
      turn = insert_turn(b, %{status: "running", prompt: "long", started_at: now()})

      with_bounds([sandbox_idle_timeout_minutes: 60, sandbox_max_lifetime_hours: 24], fn ->
        {pid, ref} = start(a)

        :sys.replace_state(pid, fn state ->
          %{state | last_activity_at: DateTime.add(DateTime.utc_now(), -7200, :second)}
        end)

        send(pid, :lifecycle_check)
        _ = :sys.get_state(pid)
        assert Process.alive?(pid)
        assert Repo.reload(sandbox).status == "ready"

        # The other conversation goes quiet: its turn ended two hours ago.
        old = DateTime.add(now(), -7200, :second)

        turn
        |> Ecto.Changeset.change(status: "completed", ended_at: old, inserted_at: old)
        |> Repo.update!()

        send(pid, :lifecycle_check)
        assert :normal = assert_stopped(ref)
        assert Repo.reload(sandbox).status == "suspended"
      end)
    end

    test "a home at the ceiling is parked, not destroyed (ADR 0023)" do
      %{a: a, sandbox: sandbox} = shared_machine("claude")
      {:ok, _} = Conversations.update_sandbox(sandbox, %{mode: "persistent"})
      stub_happy_sprite()
      reject(&Managoat.Sandbox.Sprites.destroy/1)
      Mimic.stub(Managoat.Sandbox.Sprites, :suspend, fn _h -> :ok end)

      with_bounds([sandbox_idle_timeout_minutes: 0, sandbox_max_lifetime_hours: 24], fn ->
        {pid, ref} = start(a)

        :sys.replace_state(pid, fn state ->
          %{state | sandbox_started_at: DateTime.add(DateTime.utc_now(), -25 * 3600, :second)}
        end)

        send(pid, :lifecycle_check)
        assert :normal = assert_stopped(ref)
      end)

      assert Repo.reload(sandbox).status == "suspended"

      assert Enum.any?(sandbox_stages(a.id), fn d ->
               d["event"] == "suspended" and d["reason"] == "max_lifetime"
             end)
    end

    for active? <- [false, true] do
      @tag active?: active?
      test "a qualified notification stops its #{if active?, do: "active", else: "idle"} actor",
           ctx do
        %{b: b, sandbox: sandbox} = shared_machine("claude")
        stub_happy_sprite()
        stub_turn_boundary()
        {pid, ref} = start(b)

        if ctx.active? do
          assert :ok = GenServer.call(pid, {:send_prompt, "hi", []})
        else
          # The actor has no turn, but a lost completion left its parent running.
          {:ok, _} = Conversations.update_conversation(b, %{status: "running"})
        end

        GenServer.cast(pid, {:machine_gone, sandbox.id, "suspended", "idle", "parked"})
        assert :normal = assert_stopped(ref)
        assert Repo.reload!(b).status == "idle"

        if ctx.active? do
          assert [%{status: "interrupted"}] = Conversations._unsafe_list_turns(b.id)
        end

        assert Enum.any?(sandbox_stages(b.id), &(&1["event"] == "suspended"))
      end
    end

    test "an obsolete notification leaves the replacement actor and its turn alone" do
      %{b: b, user: user} = shared_machine("claude")
      old = insert_sandbox(user_id: user.id, status: "terminated")
      stub_happy_sprite()
      stub_turn_boundary()
      {pid, _ref} = start(b)
      assert :ok = GenServer.call(pid, {:send_prompt, "hi", []})
      state = :sys.get_state(pid)
      [turn] = Conversations._unsafe_list_turns(b.id)
      turn = Repo.reload!(turn)
      events = sandbox_stages(b.id)
      owner = self()

      Mimic.stub(Managoat.Sandbox.Sprites, :close_stdin, fn _ ->
        send(owner, :closed)
        :ok
      end)

      Mimic.stub(Managoat.Sandbox.Sprites, :stop_command, fn _ ->
        send(owner, :stopped)
        :ok
      end)

      GenServer.cast(pid, {:machine_gone, old.id, "reset", "home_reset", "obsolete"})
      assert :sys.get_state(pid) == state
      assert Repo.reload!(turn) == turn
      assert Repo.reload!(b).status == "running"
      assert sandbox_stages(b.id) == events
      refute_received :closed
      refute_received :stopped
    end

    for change <- [:reassigned, :terminated, :failed, :new_turn, :deleted] do
      @tag during_cleanup: change
      test "#{change} during machine-gone cleanup preserves the committed state", ctx do
        %{b: b, sandbox: sandbox, user: user} = shared_machine("claude")
        replacement = insert_sandbox(user_id: user.id, status: "ready")
        stub_happy_sprite()
        stub_turn_boundary()
        {pid, ref} = start(b)
        assert :ok = GenServer.call(pid, {:send_prompt, "hi", []})
        [turn] = Conversations._unsafe_list_turns(b.id)
        owner = self()

        Mimic.stub(Managoat.Sandbox.Sprites, :close_stdin, fn _ ->
          refute Repo.in_transaction?()

          case ctx.during_cleanup do
            :reassigned ->
              Conversations.update_conversation(b, %{sandbox_id: replacement.id})

            terminal when terminal in [:terminated, :failed] ->
              Conversations.update_conversation(b, %{status: Atom.to_string(terminal)})

            :new_turn ->
              turn |> Ecto.Changeset.change(status: "completed") |> Repo.update!()
              insert_turn(b, status: "running")

            :deleted ->
              Repo.delete!(Repo.reload!(b))
          end

          send(owner, {:persisted, Repo.reload(b), Repo.reload(turn)})
          :ok
        end)

        GenServer.cast(pid, {:machine_gone, sandbox.id, "suspended", "idle", "stale"})
        assert :normal = assert_stopped(ref)
        assert_received {:persisted, persisted_conv, persisted_turn}
        assert Repo.reload(b) == persisted_conv
        assert Repo.reload(turn) == persisted_turn
        refute Enum.any?(sandbox_stages(b.id), &(&1["message"] == "stale"))
      end
    end

    test "a co-tenant told the machine is gone records it and stops" do
      %{b: b} = shared_machine("claude")
      stub_happy_sprite()
      {pid, ref} = start(b)

      GenServer.cast(pid, {:machine_gone, "suspended", "idle", "parked by a neighbour"})
      assert :normal = assert_stopped(ref)

      assert Enum.any?(sandbox_stages(b.id), fn d ->
               d["event"] == "suspended" and d["by"] == "another_conversation"
             end)
    end
  end
end
