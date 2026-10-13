defmodule Fountain.Team.SchedulesTest do
  use Fountain.DataCase, async: true
  use Mimic

  alias Fountain.{Audit, Conversations, Team}
  alias Fountain.Conversations.ConversationServer
  alias Fountain.Team.{Schedule, Schedules}

  # Ending a conversation whose server is gone now destroys its machine through
  # `Fountain.Machines.Machine` (ADR 0058 stage 5) rather than leaving the
  # sprite for the reaper, so these tests reach the provider where they did not
  # before. Nothing here is about the provider, so the adapter seam answers
  # yes. Stubbed at `Managoat.Sandbox.Sprites` rather than at the
  # `Managoat.Sandbox` facade so a test that drives either layer itself still
  # overrides it.
  setup do
    stub(Managoat.Sandbox.Sprites, :destroy, fn _handle -> :ok end)
    :ok
  end

  defp insert_teammate_conv(user, agent, overrides \\ %{}) do
    insert_conversation(
      Map.merge(
        %{user_id: user.id, agent: agent, status: "idle", channel_id: Team.channel()},
        Map.new(overrides)
      )
    )
  end

  defp inert_start_child do
    stub_server_start(fn _sup, _spec ->
      {:ok, spawn(fn -> Process.sleep(:infinity) end)}
    end)
  end

  defp schedule_events(user_id) do
    user_id
    |> Audit.list_recent_for_user()
    |> Enum.filter(&String.starts_with?(&1.action, "team.schedule."))
  end

  defp create!(user, agent, overrides \\ %{}) do
    attrs =
      Map.merge(
        %{"agent_id" => agent.id, "cron" => "0 9 * * *", "prompt" => "standup please"},
        Map.new(overrides)
      )

    {:ok, s} = Schedules.create_schedule(user.id, attrs)
    s
  end

  describe "create_schedule/3" do
    test "stores the schedule with a computed next run and records it" do
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id, name: "Ada")

      assert {:ok, %Schedule{} = s} =
               Schedules.create_schedule(user.id, %{
                 "agent_id" => agent.id,
                 "name" => "  Standup ",
                 "cron" => " 0 9 * * 1-5 ",
                 "prompt" => "What's on today?",
                 "one_off" => "true"
               })

      assert s.name == "Standup"
      assert s.cron == "0 9 * * 1-5"
      assert s.one_off
      assert s.enabled
      assert %DateTime{} = s.next_run_at
      assert DateTime.compare(s.next_run_at, DateTime.utc_now()) == :gt
      assert s.next_run_at.hour == 9 and s.next_run_at.minute == 0
      assert s.agent.id == agent.id

      assert [%{action: "team.schedule.created", metadata: meta}] = schedule_events(user.id)

      assert meta["cron"] == "0 9 * * 1-5"
      assert meta["one_off"] == true
      refute Map.has_key?(meta, "prompt")
    end

    test "rejects a bad cron, @reboot, and a blank prompt" do
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)

      assert {:error, cs} =
               Schedules.create_schedule(user.id, %{
                 "agent_id" => agent.id,
                 "cron" => "every day",
                 "prompt" => "x"
               })

      assert {_, _} = cs.errors[:cron]

      assert {:error, cs} =
               Schedules.create_schedule(user.id, %{
                 "agent_id" => agent.id,
                 "cron" => "@reboot",
                 "prompt" => "x"
               })

      assert {"@reboot is not a schedule", _} = cs.errors[:cron]

      assert {:error, cs} =
               Schedules.create_schedule(user.id, %{
                 "agent_id" => agent.id,
                 "cron" => "@daily",
                 "prompt" => ""
               })

      assert cs.errors[:prompt]
      assert schedule_events(user.id) == []
    end

    test "refuses another tenant's agent" do
      user = insert_verified_user()
      other = insert_verified_user()
      agent = insert_agent(user_id: other.id)

      assert {:error, :not_found} =
               Schedules.create_schedule(user.id, %{
                 "agent_id" => agent.id,
                 "cron" => "@daily",
                 "prompt" => "x"
               })
    end
  end

  describe "list/get" do
    test "tenant-scoped, and per teammate" do
      user = insert_verified_user()
      other = insert_verified_user()
      ada = insert_agent(user_id: user.id)
      linus = insert_agent(user_id: user.id)
      s1 = create!(user, ada)
      _s2 = create!(user, linus)
      _s3 = create!(other, insert_agent(user_id: other.id))

      assert length(Schedules.list_schedules(user.id)) == 2
      assert [%{id: id}] = Schedules.list_schedules(user.id, ada.id)
      assert id == s1.id
      assert Schedules.get_schedule(s1.id, user.id).id == s1.id
      assert Schedules.get_schedule(s1.id, other.id) == nil
    end
  end

  describe "update_schedule/3" do
    test "a new cron recomputes next_run_at and clears last_error; records the fields" do
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)
      s = create!(user, agent)

      {:ok, s} = s |> Schedule.run_changeset(%{last_error: "boom"}) |> Repo.update()

      assert {:ok, updated} = Schedules.update_schedule(s, %{"cron" => "30 14 * * *"})
      assert updated.next_run_at.hour == 14 and updated.next_run_at.minute == 30
      assert updated.last_error == nil

      assert [%{action: "team.schedule.updated", metadata: %{"changed" => changed}} | _] =
               schedule_events(user.id)

      assert "cron" in changed
    end

    test "a no-op update records nothing" do
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)
      s = create!(user, agent)
      before = length(schedule_events(user.id))

      assert {:ok, _} = Schedules.update_schedule(s, %{"cron" => s.cron})
      assert length(schedule_events(user.id)) == before
    end
  end

  describe "delete_schedule/2" do
    test "deletes and records" do
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)
      s = create!(user, agent)

      assert {:ok, _} = Schedules.delete_schedule(s)
      assert Schedules.get_schedule(s.id, user.id) == nil
      assert [%{action: "team.schedule.deleted"} | _] = schedule_events(user.id)
    end

    test "removing the teammate takes its schedules with it" do
      user = insert_verified_user()
      ada = insert_agent(user_id: user.id)
      linus = insert_agent(user_id: user.id)
      insert_teammate_conv(user, ada)
      insert_teammate_conv(user, linus)
      create!(user, ada)
      keep = create!(user, linus)

      :ok = Team.remove_teammate(user.id, ada.id)

      assert [%{id: id}] = Schedules.list_schedules(user.id)
      assert id == keep.id
    end
  end

  describe "run_schedule/2 — in the teammate's thread" do
    test "sends the prompt through the conversation server and stamps the row" do
      user = insert_verified_user()
      ada = insert_agent(user_id: user.id)
      conv = insert_teammate_conv(user, ada)
      s = create!(user, ada, %{"prompt" => "standup please"})
      test_pid = self()

      stub(ConversationServer, :send_prompt, fn id, text, images, opts ->
        send(test_pid, {:sent, id, text, images, opts[:actor]})
        :ok
      end)

      assert {:ok, %{id: conv_id}} = Schedules.run_schedule(s, actor: Schedules.actor())
      assert conv_id == conv.id
      assert_received {:sent, ^conv_id, "standup please", [], "system:team_scheduler"}

      s = Schedules.get_schedule(s.id, user.id)
      assert %DateTime{} = s.last_run_at
      assert s.last_conversation_id == conv.id
      assert s.last_error == nil

      assert Enum.any?(
               Audit.list_recent_for_user(user.id),
               &(&1.action == "team.schedule.fired" and &1.metadata["outcome"] == "ok" and
                   &1.actor == "system:team_scheduler")
             )
    end

    test "an error is returned unchanged and lands on the row" do
      user = insert_verified_user()
      ada = insert_agent(user_id: user.id)
      insert_teammate_conv(user, ada, status: "running")
      s = create!(user, ada)
      stub(ConversationServer, :send_prompt, fn _id, _text, _images, _opts -> {:error, :busy} end)

      assert {:error, :busy} = Schedules.run_schedule(s)

      s = Schedules.get_schedule(s.id, user.id)
      assert s.last_error == "teammate was busy"
      assert s.last_conversation_id == nil
    end

    test "an agent not on the team cannot be messaged in-thread" do
      user = insert_verified_user()
      ada = insert_agent(user_id: user.id)
      s = create!(user, ada)

      assert {:error, :not_found} = Schedules.run_schedule(s)
      assert Schedules.get_schedule(s.id, user.id).last_error == "agent is not on the team"
    end
  end

  describe "run_schedule/2 — on a one-off computer" do
    test "opens a fresh, unbound conversation with the teammate's environment and vault" do
      user = insert_verified_user()
      env = insert_env(user_id: user.id)
      vault = insert_vault(user_id: user.id)
      ada = insert_agent(user_id: user.id)
      team_conv = insert_teammate_conv(user, ada, environment_id: env.id, vault_id: vault.id)
      s = create!(user, ada, %{"one_off" => true, "prompt" => "nightly report"})
      inert_start_child()

      # The teammate's thread must not be touched.
      stub(ConversationServer, :send_prompt, fn _, _, _, _ -> flunk("in-thread send") end)

      assert {:ok, conv} = Schedules.run_schedule(s, actor: Schedules.actor())
      refute conv.id == team_conv.id
      assert conv.channel_id == nil
      assert conv.agent_id == ada.id
      assert conv.environment_id == env.id
      assert conv.vault_id == vault.id
      assert conv.source == "ui"

      # Still one teammate, still the same thread.
      assert [%{conversation: %{id: id}}] = Team.list_teammates(user.id)
      assert id == team_conv.id

      assert Schedules.get_schedule(s.id, user.id).last_conversation_id == conv.id
    end

    test "works off the team too, with the agent's own defaults" do
      user = insert_verified_user()
      ada = insert_agent(user_id: user.id)
      s = create!(user, ada, %{"one_off" => true})
      inert_start_child()

      assert {:ok, conv} = Schedules.run_schedule(s)
      assert conv.environment_id == nil and conv.vault_id == nil
      assert Team.list_teammates(user.id) == []
    end
  end

  describe "_unsafe_claim_due/1" do
    test "claims what is due, advances it, and skips the rest" do
      user = insert_verified_user()
      ada = insert_agent(user_id: user.id)
      due = create!(user, ada, %{"cron" => "0 9 * * *"})
      paused = create!(user, ada, %{"cron" => "0 9 * * *"})
      {:ok, paused} = Schedules.update_schedule(paused, %{"enabled" => false})
      later = create!(user, ada, %{"cron" => "0 9 * * *"})

      past = DateTime.utc_now() |> DateTime.add(-120, :second) |> DateTime.truncate(:second)

      for s <- [due, paused] do
        {:ok, _} = s |> Schedule.run_changeset(%{next_run_at: past}) |> Repo.update()
      end

      now = DateTime.utc_now()
      assert [%Schedule{id: id}] = Schedules._unsafe_claim_due(now)
      assert id == due.id

      advanced = Schedules.get_schedule(due.id, user.id)
      assert DateTime.compare(advanced.next_run_at, now) == :gt
      assert Schedules.get_schedule(later.id, user.id).next_run_at == later.next_run_at
      refute Schedules.get_schedule(paused.id, user.id).enabled

      # Claimed once: the same tick again finds nothing.
      assert Schedules._unsafe_claim_due(now) == []
    end
  end

  test "deleting the agent deletes the schedule" do
    user = insert_verified_user()
    ada = insert_agent(user_id: user.id)
    s = create!(user, ada)
    {:ok, _} = Fountain.Agents.delete_agent(ada)
    assert Schedules.get_schedule(s.id, user.id) == nil
  end

  test "Conversations still list the one-off runs" do
    # Sanity on the shape the UI links to: the run's conversation is an
    # ordinary row for the user.
    user = insert_verified_user()
    ada = insert_agent(user_id: user.id)
    s = create!(user, ada, %{"one_off" => true})
    inert_start_child()
    {:ok, conv} = Schedules.run_schedule(s)
    assert Conversations.get_conversation(conv.id, user.id)
  end

  test "a full fleet is described in words, not as an atom (#1126)" do
    assert Schedules.describe_error(:fleet_full) == "sandbox fleet is full"
  end

  # ADR 0060 decision 4. The catch-all would have stored `inspect/1` of the
  # tuple; the owner gets which subscription, what is wrong and what to do.
  test "a teammate whose set names an unusable ChatGPT subscription is told which and why" do
    detail = %{grant_id: Ecto.UUID.generate(), name: "Work", reason: :revoked, until: nil}
    described = Schedules.describe_error({:chatgpt_grant_unusable, detail})

    assert described == Fountain.InferenceCredentials.grant_unusable_message(detail)
    assert described =~ ~s(ChatGPT subscription "Work" is no longer accepted by OpenAI)
    # What survives `last_error`'s 250 characters is the actionable half.
    assert String.slice(described, 0, 250) =~ "Reconnect it"
  end

  test "a full fleet is described in words too (#1033)" do
    assert Schedules.describe_error(:fleet_full) == "sandbox fleet is full"
  end

  describe "run_schedule/2 at the fleet ceiling" do
    defp fired_events(user) do
      Fountain.Audit.list_recent_for_user(user.id, 50)
      |> Enum.filter(&(&1.action == "team.schedule.fired"))
    end

    test "the firing is refused, stamped and recorded; the worker retries it" do
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)
      schedule = create!(user, agent, %{"one_off" => true})
      fill_fleet()

      assert {:error, :fleet_full} = Schedules.run_schedule(schedule, actor: Schedules.actor())

      reloaded = Schedules.get_schedule(schedule.id, user.id)
      assert reloaded.last_error == "sandbox fleet is full"
      assert reloaded.last_run_at

      assert [event] = fired_events(user)
      assert event.metadata["outcome"] == "sandbox fleet is full"
    end
  end
end
