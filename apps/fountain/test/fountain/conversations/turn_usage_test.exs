defmodule Fountain.Conversations.TurnUsageTest do
  @moduledoc "`Conversations._unsafe_record_turn_usage/2` (#827): once per turn, summed on the conversation."
  use Fountain.DataCase, async: true

  alias Fountain.Conversations

  setup do
    user = insert_verified_user()
    conv = insert_conversation(user_id: user.id, agent: insert_agent(user_id: user.id))
    {:ok, user: user, conv: conv}
  end

  test "stamps the turn and adds to the conversation's running sums", %{conv: conv} do
    t1 = insert_turn(conv, prompt: "one", status: "completed")
    t2 = insert_turn(conv, prompt: "two", status: "completed", turn_number: 2)

    assert {:ok, %{usage: %{"input" => 100, "output" => 20}}} =
             Conversations._unsafe_record_turn_usage(t1, %{"input" => 100, "output" => 20})

    assert {:ok, _} =
             Conversations._unsafe_record_turn_usage(t2, %{
               "input" => 50,
               "output" => 5,
               "cache_read" => 40
             })

    conv = Conversations._unsafe_get_conversation!(conv.id)
    assert conv.usage_input_tokens == 150
    assert conv.usage_output_tokens == 25

    assert Conversations._unsafe_list_turns(conv.id) |> Enum.map(& &1.usage) == [
             %{"input" => 100, "output" => 20},
             %{"input" => 50, "output" => 5, "cache_read" => 40}
           ]
  end

  test "nil records nothing; a second figure for the same turn is refused", %{conv: conv} do
    t = insert_turn(conv, prompt: "one", status: "completed")
    assert :ok = Conversations._unsafe_record_turn_usage(t, nil)
    assert {:ok, t} = Conversations._unsafe_record_turn_usage(t, %{"input" => 1, "output" => 1})

    assert {:error, :already_recorded} =
             Conversations._unsafe_record_turn_usage(t, %{"input" => 1, "output" => 1})

    assert %{usage_input_tokens: 1, usage_output_tokens: 1} =
             Conversations._unsafe_get_conversation!(conv.id)
  end

  test "a delayed duplicate holding a stale turn struct is refused", %{conv: conv} do
    t = insert_turn(conv, prompt: "one", status: "completed")

    assert {:ok, _} =
             Conversations._unsafe_record_turn_usage(t, %{"input" => 100, "output" => 20})

    # `t` still carries usage: nil, so the unlocked clause lets this through and
    # only the locked re-read can refuse it — which is why the re-read exists.
    # Rebinding to the returned struct would route the second call into the
    # unlocked clause and test nothing.
    assert {:error, :already_recorded} =
             Conversations._unsafe_record_turn_usage(t, %{"input" => 100, "output" => 20})

    assert %{usage_input_tokens: 100, usage_output_tokens: 20} =
             Conversations._unsafe_get_conversation!(conv.id)
  end

  # Turns stamped before ADR 0075 stopped writing the stamp: one stamped
  # before an upgrade can still end after it.
  describe "over the turn-start inference stamp (#1685)" do
    test "the end-of-turn figure merges over the stamp instead of being refused", %{conv: conv} do
      t = insert_turn(conv, prompt: "one", status: "completed")

      {:ok, t} =
        Conversations._unsafe_update_turn(t, %{
          usage: %{"inference" => "platform", "model" => "anthropic/claude-opus-5"}
        })

      assert {:ok, recorded} =
               Conversations._unsafe_record_turn_usage(t, %{"input" => 100, "output" => 20})

      assert recorded.usage == %{
               "input" => 100,
               "output" => 20,
               "inference" => "platform",
               "model" => "anthropic/claude-opus-5"
             }

      # Counted once, not once per write.
      assert %{usage_input_tokens: 100, usage_output_tokens: 20} =
               Conversations._unsafe_get_conversation!(conv.id)

      assert {:error, :already_recorded} =
               Conversations._unsafe_record_turn_usage(recorded, %{"input" => 100, "output" => 20})
    end

    test "a duplicate holding the pre-figure stamped struct is refused", %{conv: conv} do
      t = insert_turn(conv, prompt: "one", status: "completed")
      stamp = %{"inference" => "platform", "model" => "anthropic/claude-opus-5"}
      {:ok, stamped} = Conversations._unsafe_update_turn(t, %{usage: stamp})

      assert {:ok, _} =
               Conversations._unsafe_record_turn_usage(stamped, %{"input" => 100, "output" => 20})

      # The only shape that reaches the locked read's refusal from a struct the
      # unlocked clause believes is stamp-only: it sees a stamp on `stamped`
      # and merges happily, and only the row read under the lock knows a real
      # figure already landed.
      assert {:error, :already_recorded} =
               Conversations._unsafe_record_turn_usage(stamped, %{"input" => 100, "output" => 20})

      assert %{usage_input_tokens: 100, usage_output_tokens: 20} =
               Conversations._unsafe_get_conversation!(conv.id)
    end

    test "an accounting-only map is an end-of-turn record, not a stamp", %{conv: conv} do
      t = insert_turn(conv, prompt: "one", status: "completed")
      accounting = %{"accounting" => %{"scope" => "session", "complete" => false}}

      assert {:ok, t} = Conversations._unsafe_record_turn_usage(t, accounting)

      assert {:error, :already_recorded} =
               Conversations._unsafe_record_turn_usage(t, %{"input" => 1, "output" => 1})
    end
  end
end
