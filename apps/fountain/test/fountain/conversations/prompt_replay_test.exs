defmodule Fountain.Conversations.PromptReplayTest do
  @moduledoc """
  A prompt must never reach the Horde child spec.

  `Horde.DynamicSupervisor` redistributes children when cluster membership
  changes — which every deploy does, as pods join and leave — and restarts each
  one from its **stored child spec**. `wake_conversation/2` used to bake the
  user's prompt into that spec as `initial_prompt`, so every rebalance replayed
  it against the agent.

  Production accumulated 38 turns from 2 distinct prompts on one conversation
  this way, one duplicate per rollout across four conversations, until the agent
  on the other end started replying "this is the sixth identical message" and
  refused to keep working.

  The test that matters is therefore about the **spec**, captured from the real
  code path, because the spec is the thing Horde stores and replays. An earlier
  version of this file restarted a server with hand-written args instead, which
  passed against the buggy code — the replay was never exercised, because the
  args under test were not the args Horde would have kept.
  """

  use Fountain.DataCase, async: false
  use Mimic

  alias Fountain.Conversations
  alias Fountain.Conversations.Launch
  alias Fountain.Conversations.Wake

  setup :set_mimic_global

  setup do
    user = insert_verified_user()
    agent = insert_agent(user_id: user.id)
    sandbox = insert_sandbox(user_id: user.id, status: "ready")
    conv = insert_conversation(user_id: user.id, agent: agent, sandbox: sandbox, status: "idle")

    stub(Managoat.Sandbox.Sprites.Client, :get!, fn -> :client end)
    stub(Sprites, :get_sprite, fn _client, _name -> {:ok, %{}} end)

    test = self()

    # Capture what would be handed to Horde, and do not actually start anything.
    stub(Horde.DynamicSupervisor, :start_child, fn _sup, spec ->
      send(test, {:child_spec, spec})
      pid = spawn(fn -> Process.sleep(:infinity) end)
      send(test, {:started_pid, pid})
      {:ok, pid}
    end)

    stub(Conversations.ConversationServer, :queue_initial_prompt, fn id, prompt, images ->
      send(test, {:queued_prompt, id, prompt, images})
      :ok
    end)

    stub(Conversations.ConversationServer, :queue_initial_prompt, fn id, prompt ->
      send(test, {:queued_prompt, id, prompt, []})
      :ok
    end)

    # Only a prompt with something travelling with it takes this arity (#1406).
    stub(Conversations.ConversationServer, :queue_initial_prompt, fn id, prompt, _images, meta ->
      send(test, {:queued_prompt_with, id, prompt, meta})
      :ok
    end)

    {:ok, conv: conv, agent: agent, user: user}
  end

  defp spec_args do
    assert_received {:child_spec, {_module, args}}
    args
  end

  describe "waking a conversation with a prompt" do
    test "puts no prompt in the child spec", %{conv: conv} do
      # The bug, in one assertion. Anything in here is replayed by Horde on
      # every redistribution, so a one-shot side effect must not be in it.
      {:ok, _} = Wake.wake_conversation(conv.id, "run the migration")

      args = spec_args()

      refute Keyword.has_key?(args, :initial_prompt),
             "the prompt is in the child spec and will be replayed on every deploy"

      refute args |> Keyword.values() |> Enum.any?(&(&1 == "run the migration"))
    end

    test "delivers the prompt out of band instead", %{conv: conv} do
      # It must still arrive — the fix is about how, not whether. And it goes
      # to the pid start_child returned, not through the registry: a cast to
      # a not-yet-propagated via-name is a silent no-op that eats the first
      # prompt (#367).
      {:ok, _} = Wake.wake_conversation(conv.id, "run the migration")

      assert_received {:started_pid, started_pid}
      assert_received {:queued_prompt, target, "run the migration", _}
      assert target == started_pid
    end

    # Through the real `Wake`, not its handoff helper alone: a handoff site
    # written the old way (`if is_binary(initial_prompt)`) would drop every
    # prompt that carries an id, text and all, and nothing else would go red.
    test "a prompt that carries an id is delivered with it, and neither is in the spec (#1406)",
         %{conv: conv} do
      {:ok, _} = Wake.wake_conversation(conv.id, {"run the migration", [client_request_id: "a"]})

      assert_received {:started_pid, started_pid}
      assert_received {:queued_prompt_with, target, "run the migration", [client_request_id: "a"]}
      assert target == started_pid
      refute_received {:queued_prompt, _, _, _}

      spec = inspect(spec_args(), limit: :infinity)
      refute spec =~ "run the migration"
      refute spec =~ "client_request_id"
    end

    test "waking without a prompt queues nothing", %{conv: conv} do
      # The rehydrator path. A boot must not send anything to the agent.
      {:ok, _} = Wake.wake_conversation(conv.id)

      refute_received {:queued_prompt, _, _, _}
    end

    test "the spec carries only what a restart legitimately needs", %{conv: conv} do
      {:ok, _} = Wake.wake_conversation(conv.id, "hello")

      assert Enum.sort(Keyword.keys(spec_args())) ==
               [:conversation_id, :runtime_module, :sandbox_id]
    end
  end

  describe "creating a conversation with an opening prompt" do
    test "puts no prompt in the child spec either", %{user: user, agent: agent} do
      # The other entry point. Fixing only the wake path would leave every
      # conversation created with an opening prompt still replaying it.
      {:ok, _conv} =
        Launch.start_conversation(%{
          "agent_id" => agent.id,
          "user_id" => user.id,
          "prompt" => "kick things off"
        })

      args = spec_args()

      refute Keyword.has_key?(args, :initial_prompt)
      assert_received {:queued_prompt, _id, "kick things off", _}
      refute_received {:queued_prompt_with, _, _, _}
    end

    test "sends the request's client_request_id with the prompt, not in the spec (#1406)", %{
      user: user,
      agent: agent
    } do
      {:ok, _conv} =
        Launch.start_conversation(%{
          "agent_id" => agent.id,
          "user_id" => user.id,
          "prompt" => "kick things off",
          "client_request_id" => "plan-7-step-1"
        })

      # A correlation in the stored spec would be replayed on every deploy,
      # exactly as the prompt was. `inspect` rather than the top-level values:
      # a nested `{prompt, opts}` or an `opts:` keyword would hide from those.
      args = spec_args()
      refute Keyword.has_key?(args, :initial_prompt)
      refute inspect(args, limit: :infinity) =~ "plan-7-step-1"

      assert_received {:queued_prompt_with, _id, "kick things off",
                       [client_request_id: "plan-7-step-1"]}
    end
  end
end
