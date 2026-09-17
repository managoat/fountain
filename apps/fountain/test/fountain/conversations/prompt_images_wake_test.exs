defmodule Fountain.Conversations.PromptImagesWakeTest do
  use Fountain.DataCase, async: true
  use Mimic

  alias Fountain.Audit
  alias Fountain.Conversations
  alias Fountain.Conversations.ConversationServer

  # `send_prompt/4` has two roads to the turn, and images used to travel down
  # only one of them (#2373). A live server took `{:send_prompt, prompt,
  # images}`; a conversation with no server was woken, and the wake delivered
  # the text with `queue_initial_prompt/2`'s default `[]`. The request answered
  # `200 {"status":"queued"}` either way, and `conversation.prompted` recorded
  # the real `image_count`, so the trail said images were sent and the turn had
  # none. Nothing reported the loss.
  #
  # The wake road is the one under test here. The live road is covered where
  # the server's own prompt handling is
  # (`conversation_server_test.exs`); what was missing was any assertion that
  # the two roads agree.

  defp park(user) do
    agent = insert_agent(user_id: user.id)
    sandbox = insert_sandbox(user_id: user.id, machine_name: "sprite-2373")
    {:ok, sandbox} = Conversations.update_sandbox(sandbox, %{status: "ready"})

    insert_conversation(user_id: user.id, agent: agent, sandbox: sandbox, status: "idle")
  end

  # The sprite is still alive, so the wake reuses the sandbox rather than
  # provisioning: the shortest of the four handoff sites, and the one a parked
  # conversation actually takes. `start_child` hands back a bare process so no
  # real `ConversationServer` runs under the shared Horde supervisor in an
  # async test, exactly as `conversations_wake_test.exs` does it.
  defp stub_wake(server) do
    stub(Managoat.Sandbox.Sprites, :get, fn _handle ->
      {:ok, %{status: :running, raw: %{name: "sprite-2373"}}}
    end)

    stub(Horde.DynamicSupervisor, :start_child, fn _supervisor, _child_spec -> {:ok, server} end)

    test_pid = self()

    stub(ConversationServer, :queue_initial_prompt, fn pid, prompt, images ->
      send(test_pid, {:queued, pid, prompt, images})
      :ok
    end)

    # Both arities, reporting what each one carries. Stubbing only `/3` would
    # make this file fail on `main` because the call arity changed there, not
    # because anything was lost — the mailbox would simply be empty, and the
    # same empty mailbox is what a wake that never delivered at all produces.
    # With `/2` reporting the `[]` it defaults to, `main` delivers a message
    # and the assertion fails on the images that are missing from it.
    stub(ConversationServer, :queue_initial_prompt, fn pid, prompt ->
      send(test_pid, {:queued, pid, prompt, []})
      :ok
    end)
  end

  describe "send_prompt/4 with no live server" do
    setup do
      user = insert_verified_user()
      server = spawn(fn -> Process.sleep(:infinity) end)
      stub_wake(server)

      {:ok, conv: park(user), server: server, user: user}
    end

    test "the woken conversation's first turn gets the prompt's images", ctx do
      # The decoded shape `FountainWeb.PromptImages.decode/1` produces, which
      # is what the controller hands `send_prompt/4`.
      images = [
        %{media_type: "image/png", data: "not-really-a-png"},
        %{media_type: "image/jpeg", data: "nor-is-this"}
      ]

      assert :ok = ConversationServer.send_prompt(ctx.conv.id, "what is in these?", images)

      assert_receive {:queued, server, "what is in these?", ^images}
      assert server == ctx.server
    end

    test "a prompt with no images still hands over an empty list", ctx do
      assert :ok = ConversationServer.send_prompt(ctx.conv.id, "no pictures", [])

      assert_receive {:queued, _server, "no pictures", []}
    end

    test "the audit row's image_count matches what the turn was handed", ctx do
      # The half of #2373 that made the loss invisible: the trail counted the
      # images the request carried whether or not they reached the turn.
      images = [%{media_type: "image/png", data: "one"}]

      assert :ok =
               ConversationServer.send_prompt(ctx.conv.id, "count me", images, actor: "api_key")

      assert_receive {:queued, _server, "count me", handed_over}

      event =
        ctx.user.id
        |> Audit.list_recent_for_user(200)
        |> Enum.find(&(&1.action == "conversation.prompted"))

      assert event, "sending a prompt must be audited"
      assert event.metadata["image_count"] == 1
      assert event.metadata["image_count"] == length(handed_over)
    end
  end
end
