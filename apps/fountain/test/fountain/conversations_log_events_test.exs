defmodule Fountain.ConversationsLogEventsTest do
  use Fountain.DataCase, async: true

  alias Fountain.Conversations
  alias Fountain.Conversations.{LogEvent, Sandbox}

  # Log events, output accounting and turn images.
  # Split out of the 2,215-line conversations_context_test.exs (#899): ExUnit
  # parallelises across modules, never within one, so that single module was a
  # 29.4s floor for whichever partition drew it.

  # Log events
  # ────────────────────────────────────────────────────────────────────────────

  describe "log!/1" do
    test "microseconds survive a database round trip (#1624)" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)

      for timestamp <- [~U[2026-09-06 01:30:46.094866Z], ~U[2026-09-06 01:30:46.987654Z]] do
        event =
          Conversations.log!(%{
            conversation_id: conv.id,
            kind: "output",
            stream: "stdout",
            data: "precision fixture",
            inserted_at: timestamp
          })

        # The inserted struct is what live PubSub broadcasts; history and
        # reconnect replay reload the row. Asserting only the struct missed
        # the timestamp(0) column behind the utc_datetime_usec schema.
        assert event.inserted_at == timestamp
        assert Fountain.Repo.reload!(event).inserted_at == timestamp
      end
    end

    test "inserts a LogEvent and returns the struct" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)

      attrs = %{
        conversation_id: conv.id,
        kind: "output",
        stream: "stdout",
        data: "hello",
        inserted_at: DateTime.utc_now()
      }

      event = Conversations.log!(attrs)
      assert %LogEvent{} = event
      assert is_integer(event.id)
      assert event.conversation_id == conv.id
      assert event.kind == "output"
      assert event.data == "hello"
    end

    test "defaults inserted_at to current time when not provided" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)

      attrs = %{
        conversation_id: conv.id,
        kind: "output"
      }

      before = DateTime.utc_now()
      event = Conversations.log!(attrs)
      after_time = DateTime.utc_now()

      assert DateTime.compare(event.inserted_at, before) in [:gt, :eq]
      assert DateTime.compare(event.inserted_at, after_time) in [:lt, :eq]
    end

    test "inserts a stage event" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)

      event =
        Conversations.log!(%{
          conversation_id: conv.id,
          kind: "stage",
          stage: "provision",
          state: "started",
          inserted_at: DateTime.utc_now()
        })

      assert event.kind == "stage"
      assert event.stage == "provision"
      assert event.state == "started"
    end
  end

  describe "_unsafe_list_log_events/3" do
    setup do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)
      %{user: user, conv: conv}
    end

    test "returns all events when no opts given", %{conv: conv} do
      e1 = insert_log_event(conv, kind: "output", stream: "stdout", data: "a")
      e2 = insert_log_event(conv, kind: "output", stream: "stderr", data: "b")
      e3 = insert_log_event(conv, kind: "stage", stream: "", stage: "provision")

      ids = Conversations._unsafe_list_log_events(conv.id) |> Enum.map(& &1.id)
      assert e1.id in ids
      assert e2.id in ids
      assert e3.id in ids
    end

    test "no filter with empty streams list returns all events", %{conv: conv} do
      e1 = insert_log_event(conv, kind: "output", stream: "stdout")
      e2 = insert_log_event(conv, kind: "stage", stream: "", stage: "provision")

      ids = Conversations._unsafe_list_log_events(conv.id, 0, streams: []) |> Enum.map(& &1.id)
      assert e1.id in ids
      assert e2.id in ids
    end

    test "streams: [\"stdout\"] returns only stdout events", %{conv: conv} do
      stdout = insert_log_event(conv, kind: "output", stream: "stdout", data: "out")
      stderr = insert_log_event(conv, kind: "output", stream: "stderr", data: "err")
      stage = insert_log_event(conv, kind: "stage", stream: "", stage: "provision")

      results = Conversations._unsafe_list_log_events(conv.id, 0, streams: ["stdout"])
      ids = Enum.map(results, & &1.id)
      assert stdout.id in ids
      refute stderr.id in ids
      refute stage.id in ids
    end

    test "streams: [\"stderr\"] returns only stderr events", %{conv: conv} do
      stdout = insert_log_event(conv, kind: "output", stream: "stdout")
      stderr = insert_log_event(conv, kind: "output", stream: "stderr")
      stage = insert_log_event(conv, kind: "stage", stream: "", stage: "provision")

      results = Conversations._unsafe_list_log_events(conv.id, 0, streams: ["stderr"])
      ids = Enum.map(results, & &1.id)
      refute stdout.id in ids
      assert stderr.id in ids
      refute stage.id in ids
    end

    test "streams: [\"stage\"] returns only stage kind events", %{conv: conv} do
      stdout = insert_log_event(conv, kind: "output", stream: "stdout")
      stderr = insert_log_event(conv, kind: "output", stream: "stderr")
      stage = insert_log_event(conv, kind: "stage", stream: "", stage: "provision")

      results = Conversations._unsafe_list_log_events(conv.id, 0, streams: ["stage"])
      ids = Enum.map(results, & &1.id)
      refute stdout.id in ids
      refute stderr.id in ids
      assert stage.id in ids
    end

    test ~s|streams: ["stdout", "stage"] returns stdout and stage events|, %{conv: conv} do
      stdout = insert_log_event(conv, kind: "output", stream: "stdout")
      stderr = insert_log_event(conv, kind: "output", stream: "stderr")
      stage = insert_log_event(conv, kind: "stage", stream: "", stage: "provision")

      results = Conversations._unsafe_list_log_events(conv.id, 0, streams: ["stdout", "stage"])
      ids = Enum.map(results, & &1.id)
      assert stdout.id in ids
      refute stderr.id in ids
      assert stage.id in ids
    end

    test "streams: [\"unknown\"] returns empty list (unknown stream filter)", %{conv: conv} do
      _e = insert_log_event(conv, kind: "output", stream: "stdout")

      assert Conversations._unsafe_list_log_events(conv.id, 0, streams: ["unknown"]) == []
    end

    test "after_id filters events with id greater than after_id", %{conv: conv} do
      e1 = insert_log_event(conv, kind: "output", stream: "stdout")
      e2 = insert_log_event(conv, kind: "output", stream: "stdout")
      e3 = insert_log_event(conv, kind: "output", stream: "stdout")

      ids = Conversations._unsafe_list_log_events(conv.id, e1.id) |> Enum.map(& &1.id)
      refute e1.id in ids
      assert e2.id in ids
      assert e3.id in ids
    end

    test "returns events ordered by id ascending", %{conv: conv} do
      e1 = insert_log_event(conv, kind: "output", stream: "stdout")
      e2 = insert_log_event(conv, kind: "output", stream: "stdout")
      e3 = insert_log_event(conv, kind: "output", stream: "stdout")

      ids = Conversations._unsafe_list_log_events(conv.id) |> Enum.map(& &1.id)
      assert ids == Enum.sort(ids)
      assert hd(ids) == e1.id
      assert List.last(ids) == e3.id
    end

    test "does not return events from other conversations", %{conv: conv} do
      user = insert_verified_user()
      other_conv = insert_conversation(user_id: user.id)
      _other = insert_log_event(other_conv, kind: "output", stream: "stdout")
      mine = insert_log_event(conv, kind: "output", stream: "stdout")

      results = Conversations._unsafe_list_log_events(conv.id)
      ids = Enum.map(results, & &1.id)
      assert ids == [mine.id]
    end
  end

  # ────────────────────────────────────────────────────────────────────────────
  # _unsafe_list_sandboxes_admin/0
  # ────────────────────────────────────────────────────────────────────────────

  describe "_unsafe_list_sandboxes_admin/0" do
    test "returns sandboxes with pending and ready statuses" do
      user = insert_verified_user()
      pending = insert_sandbox(user_id: user.id)
      ready = insert_sandbox(user_id: user.id)
      {:ok, _} = update_sandbox(ready, %{status: "ready"})

      ids = Conversations._unsafe_list_sandboxes_admin() |> Enum.map(& &1.id)
      assert pending.id in ids
      assert ready.id in ids
    end

    test "excludes sandboxes with terminated status" do
      user = insert_verified_user()
      sandbox = insert_sandbox(user_id: user.id)
      {:ok, _} = update_sandbox(sandbox, %{status: "terminated"})

      ids = Conversations._unsafe_list_sandboxes_admin() |> Enum.map(& &1.id)
      refute sandbox.id in ids
    end

    test "excludes sandboxes with failed status" do
      user = insert_verified_user()
      sandbox = insert_sandbox(user_id: user.id)
      {:ok, _} = update_sandbox(sandbox, %{status: "failed"})

      ids = Conversations._unsafe_list_sandboxes_admin() |> Enum.map(& &1.id)
      refute sandbox.id in ids
    end

    test "includes pending but not terminated when both exist" do
      user = insert_verified_user()
      active = insert_sandbox(user_id: user.id)
      terminated = insert_sandbox(user_id: user.id)
      {:ok, _} = update_sandbox(terminated, %{status: "terminated"})

      ids = Conversations._unsafe_list_sandboxes_admin() |> Enum.map(& &1.id)
      assert active.id in ids
      refute terminated.id in ids
    end

    test "preloads user association" do
      user = insert_verified_user()
      _sandbox = insert_sandbox(user_id: user.id)

      results = Conversations._unsafe_list_sandboxes_admin()
      assert results != []
      result = Enum.find(results, &(&1.user_id == user.id))
      assert result.user.id == user.id
    end

    test "preloads conversations association" do
      user = insert_verified_user()
      sandbox = insert_sandbox(user_id: user.id)
      _conv = insert_conversation(user_id: user.id, sandbox_id: sandbox.id)

      results = Conversations._unsafe_list_sandboxes_admin()
      result = Enum.find(results, &(&1.id == sandbox.id))
      assert is_list(result.conversations)
    end

    test "returns empty list when all sandboxes are in terminal states" do
      user = insert_verified_user()
      s1 = insert_sandbox(user_id: user.id)
      s2 = insert_sandbox(user_id: user.id)
      {:ok, _} = update_sandbox(s1, %{status: "terminated"})
      {:ok, _} = update_sandbox(s2, %{status: "failed"})

      # All sandboxes in this test's db partition are terminal
      results = Conversations._unsafe_list_sandboxes_admin()
      ids = Enum.map(results, & &1.id)
      refute s1.id in ids
      refute s2.id in ids
    end
  end

  # ────────────────────────────────────────────────────────────────────────────
  # _unsafe_list_resumable_conversations/0
  # ────────────────────────────────────────────────────────────────────────────

  describe "_unsafe_list_resumable_conversations/0" do
    test "returns idle conversation whose sandbox is ready" do
      user = insert_verified_user()
      sandbox = insert_sandbox(user_id: user.id)
      {:ok, _} = update_sandbox(sandbox, %{status: "ready"})
      conv = insert_conversation(user_id: user.id, status: "idle", sandbox_id: sandbox.id)

      ids = Conversations._unsafe_list_resumable_conversations() |> Enum.map(& &1.id)
      assert conv.id in ids
    end

    test "returns running conversation whose sandbox is ready" do
      user = insert_verified_user()
      sandbox = insert_sandbox(user_id: user.id)
      {:ok, _} = update_sandbox(sandbox, %{status: "ready"})
      conv = insert_conversation(user_id: user.id, status: "running", sandbox_id: sandbox.id)

      ids = Conversations._unsafe_list_resumable_conversations() |> Enum.map(& &1.id)
      assert conv.id in ids
    end

    test "excludes idle conversation whose sandbox is not ready (pending)" do
      user = insert_verified_user()
      sandbox = insert_sandbox(user_id: user.id)
      # sandbox remains "pending"
      conv = insert_conversation(user_id: user.id, status: "idle", sandbox_id: sandbox.id)

      ids = Conversations._unsafe_list_resumable_conversations() |> Enum.map(& &1.id)
      refute conv.id in ids
    end

    test "excludes terminated conversation even when sandbox is ready" do
      user = insert_verified_user()
      sandbox = insert_sandbox(user_id: user.id)
      {:ok, _} = update_sandbox(sandbox, %{status: "ready"})
      conv = insert_conversation(user_id: user.id, status: "terminated", sandbox_id: sandbox.id)

      ids = Conversations._unsafe_list_resumable_conversations() |> Enum.map(& &1.id)
      refute conv.id in ids
    end

    test "excludes a terminated conversation even when sandbox is ready" do
      # The sandbox being usable is not enough; the conversation has to be one
      # someone can still talk to. This used to be asserted with "completed",
      # a status nothing could produce, so it proved nothing.
      user = insert_verified_user()
      sandbox = insert_sandbox(user_id: user.id)
      {:ok, _} = update_sandbox(sandbox, %{status: "ready"})
      conv = insert_conversation(user_id: user.id, status: "terminated", sandbox_id: sandbox.id)

      ids = Conversations._unsafe_list_resumable_conversations() |> Enum.map(& &1.id)
      refute conv.id in ids
    end

    test "preloads sandbox association" do
      user = insert_verified_user()
      sandbox = insert_sandbox(user_id: user.id)
      {:ok, _} = update_sandbox(sandbox, %{status: "ready"})
      conv = insert_conversation(user_id: user.id, status: "idle", sandbox_id: sandbox.id)

      results = Conversations._unsafe_list_resumable_conversations()
      result = Enum.find(results, &(&1.id == conv.id))
      assert %Sandbox{} = result.sandbox
      assert result.sandbox.id == sandbox.id
    end

    test "returns empty list when no resumable conversations exist" do
      assert Conversations._unsafe_list_resumable_conversations() == []
    end
  end

  # ────────────────────────────────────────────────────────────────────────────
  # _unsafe_list_conversations_by_activity/0
  # ────────────────────────────────────────────────────────────────────────────

  # ────────────────────────────────────────────────────────────────────────────
  # _unsafe_insert_turn_images/2 and _unsafe_get_turn_image/2
  # ────────────────────────────────────────────────────────────────────────────

  # Helper to insert a TurnImage via changeset directly, for tests that need a
  # row without exercising _unsafe_insert_turn_images/2.
  defp insert_turn_image!(turn_id, position, media_type, data) do
    %Fountain.Conversations.TurnImage{}
    |> Fountain.Conversations.TurnImage.changeset(%{
      turn_id: turn_id,
      position: position,
      media_type: media_type,
      data: data
    })
    |> Ecto.Changeset.put_change(:inserted_at, DateTime.utc_now() |> DateTime.truncate(:second))
    |> Repo.insert!()
  end

  describe "_unsafe_insert_turn_images/2" do
    test "returns {:ok, 0} immediately when images list is empty" do
      assert {:ok, 0} = Conversations._unsafe_insert_turn_images(Ecto.UUID.generate(), [])
    end

    test "inserts images and returns count" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)
      turn = insert_turn(conv)
      images = [%{media_type: "image/png", data: <<1, 2, 3>>}]
      assert {:ok, 1} = Conversations._unsafe_insert_turn_images(turn.id, images)
    end

    test "positions are assigned in order" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)
      turn = insert_turn(conv)

      assert {:ok, 2} =
               Conversations._unsafe_insert_turn_images(turn.id, [
                 %{media_type: "image/png", data: <<1>>},
                 %{media_type: "image/jpeg", data: <<2>>}
               ])

      assert Conversations._unsafe_get_turn_image(turn.id, 0).media_type == "image/png"
      assert Conversations._unsafe_get_turn_image(turn.id, 1).media_type == "image/jpeg"
    end

    test "a disallowed media type is refused instead of stored" do
      # This used to go through Repo.insert_all against a raw table name, so the
      # schema's allowlist never ran and the schema described validation that
      # nothing performed.
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)
      turn = insert_turn(conv)

      assert {:error, changeset} =
               Conversations._unsafe_insert_turn_images(turn.id, [
                 %{media_type: "text/html", data: "<script>alert(1)</script>"}
               ])

      assert {"is invalid", _} = changeset.errors[:media_type]
      assert Conversations._unsafe_get_turn_image(turn.id, 0) == nil
    end

    test "an unknown turn is refused rather than orphaning a row" do
      assert {:error, changeset} =
               Conversations._unsafe_insert_turn_images(Ecto.UUID.generate(), [
                 %{media_type: "image/png", data: <<1>>}
               ])

      refute changeset.valid? and changeset.errors == []
    end
  end

  describe "_unsafe_get_turn_image/2" do
    test "returns the TurnImage when turn_id and position match" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)
      turn = insert_turn(conv)

      insert_turn_image!(turn.id, 0, "image/png", <<7, 8, 9>>)

      result = Conversations._unsafe_get_turn_image(turn.id, 0)
      assert result != nil
      assert result.turn_id == turn.id
      assert result.position == 0
      assert result.media_type == "image/png"
    end

    test "returns nil when no image exists at the given position" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)
      turn = insert_turn(conv)

      assert Conversations._unsafe_get_turn_image(turn.id, 99) == nil
    end

    test "returns nil when turn_id does not exist" do
      assert Conversations._unsafe_get_turn_image(Ecto.UUID.generate(), 0) == nil
    end

    test "returns nil when position belongs to a different turn" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)
      turn1 = insert_turn(conv)
      turn2 = insert_turn(conv)

      insert_turn_image!(turn1.id, 0, "image/png", <<1>>)

      # turn1 has an image at position 0, but turn2 does not
      assert Conversations._unsafe_get_turn_image(turn2.id, 0) == nil
    end
  end

  # ────────────────────────────────────────────────────────────────────────────
end
