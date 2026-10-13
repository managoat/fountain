defmodule Fountain.Workers.TeamSchedulerTest do
  use Fountain.DataCase, async: true
  use Mimic

  alias Fountain.Conversations.ConversationServer
  alias Fountain.Team
  alias Fountain.Team.{Schedule, Schedules}
  alias Fountain.Workers.{TeamScheduler, TeamScheduleRun}

  defp create!(user, agent, overrides \\ %{}) do
    attrs =
      Map.merge(
        %{"agent_id" => agent.id, "cron" => "0 9 * * *", "prompt" => "hi"},
        Map.new(overrides)
      )

    {:ok, s} = Schedules.create_schedule(user.id, attrs)
    s
  end

  defp make_due(schedule) do
    past = DateTime.utc_now() |> DateTime.add(-90, :second) |> DateTime.truncate(:second)
    {:ok, s} = schedule |> Schedule.run_changeset(%{next_run_at: past}) |> Repo.update()
    s
  end

  describe "TeamScheduler" do
    test "enqueues one run per due schedule and nothing for the rest" do
      user = insert_verified_user()
      ada = insert_agent(user_id: user.id)
      due = create!(user, ada) |> make_due()
      _later = create!(user, ada)

      assert :ok = perform_job(TeamScheduler, %{})

      assert [job] = all_enqueued(worker: TeamScheduleRun)
      assert job.args["schedule_id"] == due.id
      assert is_binary(job.args["fired_at"])

      # The claim advanced it, so a second tick is quiet.
      assert :ok = perform_job(TeamScheduler, %{})
      assert length(all_enqueued(worker: TeamScheduleRun)) == 1
    end
  end

  describe "TeamScheduleRun" do
    test "runs the schedule as the system" do
      user = insert_verified_user()
      ada = insert_agent(user_id: user.id)

      conv =
        insert_conversation(
          user_id: user.id,
          agent: ada,
          status: "idle",
          channel_id: Team.channel()
        )

      s = create!(user, ada)
      test_pid = self()

      stub(ConversationServer, :send_prompt, fn id, _text, _images, opts ->
        send(test_pid, {:sent, id, opts[:actor]})
        :ok
      end)

      fired_at = DateTime.utc_now() |> DateTime.to_iso8601()

      assert :ok = perform_job(TeamScheduleRun, %{"schedule_id" => s.id, "fired_at" => fired_at})
      conv_id = conv.id
      assert_received {:sent, ^conv_id, "system:team_scheduler"}
    end

    test "snoozes on a busy teammate, gives up once the firing is stale" do
      user = insert_verified_user()
      ada = insert_agent(user_id: user.id)

      insert_conversation(
        user_id: user.id,
        agent: ada,
        status: "running",
        channel_id: Team.channel()
      )

      s = create!(user, ada)
      stub(ConversationServer, :send_prompt, fn _, _, _, _ -> {:error, :busy} end)

      fresh = DateTime.utc_now() |> DateTime.to_iso8601()

      assert {:snooze, 30} =
               perform_job(TeamScheduleRun, %{"schedule_id" => s.id, "fired_at" => fresh})

      stale = DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.to_iso8601()
      assert :ok = perform_job(TeamScheduleRun, %{"schedule_id" => s.id, "fired_at" => stale})
      assert Schedules.get_schedule(s.id, user.id).last_error == "teammate was busy"
    end

    test "snoozes on a machine its owner is mid-operation on" do
      # ADR 0058 stage 6a: a machine mid-operation is a wait, not a failure.
      user = insert_verified_user()
      ada = insert_agent(user_id: user.id)

      insert_conversation(
        user_id: user.id,
        agent: ada,
        status: "idle",
        channel_id: Team.channel()
      )

      s = create!(user, ada)
      stub(ConversationServer, :send_prompt, fn _, _, _, _ -> {:error, :sandbox_unavailable} end)

      fresh = DateTime.utc_now() |> DateTime.to_iso8601()

      assert {:snooze, 30} =
               perform_job(TeamScheduleRun, %{"schedule_id" => s.id, "fired_at" => fresh})

      stale = DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.to_iso8601()
      assert :ok = perform_job(TeamScheduleRun, %{"schedule_id" => s.id, "fired_at" => stale})

      assert Schedules.get_schedule(s.id, user.id).last_error ==
               "Fountain was working on the teammate's computer"
    end

    test "snoozes on every transient refusal, a full fleet among them" do
      # A cron firing has nobody there to retry it, so a refusal that clears by
      # itself is retried here rather than consumed. `:fleet_full` joined the
      # list when the sandbox queue that used to hold these firings went
      # (ADR 0042, as amended 2026-10-13).
      user = insert_verified_user()
      ada = insert_agent(user_id: user.id)

      insert_conversation(
        user_id: user.id,
        agent: ada,
        status: "idle",
        channel_id: Team.channel()
      )

      s = create!(user, ada)

      for reason <-
            ~w(busy provisioning runner_offline sandbox_at_capacity sandbox_unavailable
               sprite_probe_failed sandbox_resume_failed fleet_full)a do
        stub(ConversationServer, :send_prompt, fn _, _, _, _ -> {:error, reason} end)
        fresh = DateTime.utc_now() |> DateTime.to_iso8601()

        assert {:snooze, 30} =
                 perform_job(TeamScheduleRun, %{"schedule_id" => s.id, "fired_at" => fresh}),
               "a firing that met #{inspect(reason)} was consumed rather than retried"
      end

      assert Schedules.get_schedule(s.id, user.id).last_error == "sandbox fleet is full"
    end

    test "a deleted or paused schedule is a no-op" do
      user = insert_verified_user()
      ada = insert_agent(user_id: user.id)
      s = create!(user, ada)
      {:ok, s} = Schedules.update_schedule(s, %{"enabled" => false})
      stub(ConversationServer, :send_prompt, fn _, _, _, _ -> flunk("ran a paused schedule") end)

      fired_at = DateTime.utc_now() |> DateTime.to_iso8601()
      assert :ok = perform_job(TeamScheduleRun, %{"schedule_id" => s.id, "fired_at" => fired_at})

      assert :ok =
               perform_job(TeamScheduleRun, %{
                 "schedule_id" => Ecto.UUID.generate(),
                 "fired_at" => fired_at
               })
    end

    test "other errors are final for the firing and land on the row" do
      user = insert_verified_user()
      ada = insert_agent(user_id: user.id)
      s = create!(user, ada)

      fired_at = DateTime.utc_now() |> DateTime.to_iso8601()
      assert :ok = perform_job(TeamScheduleRun, %{"schedule_id" => s.id, "fired_at" => fired_at})
      assert Schedules.get_schedule(s.id, user.id).last_error == "agent is not on the team"
    end
  end
end
