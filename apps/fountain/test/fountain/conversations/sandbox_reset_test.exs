defmodule Fountain.Conversations.SandboxResetTest do
  # #1071: resetting a home destroys the machine and keeps the conversations;
  # each one's next prompt builds a fresh home (ADR 0023 step 5).
  use Fountain.DataCase, async: true
  use Mimic

  alias Fountain.Conversations
  alias Fountain.Conversations.ConversationServer

  setup do
    user = insert_active_user()
    {:ok, user} = Fountain.Accounts.update_sandbox_limit(user, 10)
    env = insert_env(user_id: user.id)
    agent = insert_agent(user_id: user.id, runtime: "claude", environment_id: env.id)

    home =
      insert_sandbox(
        user_id: user.id,
        status: "ready",
        mode: "persistent",
        agent_id: agent.id,
        environment_id: env.id,
        provider: "sprites"
      )

    a =
      insert_conversation(
        user_id: user.id,
        agent: agent,
        sandbox: home,
        status: "idle",
        runtime_session_id: "sess-a"
      )

    b = insert_conversation(user_id: user.id, agent: agent, sandbox: home, status: "idle")
    stub(Horde.DynamicSupervisor, :start_child, fn _s, _spec -> {:ok, spawn(fn -> :ok end)} end)
    {:ok, user: user, env: env, agent: agent, home: home, a: a, b: b}
  end

  test "an enclosing transaction cannot start provider deletion or persist a reset fence", ctx do
    reject(Managoat.Sandbox.Sprites, :destroy, 1)

    assert {:ok, {:error, :provider_transaction_open}} =
             Repo.transaction(fn -> Conversations.reset_sandbox(ctx.home) end)

    assert Repo.reload!(ctx.home).status == "ready"
    refute Repo.reload!(ctx.home).reset_requested_at
    assert Repo.reload!(ctx.a).runtime_session_id == "sess-a"
    assert Conversations._unsafe_list_log_events(ctx.a.id) == []
  end

  test "destroys the sprite, retires the row, keeps the conversations", ctx do
    test = self()
    stub(Managoat.Sandbox.Sprites, :destroy, fn h -> send(test, {:destroyed, h.name}) && :ok end)

    assert {:ok, sandbox} = Conversations.reset_sandbox(ctx.home, actor: "api")
    assert sandbox.status == "terminated"
    assert_received {:destroyed, name}
    assert name == ctx.home.sprite_name

    for conv <- [ctx.a, ctx.b] do
      reloaded = Conversations._unsafe_get_conversation!(conv.id)
      assert reloaded.status == "idle"
      assert reloaded.sandbox_id == ctx.home.id
      assert is_nil(reloaded.runtime_session_id)
    end
  end

  test "every conversation's transcript says the machine was reset", ctx do
    stub(Managoat.Sandbox.Sprites, :destroy, fn _h -> :ok end)
    assert {:ok, _} = Conversations.reset_sandbox(ctx.home)

    for conv <- [ctx.a, ctx.b] do
      assert [event] =
               Conversations._unsafe_list_log_events(conv.id)
               |> Enum.filter(&(&1.kind == "stage" and &1.stage == "sandbox"))

      assert %{"event" => "reset", "reason" => "home_reset"} = Jason.decode!(event.data)
    end
  end

  test "a live server on the home is told the machine is gone, and nothing else", ctx do
    stub(Managoat.Sandbox.Sprites, :destroy, fn _h -> :ok end)
    test = self()

    # Stand in for conversation A's ConversationServer: registered under its
    # id, forwards whatever is cast to it.
    fake =
      spawn(fn ->
        {:ok, _} = Horde.Registry.register(Fountain.ConversationRegistry, ctx.a.id, nil)
        send(test, :registered)

        receive do
          {:"$gen_cast", msg} -> send(test, {:cast, msg})
        end
      end)

    assert_receive :registered
    assert {:ok, ^fake} = ConversationServer.await_registered(ctx.a.id)

    assert {:ok, _} = Conversations.reset_sandbox(ctx.home)
    sandbox_id = ctx.home.id
    assert_receive {:cast, {:machine_gone, ^sandbox_id, "reset", "home_reset", message}}, 1_000
    assert message =~ "reset by its owner"

    # The server records the event on A's transcript itself; the reset does
    # not write a second one. B, with no server, gets it recorded here.
    assert Conversations._unsafe_list_log_events(ctx.a.id)
           |> Enum.filter(&(&1.stage == "sandbox")) == []

    assert [_] =
             Conversations._unsafe_list_log_events(ctx.b.id)
             |> Enum.filter(&(&1.stage == "sandbox"))
  end

  test "refused while a conversation on it is mid-turn", ctx do
    insert_turn(ctx.a, status: "running")
    assert {:error, :sandbox_mid_turn} = Conversations.reset_sandbox(ctx.home)
    assert Conversations._unsafe_get_sandbox!(ctx.home.id).status == "ready"
  end

  test "refused for an ephemeral sandbox and for one already gone", ctx do
    ephemeral = insert_sandbox(user_id: ctx.user.id, status: "ready", mode: "ephemeral")

    assert {:error, {:sandbox_not_resettable, "ephemeral"}} =
             Conversations.reset_sandbox(ephemeral)

    stub(Managoat.Sandbox.Sprites, :destroy, fn _h -> :ok end)
    {:ok, gone} = Conversations.reset_sandbox(ctx.home)

    assert {:error, {:sandbox_not_resettable, "terminated"}} =
             Conversations.reset_sandbox(gone)
  end

  for capacity <- [1, :unbounded] do
    test "reset fences #{inspect(capacity)} admission before calling the provider", ctx do
      expect(Managoat.Sandbox.Sprites, :destroy, fn _ ->
        refute Repo.in_transaction?()
        assert Fountain.Quotas.active_sandbox_count(ctx.user.id) == 1

        assert {:error, :sandbox_unavailable} =
                 Conversations._unsafe_create_turn_on_sandbox(
                   %{
                     conversation_id: ctx.a.id,
                     turn_number: 1,
                     status: "running",
                     prompt: "late"
                   },
                   ctx.home.id,
                   unquote(capacity)
                 )

        assert {:error, :sandbox_reset_pending} = Conversations.reset_sandbox(ctx.home)
        :ok
      end)

      assert {:ok, %{status: "terminated"}} = Conversations.reset_sandbox(ctx.home)
      assert Fountain.Quotas.active_sandbox_count(ctx.user.id) == 0
    end
  end

  test "an uncertain destroy retains capacity and cannot be retried or swept", ctx do
    expect(Managoat.Sandbox.Sprites, :destroy, fn _ -> {:error, :timeout} end)
    assert {:error, :sandbox_reset_pending} = Conversations.reset_sandbox(ctx.home)
    assert {:error, :sandbox_reset_pending} = Conversations.reset_sandbox(ctx.home)
    assert {:error, :sandbox_reset_pending} = Conversations.wake_conversation(ctx.a.id)

    # A write that would keep the machine alive is refused. A write that
    # retires it is not, and is covered in the describe block below.
    assert {:error, :sandbox_reset_pending} =
             Conversations.update_sandbox(ctx.home, %{status: "suspended"})

    Repo.update_all(from(s in Conversations.Sandbox, where: s.id == ^ctx.home.id),
      set: [updated_at: DateTime.add(DateTime.utc_now(), -172_800, :second)]
    )

    assert {0, 0} = Fountain.Workers.SandboxReaper.sweep_abandoned_sandboxes()
    assert Fountain.Quotas.active_sandbox_count(ctx.user.id) == 1
    assert Repo.reload!(ctx.home).status == "ready"
    refute Enum.any?(Fountain.Audit.list_for_user(ctx.user.id), &(&1.action == "sandbox.reset"))
  end

  describe "an unconfirmed reset is fenced, not a dead end" do
    setup ctx do
      expect(Managoat.Sandbox.Sprites, :destroy, fn _ -> {:error, :timeout} end)
      assert {:error, :sandbox_reset_pending} = Conversations.reset_sandbox(ctx.home)
      :ok
    end

    test "an operator reaps the row, which releases the slot", ctx do
      assert {:ok, :released} = Conversations._unsafe_reap_sandbox(ctx.home.id)
      assert Repo.reload!(ctx.home).status == "terminated"
      assert Fountain.Quotas.active_sandbox_count(ctx.user.id) == 0
    end

    test "deleting the agent still retires its home", ctx do
      stub(Managoat.Sandbox.Sprites, :destroy, fn _ -> :ok end)
      assert {:ok, _} = Fountain.Agents.delete_agent(ctx.agent, actor: "ui")
      assert Repo.reload!(ctx.home).status == "terminated"
      assert Fountain.Quotas.active_sandbox_count(ctx.user.id) == 0
    end

    test "a server that gives up can still mark the machine failed", ctx do
      assert {:ok, failed} = Conversations.update_sandbox(ctx.home, %{status: "failed"})
      assert failed.status == "failed"
      assert Fountain.Quotas.active_sandbox_count(ctx.user.id) == 0
    end

    test "a park is skipped rather than raised, and takes no checkpoint", ctx do
      reject(Managoat.Sandbox.Sprites, :create_checkpoint, 2)

      assert :skipped = Fountain.Conversations.HomeCheckpoint.on_park(Repo.reload!(ctx.home))
      assert :ok = Fountain.Conversations.Lifecycle.park(ctx.a.id, ctx.home.id, nil, :idle)

      held = Repo.reload!(ctx.home)
      assert held.status == "ready"
      refute is_nil(held.reset_requested_at)
      assert Repo.reload!(ctx.a).status == "idle"
    end

    test "anything that would re-use the machine is still refused", ctx do
      assert {:error, :sandbox_reset_pending} = Conversations.reset_sandbox(ctx.home)
      assert {:error, :sandbox_reset_pending} = Conversations.wake_conversation(ctx.a.id)

      assert {:error, :sandbox_reset_pending} =
               Conversations.update_sandbox(ctx.home, %{status: "suspended"})

      assert Repo.reload!(ctx.home).status == "ready"
    end

    test "the request is on the trail even though the reset is not", ctx do
      actions =
        ctx.user.id
        |> Fountain.Audit.list_for_user()
        |> Enum.map(& &1.action)

      assert "sandbox.reset_requested" in actions
      refute "sandbox.reset" in actions

      assert [event] =
               ctx.user.id
               |> Fountain.Audit.list_for_user()
               |> Enum.filter(&(&1.action == "sandbox.reset_requested"))

      assert event.resource_id == ctx.home.id
      assert event.metadata["reason"] == "home_reset"
      assert event.metadata["conversations"] == 2
    end
  end

  test "a confirmed reset records both the request and the reset", ctx do
    stub(Managoat.Sandbox.Sprites, :destroy, fn _ -> :ok end)
    assert {:ok, %{status: "terminated"}} = Conversations.reset_sandbox(ctx.home)

    actions =
      ctx.user.id |> Fountain.Audit.list_for_user() |> Enum.map(& &1.action) |> Enum.sort()

    assert "sandbox.reset_requested" in actions
    assert "sandbox.reset" in actions
  end

  test "a sandbox that is still building is not resettable", ctx do
    reject(Managoat.Sandbox.Sprites, :destroy, 1)

    for status <- ["pending", "starting"] do
      ctx.home |> Ecto.Changeset.change(status: status) |> Repo.update!()

      assert {:error, {:sandbox_not_resettable, ^status}} = Conversations.reset_sandbox(ctx.home)
      refute Repo.reload!(ctx.home).reset_requested_at
    end
  end

  test "a parked reset holds capacity even through replacement exclusions", ctx do
    {:ok, home} = Conversations.update_sandbox(ctx.home, %{status: "suspended"})
    expect(Managoat.Sandbox.Sprites, :destroy, fn _ -> {:error, :timeout} end)
    assert {:error, :sandbox_reset_pending} = Conversations.reset_sandbox(home)
    assert Fountain.Quotas.active_sandbox_count(ctx.user.id, exclude: home.id) == 1
    assert Fountain.Quotas.active_sandbox_counts()[ctx.user.id] == 1
    assert Fountain.Quotas.fleet_count() == 1
  end

  test "a lost reset caller leaves the admission fence in place", ctx do
    expect(Managoat.Sandbox.Sprites, :destroy, fn _ -> raise "caller lost" end)
    assert_raise RuntimeError, "caller lost", fn -> Conversations.reset_sandbox(ctx.home) end
    assert {:error, :sandbox_reset_pending} = Conversations.reset_sandbox(ctx.home)

    assert {:error, :sandbox_unavailable} =
             Fountain.Conversations.Connection.open_autonomous_turn(
               ctx.a.id,
               ctx.user.id,
               ctx.home.id
             )
  end

  test "reset rechecks persisted mode instead of trusting the supplied struct", ctx do
    ctx.home |> Ecto.Changeset.change(mode: "ephemeral") |> Repo.update!()

    assert {:error, {:sandbox_not_resettable, "ephemeral"}} =
             Conversations.reset_sandbox(ctx.home)
  end

  test "the next prompt builds a fresh home on the same identity", ctx do
    stub(Managoat.Sandbox.Sprites, :destroy, fn _h -> :ok end)
    {:ok, _} = Conversations.reset_sandbox(ctx.home)

    assert {:ok, woken} = Conversations.wake_conversation(ctx.a.id)
    refute woken.sandbox_id == ctx.home.id
    fresh = Conversations._unsafe_get_sandbox!(woken.sandbox_id)
    assert fresh.mode == "persistent"
    assert fresh.agent_id == ctx.agent.id

    assert %{id: id} = Conversations._unsafe_find_home(ctx.user.id, ctx.agent.id, ctx.env.id, nil)
    assert id == woken.sandbox_id
    # The co-tenant followed onto the fresh home (#1067).
    assert Conversations._unsafe_get_conversation!(ctx.b.id).sandbox_id == woken.sandbox_id
  end

  for follows? <- [true, false] do
    @tag follows?: follows?
    test "a #{if follows?, do: "following", else: "stranded"} co-tenant is told which old sandbox was lost",
         ctx do
      unless ctx.follows? do
        other_env = insert_env(user_id: ctx.user.id)
        {:ok, _} = Conversations.update_conversation(ctx.b, %{environment_id: other_env.id})
      end

      stub(Managoat.Sandbox.Sprites, :destroy, fn _h -> :ok end)
      assert {:ok, _} = Conversations.reset_sandbox(ctx.home)
      owner = self()

      actor =
        spawn(fn ->
          {:ok, _} = Horde.Registry.register(Fountain.ConversationRegistry, ctx.b.id, nil)
          send(owner, {:registered, self()})

          receive do
            {:"$gen_cast", message} -> send(owner, {:cotenant_cast, message})
          end
        end)

      on_exit(fn -> if Process.alive?(actor), do: Process.exit(actor, :kill) end)
      assert_receive {:registered, ^actor}
      assert {:ok, ^actor} = ConversationServer.await_registered(ctx.b.id)
      assert {:ok, woken} = Conversations.wake_conversation(ctx.a.id)
      old_id = ctx.home.id
      expected_event = if(ctx.follows?, do: "replaced", else: "reset")

      assert_receive {:cotenant_cast,
                      {:machine_gone, ^old_id, ^expected_event, "sprite_gone", message}}

      assert is_binary(message)
      refute woken.sandbox_id == old_id

      assert Repo.reload!(ctx.b).sandbox_id ==
               if(ctx.follows?, do: woken.sandbox_id, else: old_id)
    end
  end

  # #1636: co-tenants normally share one identity, because attaching to a
  # machine requires the same agent, environment and vault. Rebinding a
  # teammate moves one conversation's environment while its co-tenants keep
  # theirs, and the replacement a wake builds carries only the waking
  # conversation's pair. Handing it to the other one would run it on another
  # binding's environment files and vault material, and would make the machine
  # depend on which conversation happened to wake first.
  describe "a co-tenant that declares a different identity" do
    setup ctx do
      other_env = insert_env(user_id: ctx.user.id)
      {:ok, b} = Conversations.update_conversation(ctx.b, %{environment_id: other_env.id})
      stub(Managoat.Sandbox.Sprites, :destroy, fn _h -> :ok end)
      {:ok, _} = Conversations.reset_sandbox(ctx.home)
      Map.merge(ctx, %{other_env: other_env, b: b})
    end

    test "waking the one that kept the identity leaves the rebound one behind", ctx do
      assert {:ok, woken_a} = Conversations.wake_conversation(ctx.a.id)
      refute woken_a.sandbox_id == ctx.home.id
      assert Conversations._unsafe_get_sandbox!(woken_a.sandbox_id).environment_id == ctx.env.id

      # It did not follow: it names something else, so it keeps the retired
      # row until its own wake.
      assert Conversations._unsafe_get_conversation!(ctx.b.id).sandbox_id == ctx.home.id

      assert {:ok, woken_b} = Conversations.wake_conversation(ctx.b.id)
      refute woken_b.sandbox_id == woken_a.sandbox_id

      assert Conversations._unsafe_get_sandbox!(woken_b.sandbox_id).environment_id ==
               ctx.other_env.id
    end

    test "waking the rebound one first does not pull the other onto its machine", ctx do
      assert {:ok, woken_b} = Conversations.wake_conversation(ctx.b.id)

      assert Conversations._unsafe_get_sandbox!(woken_b.sandbox_id).environment_id ==
               ctx.other_env.id

      assert Conversations._unsafe_get_conversation!(ctx.a.id).sandbox_id == ctx.home.id

      assert {:ok, woken_a} = Conversations.wake_conversation(ctx.a.id)
      refute woken_a.sandbox_id == woken_b.sandbox_id
      assert Conversations._unsafe_get_sandbox!(woken_a.sandbox_id).environment_id == ctx.env.id
    end

    test "the one left behind is told its machine is gone", ctx do
      assert {:ok, _} = Conversations.wake_conversation(ctx.a.id)

      messages =
        ctx.b.id
        |> Conversations._unsafe_list_log_events(0)
        |> Enum.filter(&(&1.kind == "stage" and &1.stage == "sandbox"))
        |> Enum.map(&Jason.decode!(&1.data)["message"])

      assert Enum.any?(messages, &(&1 =~ "different environment"))
    end
  end

  test "records sandbox.reset with the actor", ctx do
    stub(Managoat.Sandbox.Sprites, :destroy, fn _h -> :ok end)
    {:ok, _} = Conversations.reset_sandbox(ctx.home, actor: "api", request_ip: "10.0.0.1")

    assert [event] =
             Fountain.Audit.list_for_user(ctx.user.id)
             |> Enum.filter(&(&1.action == "sandbox.reset"))

    assert event.resource_id == ctx.home.id
    assert event.actor == "api"
    assert event.metadata["conversations"] == 2
    assert event.metadata["agent_id"] == ctx.agent.id
  end
end
