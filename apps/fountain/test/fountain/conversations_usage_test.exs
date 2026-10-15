defmodule Fountain.ConversationsUsageTest do
  @moduledoc """
  What the console's dashboard reports (#871): tokens over a period, and the
  two conversation counts, both computed in the database.
  """
  use Fountain.DataCase, async: true

  alias Fountain.Conversations

  setup do
    user = insert_verified_user()
    other = insert_verified_user()
    {:ok, user: user, other: other}
  end

  defp turn_with_usage(conv, usage, at) do
    turn = insert_turn(conv)
    {:ok, _} = Conversations._unsafe_record_turn_usage(turn, usage)

    # inserted_at is set by the DB; move it to place the turn in a period.
    Fountain.Repo.update_all(
      from(t in Fountain.Conversations.Turn, where: t.id == ^turn.id),
      set: [inserted_at: at]
    )

    turn
  end

  describe "token_usage/3" do
    test "sums the turns inside the period, and only this tenant's", %{user: user, other: other} do
      conv = insert_conversation(user_id: user.id)
      theirs = insert_conversation(user_id: other.id)

      now = DateTime.utc_now() |> DateTime.truncate(:second)
      inside = DateTime.add(now, -3600, :second)
      outside = DateTime.add(now, -90 * 86_400, :second)

      turn_with_usage(conv, %{"input" => 100, "output" => 20}, inside)
      turn_with_usage(conv, %{"input" => 5, "output" => 1}, inside)
      turn_with_usage(conv, %{"input" => 9_000, "output" => 9_000}, outside)
      turn_with_usage(theirs, %{"input" => 7, "output" => 7}, inside)

      from = DateTime.add(now, -86_400, :second)

      assert Conversations.token_usage(user.id, from, now) ==
               %{input: 105, cache_read: 0, cache_write: 0, output: 21}
    end

    # The bug this metric shipped with: a coding agent re-reads its context
    # every turn, so nearly everything it consumes arrives as `cache_read`.
    # Prod's first month was 1.5k input against 41M cache_read — reporting
    # `input` alone as "what went in" was wrong by four orders of magnitude.
    test "counts the prompt cache, which is where nearly all the input is", %{user: user} do
      conv = insert_conversation(user_id: user.id)
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      at = DateTime.add(now, -60, :second)

      turn_with_usage(
        conv,
        %{
          "input" => 1_471,
          "cache_read" => 41_317_595,
          "cache_write" => 3_120_406,
          "output" => 545_912
        },
        at
      )

      usage = Conversations.token_usage(user.id, DateTime.add(now, -86_400, :second), now)

      assert usage == %{
               input: 1_471,
               cache_read: 41_317_595,
               cache_write: 3_120_406,
               output: 545_912
             }

      assert Conversations.total_input(usage) == 44_439_472
    end

    test "no turns, and turns that reported no usage, are zero not nil", %{user: user} do
      conv = insert_conversation(user_id: user.id)
      insert_turn(conv)
      now = DateTime.utc_now()
      from = DateTime.add(now, -86_400, :second)

      assert Conversations.token_usage(user.id, from, now) ==
               %{input: 0, cache_read: 0, cache_write: 0, output: 0}
    end

    test "a usage map missing a key contributes nothing for it", %{user: user} do
      conv = insert_conversation(user_id: user.id)
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      turn_with_usage(conv, %{"input" => 50}, DateTime.add(now, -60, :second))

      assert %{input: 50, cache_read: 0, cache_write: 0, output: 0} =
               Conversations.token_usage(user.id, DateTime.add(now, -86_400, :second), now)
    end

    # `usage` is whatever the runtime reported; nothing validates its shape on
    # the way in. A cast error here would take the dashboard down with it.
    test "a runtime that reported nonsense is skipped, not fatal", %{user: user} do
      conv = insert_conversation(user_id: user.id)
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      at = DateTime.add(now, -60, :second)

      turn_with_usage(conv, %{"input" => "lots", "output" => %{"nested" => 1}}, at)
      turn_with_usage(conv, %{"input" => 10, "output" => 2}, at)

      assert Conversations.token_usage(user.id, DateTime.add(now, -86_400, :second), now) ==
               %{input: 10, cache_read: 0, cache_write: 0, output: 2}
    end

    # The same nonsense, on the write side: it used to raise inside the
    # transaction, because the counters it increments are bigints.
    test "recording nonsense counts as nothing rather than raising", %{user: user} do
      conv = insert_conversation(user_id: user.id)
      turn = insert_turn(conv)

      assert {:ok, updated} =
               Conversations._unsafe_record_turn_usage(turn, %{
                 "input" => "lots",
                 "output" => -5
               })

      # Stored as it came — the trail is what the runtime said…
      assert updated.usage == %{"input" => "lots", "output" => -5}

      # …but nothing unusable reached the counters.
      reloaded = Conversations.get_conversation(conv.id, user.id)
      assert reloaded.usage_input_tokens == 0
      assert reloaded.usage_output_tokens == 0
    end
  end

  describe "conversation_counts/1" do
    test "counts the tenant's own, and which of them are live", %{user: user, other: other} do
      insert_conversation(user_id: user.id, status: "running")
      insert_conversation(user_id: user.id, status: "pending")
      insert_conversation(user_id: user.id, status: "idle")
      insert_conversation(user_id: user.id, status: "terminated")
      insert_conversation(user_id: other.id, status: "running")

      assert Conversations.conversation_counts(user.id) == %{total: 4, active: 2}
    end

    test "an account with nothing is zeroes, not nil", %{user: user} do
      assert Conversations.conversation_counts(user.id) == %{total: 0, active: 0}
    end
  end

  describe "activity_counts/3 (ADR 0079)" do
    test "counts turns in [from, to) and the conversations they belong to, this tenant's only",
         %{user: user, other: other} do
      a = insert_conversation(user_id: user.id)
      b = insert_conversation(user_id: user.id)
      quiet = insert_conversation(user_id: user.id)
      theirs = insert_conversation(user_id: other.id)

      now = DateTime.utc_now() |> DateTime.truncate(:second)
      inside = DateTime.add(now, -3600, :second)
      from = DateTime.add(now, -86_400, :second)

      turn_with_usage(a, %{"input" => 1}, inside)
      turn_with_usage(a, %{"input" => 1}, inside)
      turn_with_usage(b, %{"input" => 1}, inside)
      # On the upper bound, so outside the half-open period.
      turn_with_usage(quiet, %{"input" => 1}, now)
      turn_with_usage(quiet, %{"input" => 1}, DateTime.add(now, -90 * 86_400, :second))
      turn_with_usage(theirs, %{"input" => 1}, inside)

      assert Conversations.activity_counts(user.id, from, now) == %{conversations: 2, turns: 3}
    end

    test "an account with nothing is zeroes", %{user: user} do
      now = DateTime.utc_now()

      assert Conversations.activity_counts(user.id, DateTime.add(now, -60, :second), now) ==
               %{conversations: 0, turns: 0}
    end

    test "the admin form groups by account and leaves quiet accounts out",
         %{user: user, other: other} do
      quiet = insert_verified_user()
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      inside = DateTime.add(now, -3600, :second)

      turn_with_usage(insert_conversation(user_id: user.id), %{"input" => 1}, inside)
      turn_with_usage(insert_conversation(user_id: other.id), %{"input" => 1}, inside)
      turn_with_usage(insert_conversation(user_id: other.id), %{"input" => 1}, inside)

      counts =
        Conversations._unsafe_activity_counts_admin(
          [user.id, other.id, quiet.id],
          DateTime.add(now, -86_400, :second),
          DateTime.add(now, 1, :second)
        )

      assert counts == %{
               user.id => %{conversations: 1, turns: 1},
               other.id => %{conversations: 2, turns: 2}
             }

      assert Conversations._unsafe_activity_counts_admin([], now, now) == %{}
    end
  end
end
