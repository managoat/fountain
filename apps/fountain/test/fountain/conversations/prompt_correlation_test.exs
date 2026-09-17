defmodule Fountain.Conversations.PromptCorrelationTest do
  @moduledoc """
  A prompt's `client_request_id` arrives on the turn it opens (#1406), down
  every road a prompt takes to a turn: the call a live server answers, the cast
  that follows a wake, and the continuation a prompt is parked on when it loses
  the race to a reapply. And it arrives on nobody else's turn.
  """

  use Fountain.ConversationServerCase

  import Fountain.ConversationServerCase.ACP

  alias Fountain.Environments
  alias Fountain.Conversations.{ConversationServer, PromptDelivery, Reapply, Redaction, Wake}

  setup do
    stub(Managoat.Sandbox.Sprites, :destroy, fn _handle -> :ok end)
    user = insert_verified_user()
    env = insert_env(user_id: user.id)
    agent = insert_agent(user_id: user.id, environment_id: env.id, runtime: "claude")

    sandbox =
      insert_sandbox(
        user_id: user.id,
        status: "pending",
        agent_id: agent.id,
        environment_id: env.id
      )

    conv =
      insert_conversation(
        user_id: user.id,
        agent: agent,
        runtime: "claude",
        sandbox_id: sandbox.id,
        status: "pending"
      )

    {:ok, user: user, env: env, conv: conv}
  end

  defp start_with_turn(conv, opts \\ []) do
    stub_happy_sprite()
    ref = stub_acp_transport()
    {pid, _mon, :alive} = start_server(conv, [initial_prompt: "first"] ++ opts)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    {pid, ref, drive_to_prompt(pid, ref)}
  end

  # Stage events persist their metadata as JSON in `data`.
  defp started_events(conv_id) do
    for event <- Conversations._unsafe_list_log_events(conv_id),
        event.kind == "stage" and event.stage == "turn" and event.state == "started",
        do: Jason.decode!(event.data)
  end

  describe "a live server" do
    test "stores the id on the turn the prompt opens, and on no other", %{conv: conv} do
      {pid, ref, prompt_id} = start_with_turn(conv)
      reply(pid, ref, prompt_id, %{"stopReason" => "end_turn"})

      assert :ok =
               GenServer.call(pid, PromptDelivery.call(pid, "second", [], client_request_id: "b"))

      assert [first, second] = Conversations._unsafe_list_turns(conv.id)
      assert is_nil(first.client_request_id)
      assert second.client_request_id == "b"
      assert second.prompt == "second"
    end

    test "the started event binds the id to the turn id", %{conv: conv} do
      {pid, ref, prompt_id} = start_with_turn(conv)
      reply(pid, ref, prompt_id, %{"stopReason" => "end_turn"})

      assert :ok =
               GenServer.call(pid, PromptDelivery.call(pid, "second", [], client_request_id: "b"))

      # The second turn reuses the connection, and a reused connection says
      # `started` once the peer has taken the prompt.
      %{"method" => "session/set_model", "id" => set_id} = next_write()
      reply(pid, ref, set_id, %{})
      assert %{"method" => "session/prompt"} = next_write()
      settle(pid)

      assert [_first, second] = Conversations._unsafe_list_turns(conv.id)
      assert [plain, correlated] = started_events(conv.id)

      # A prompt that carried nothing leaves the event in the shape it had.
      refute Map.has_key?(plain, "client_request_id")
      assert correlated["client_request_id"] == "b"
      assert correlated["turn_id"] == second.id
    end

    # `log!/1` redacts every event's data against the conversation's registered
    # environment values, and an id is part of that data. An ordinary plain
    # value — `NODE_ENV=production` — is over the length floor, so the id
    # `production-build-7` reaches its event as `[REDACTED]-build-7`, which is
    # also a legal id another client can send. The event cannot tell them
    # apart. The turn can: it is written by the changeset, not by `log!/1`.
    test "the event's copy of an id can be redacted; the turn's is literal", %{conv: conv} do
      Redaction.put(conv.id, [{"NODE_ENV", "production"}])
      on_exit(fn -> Redaction.delete(conv.id) end)

      collides = "[REDACTED]-build-7"

      {pid, ref, prompt_id} =
        start_with_turn(conv, prompt_opts: [client_request_id: "production-build-7"])

      reply(pid, ref, prompt_id, %{"stopReason" => "end_turn"})

      assert :ok =
               GenServer.call(
                 pid,
                 PromptDelivery.call(pid, "second", [], client_request_id: collides)
               )

      %{"method" => "session/set_model", "id" => set_id} = next_write()
      reply(pid, ref, set_id, %{})
      assert %{"method" => "session/prompt"} = next_write()
      settle(pid)

      # Two different clients, one string: binding on the event alone picks
      # the wrong turn, and no timeout protects against a match that arrives.
      assert [first_event, second_event] = started_events(conv.id)
      assert first_event["client_request_id"] == collides
      assert second_event["client_request_id"] == collides

      # The turns are what the two clients sent, and they differ.
      assert [first, second] = Conversations._unsafe_list_turns(conv.id)
      assert first.client_request_id == "production-build-7"
      assert second.client_request_id == collides
      assert first_event["turn_id"] == first.id
      assert second_event["turn_id"] == second.id
    end

    test "a refused prompt leaves its id on nothing", %{conv: conv} do
      {pid, _ref, _prompt_id} = start_with_turn(conv)

      assert {:error, :busy} =
               GenServer.call(pid, PromptDelivery.call(pid, "second", [], client_request_id: "b"))

      assert [only] = Conversations._unsafe_list_turns(conv.id)
      assert is_nil(only.client_request_id)
    end

    # The issue's case on a live server: two clients submit at the same moment.
    # This is not a race the test has to win. The server's mailbox puts the two
    # calls in some order and the first opens the turn, so the second is always
    # `:busy`; which client is first is the part nobody controls, and sequence
    # inference cannot tell a client which it was. The id can: the turn carries
    # the accepted caller's, and the refused caller's is on nothing.
    test "two clients at once: the turn names the one the server took first",
         %{conv: conv} do
      {pid, ref, prompt_id} = start_with_turn(conv)
      reply(pid, ref, prompt_id, %{"stopReason" => "end_turn"})

      results =
        ["salon-a", "salon-b"]
        |> Enum.map(fn id ->
          Task.async(fn ->
            {id,
             GenServer.call(
               pid,
               PromptDelivery.call(pid, "from #{id}", [], client_request_id: id)
             )}
          end)
        end)
        |> Task.await_many()

      assert [{accepted, :ok}] = Enum.filter(results, &match?({_, :ok}, &1))
      assert [{refused, {:error, :busy}}] = Enum.reject(results, &match?({_, :ok}, &1))

      assert [_first, second] = Conversations._unsafe_list_turns(conv.id)
      assert second.client_request_id == accepted
      assert second.prompt == "from #{accepted}"

      refute Enum.any?(
               Conversations._unsafe_list_turns(conv.id),
               &(&1.client_request_id == refused)
             )
    end

    test "a prompt with nothing to carry is the message every release understands" do
      me = self()
      assert {:send_prompt, "hi", []} = PromptDelivery.call(me, "hi", [], actor: "api")
      assert {:send_prompt, "hi", []} = PromptDelivery.call(me, "hi", [], client_request_id: nil)
      assert {:initial_prompt, "hi", []} = PromptDelivery.cast(me, "hi", [], [])

      assert {:send_prompt, "hi", [], [client_request_id: "a"]} =
               PromptDelivery.call(me, "hi", [], actor: "api", client_request_id: "a")
    end

    # Horde can place the server on a pod of the previous release, whose
    # catch-all clauses answer a four-element call `:unknown_call` and drop a
    # four-element cast. The prompt has to run there, so the id stays behind.
    test "a server on a node that predates the field gets the prompt without the id" do
      me = self()
      predates = fn _node -> false end
      carrying = [client_request_id: "a"]

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:send_prompt, "the secret plan", []} =
                   PromptDelivery.call(me, "the secret plan", [], carrying, predates)

          assert {:initial_prompt, "the secret plan", []} =
                   PromptDelivery.cast(me, "the secret plan", [], carrying, predates)
        end)

      assert log =~ "predates client_request_id"
      # The prompt is the tenant's content (#545): the warning names the node.
      refute log =~ "the secret plan"

      # This node has the module, and a node that cannot be asked reads as no.
      assert PromptDelivery.understands?(node())
      refute PromptDelivery.understands?(:"nobody@nowhere.invalid")
    end

    # The API refuses these with 422. A caller that is not the API must not be
    # able to fail turn admission, and so drop a live connection, over a label.
    test "an id the turn would refuse does not travel" do
      too_long = String.duplicate("x", Conversations.Turn.client_request_id_max() + 1)
      # PostgreSQL raises 22021 on this one from inside the insert, rather than
      # refusing the changeset, so it must not get as far as turn admission.
      with_nul = "plan-7" <> <<0>> <> "step-3"

      for bad <- ["", too_long, 42, nil, with_nul] do
        assert PromptDelivery.travelling(client_request_id: bad) == []
        assert PromptDelivery.for_wake("hi", client_request_id: bad) == "hi"
      end

      longest = String.duplicate("x", Conversations.Turn.client_request_id_max())
      assert PromptDelivery.travelling(client_request_id: longest) == [client_request_id: longest]
    end
  end

  describe "a woken conversation" do
    test "the cast that follows provisioning carries the id to turn one", %{conv: conv} do
      {_pid, _ref, _prompt_id} = start_with_turn(conv, prompt_opts: [client_request_id: "a"])

      assert [turn] = Conversations._unsafe_list_turns(conv.id)
      assert turn.client_request_id == "a"
      assert [%{"client_request_id" => "a", "turn_id" => turn_id}] = started_events(conv.id)
      assert turn_id == turn.id
    end

    # The same two clients, on a conversation that had to be woken. Both were
    # answered `queued` before a turn existed, and both prompts arrive as casts.
    # The second finds a user turn running and is dropped with nobody told, so
    # the id is the only way either client learns whose prompt ran.
    test "two prompts cast at a waking server: one turn, carrying the first one's id",
         %{conv: conv} do
      {pid, _ref, _prompt_id} = start_with_turn(conv, prompt_opts: [client_request_id: "a"])

      ExUnit.CaptureLog.capture_log(fn ->
        ConversationServer.queue_initial_prompt(pid, "second", [], client_request_id: "b")
        settle(pid)
      end)

      assert [turn] = Conversations._unsafe_list_turns(conv.id)
      assert turn.client_request_id == "a"
      assert [%{"client_request_id" => "a"}] = started_events(conv.id)
    end

    test "send_prompt hands the wake the id with the text", %{conv: conv} do
      test = self()

      # Arity three since #2373: the images travel this road beside the prompt.
      stub(Wake, :wake_conversation, fn id, prompt, images ->
        send(test, {:woke, id, prompt, images})
        {:ok, conv}
      end)

      images = [%{data: "iVBOR", media_type: "image/png"}]

      assert :ok =
               ConversationServer.send_prompt(conv.id, "hi", images, client_request_id: "a")

      assert_received {:woke, id, {"hi", [client_request_id: "a"]}, ^images}
      assert id == conv.id

      # Nothing to carry: the bare text, which is what Wake always took.
      assert :ok = ConversationServer.send_prompt(conv.id, "hi", [], actor: "api")
      assert_received {:woke, _, "hi", []}
    end

    test "the wake hands its prompt to whichever server owns the conversation" do
      # The images travel this road too (#2373), whether or not a correlation
      # travels with them.
      images = [%{data: "iVBOR", media_type: "image/png"}]

      assert :ok = PromptDelivery.hand_over(self(), {"hi", [client_request_id: "a"]}, images)

      assert_received {:"$gen_cast", {:initial_prompt, "hi", ^images, [client_request_id: "a"]}}

      assert :ok = PromptDelivery.hand_over(self(), "hi", images)
      assert_received {:"$gen_cast", {:initial_prompt, "hi", ^images}}

      # A wake for an interrupt carries no prompt, and an empty one is none.
      assert :ok = PromptDelivery.hand_over(self(), nil, [])
      assert :ok = PromptDelivery.hand_over(self(), "", [])
      assert :ok = PromptDelivery.hand_over(self(), {"", [client_request_id: "a"]}, images)
      refute_received {:"$gen_cast", _}
    end
  end

  test "a prompt parked behind a reapply keeps its id", %{conv: conv, env: env} do
    stub_happy_sprite()
    {pid, _, :alive} = start_server(conv)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    # The harness server is outside the registry, so a reapply can commit
    # without any notification reaching it (#1565): the next prompt finds its
    # revision stale, is not opened, and is delivered after the rebuild.
    {:ok, conv} = Conversations.update_conversation(conv, %{status: "idle"})
    {:ok, _} = Environments.update_environment(env, %{env_vars: %{"MARKER" => "fresh"}})

    Mimic.stub(Managoat.Sandbox.Sprites, :spawn, fn _, _, _, _ ->
      {:error, {:unavailable, :test_finished}}
    end)

    assert {:ok, updated} = Reapply.reapply_conversation(conv, %{})

    assert :ok =
             GenServer.call(
               pid,
               PromptDelivery.call(pid, "after reapply", [], client_request_id: "r")
             )

    assert :sys.get_state(pid).configuration_revision == updated.configuration_revision
    assert [turn] = Conversations._unsafe_list_turns(conv.id)
    assert turn.client_request_id == "r"
  end

  test "the row refuses an id longer than the API allows" do
    too_long = String.duplicate("x", Conversations.Turn.client_request_id_max() + 1)

    changeset =
      Conversations.Turn.changeset(%Conversations.Turn{}, %{
        conversation_id: Ecto.UUID.generate(),
        turn_number: 1,
        prompt: "hi",
        status: "running",
        client_request_id: too_long
      })

    assert %{client_request_id: [_]} = errors_on(changeset)
  end

  # Two ids the API accepts, and the round trip the caller is promised for
  # them: the response echoes the id, so the turn and its started event have to
  # carry that same id or the caller cannot find its work.
  describe "an id the API accepts survives the round trip" do
    # Ecto trims a string before it decides the value is empty, so an id of
    # spaces used to reach the turn as `nil` while the response echoed it.
    test "an id of spaces is stored as it was sent", %{conv: conv} do
      {_pid, _ref, _prompt_id} = start_with_turn(conv, prompt_opts: [client_request_id: " "])

      assert [turn] = Conversations._unsafe_list_turns(conv.id)
      assert turn.client_request_id == " "
      assert [%{"client_request_id" => " "}] = started_events(conv.id)
    end

    # The bound is 200 graphemes at the door, in `PromptDelivery.travelling/1`
    # and in the changeset. A grapheme is several PostgreSQL characters here:
    # this id is 200 of them and 400 of those, which `varchar(255)` refused
    # from inside turn admission, after the caller had been told `queued`.
    test "an id of 200 combining graphemes fits the column", %{conv: conv} do
      id = String.duplicate("e\u0301", Conversations.Turn.client_request_id_max())
      assert String.length(id) == Conversations.Turn.client_request_id_max()
      assert byte_size(id) > 255

      {_pid, _ref, _prompt_id} = start_with_turn(conv, prompt_opts: [client_request_id: id])

      assert [turn] = Conversations._unsafe_list_turns(conv.id)
      assert turn.client_request_id == id
      assert [%{"client_request_id" => ^id}] = started_events(conv.id)
    end

    # The one character no id may carry. PostgreSQL rejects U+0000 in a text
    # column with 22021, raised from inside an insert nothing rescues, so the
    # row has to refuse it as an ordinary validation error instead.
    test "an id carrying NUL is a changeset error, not a raise" do
      changeset =
        Conversations.Turn.changeset(%Conversations.Turn{}, %{
          conversation_id: Ecto.UUID.generate(),
          turn_number: 1,
          prompt: "hello",
          status: "running",
          client_request_id: "plan-7" <> <<0>> <> "step-3"
        })

      assert %{client_request_id: [_]} = errors_on(changeset)
    end

    # The door refuses the same id with 422, and it does it with a pattern
    # rather than this function. Two statements of one rule, pinned together.
    test "the door's pattern and the row agree about NUL" do
      pattern = Regex.compile!(Conversations.Turn.client_request_id_pattern())

      for id <- ["plan-7", " ", "\t\n", String.duplicate("é", 200)] do
        assert Regex.match?(pattern, id)
        refute Conversations.Turn.has_nul?(id)
      end

      for id <- [<<0>>, "a" <> <<0>>, <<0>> <> "a", "a" <> <<0>> <> "\n"] do
        refute Regex.match?(pattern, id)
        assert Conversations.Turn.has_nul?(id)
      end
    end

    # The one string that still reads as "the caller sent none", so that a
    # caller which is not the API cannot fail turn admission with it.
    test "an empty id is none, and opens the turn without one" do
      changeset =
        Conversations.Turn.changeset(%Conversations.Turn{}, %{
          conversation_id: Ecto.UUID.generate(),
          turn_number: 1,
          prompt: "hi",
          status: "running",
          client_request_id: ""
        })

      assert changeset.valid?
      assert is_nil(Ecto.Changeset.get_field(changeset, :client_request_id))
    end
  end
end
