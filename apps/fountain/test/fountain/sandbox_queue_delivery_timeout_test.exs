defmodule Fountain.SandboxQueueDeliveryTimeoutTest do
  # The transport timeout is global application configuration.
  use Fountain.DataCase, async: false

  alias Fountain.Conversations.ConversationServer
  alias Fountain.SandboxQueue
  alias Fountain.SandboxQueue.Request

  setup do
    previous = Application.fetch_env(:fountain, :conversation_call_timeout_ms)
    Application.put_env(:fountain, :conversation_call_timeout_ms, 100)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:fountain, :conversation_call_timeout_ms, value)
        :error -> Application.delete_env(:fountain, :conversation_call_timeout_ms)
      end
    end)

    user = insert_active_user()
    agent = insert_agent(user_id: user.id)

    {:ok, request} =
      SandboxQueue.enqueue(%{
        user_id: user.id,
        agent_id: agent.id,
        kind: "start",
        attrs: %{
          "channel_id" => "waiting-channel",
          "prompt" => "run once",
          "client_request_id" => "work-1"
        }
      })

    conv = insert_conversation(user_id: user.id, agent: agent, channel_id: "waiting-channel")
    {:ok, user: user, conv: conv, request: request}
  end

  test "a timeout records unknown delivery and never retries a call that can run late", ctx do
    observer = self()

    server =
      start_supervised!({Task,
       fn ->
         {:ok, _} = Horde.Registry.register(Fountain.ConversationRegistry, ctx.conv.id, nil)
         # Like provisioning, this leaves calls waiting in the server's mailbox.
         receive do
           :unblock -> accept_prompts(observer, 0)
         end
       end})

    assert {:ok, ^server} = ConversationServer.await_registered(ctx.conv.id, 2_000)

    assert %{started: 0, failed: 1, expired: 0} = SandboxQueue.drain(ctx.user.id)
    request = Repo.get!(Request, ctx.request.id)
    assert request.status == "failed"
    assert request.error == "prompt_delivery_unknown"
    assert request.conversation_id == ctx.conv.id
    assert request.attrs == %{}
    refute_received {:delivered, _, _, _}

    # A timeout does not remove the original call. Let it execute and finish
    # before another drain, so a busy turn cannot hide a duplicate delivery.
    send(server, :unblock)
    assert_receive {:delivered, 1, "run once", [client_request_id: "work-1"]}
    assert GenServer.call(server, :delivered_count) == 1

    assert %{started: 0, failed: 0, expired: 0} = SandboxQueue.drain(ctx.user.id)
    assert GenServer.call(server, :delivered_count) == 1
    refute_received {:delivered, 2, _, _}
  end

  @tag capture_log: true
  test "distribution loss after receipt records unknown delivery instead of recovering the claim",
       ctx do
    observer = self()

    server =
      start_supervised!(
        Supervisor.child_spec(
          {Task,
           fn ->
             {:ok, _} = Horde.Registry.register(Fountain.ConversationRegistry, ctx.conv.id, nil)

             receive do
               {:"$gen_call", _from, {:send_prompt, prompt, _images, meta}} ->
                 send(observer, {:delivered, 1, prompt, meta})
                 Horde.Registry.unregister(Fountain.ConversationRegistry, ctx.conv.id)
                 # Model the monitor exit from distribution loss after receipt.
                 # This exercises the real call transport, not a live partition.
                 exit({:nodedown, :disconnected@fountain})
             end
           end},
          id: :disconnected_server
        )
      )

    assert {:ok, ^server} = ConversationServer.await_registered(ctx.conv.id, 2_000)

    assert %{started: 0, failed: 1, expired: 0} = SandboxQueue.drain(ctx.user.id)
    assert_receive {:delivered, 1, "run once", [client_request_id: "work-1"]}
    request = Repo.get!(Request, ctx.request.id)
    assert request.status == "failed"
    assert request.error == "prompt_delivery_unknown"
    assert request.conversation_id == ctx.conv.id
    assert request.attrs == %{}

    successor =
      start_supervised!(
        {Task,
         fn ->
           {:ok, _} = Horde.Registry.register(Fountain.ConversationRegistry, ctx.conv.id, nil)
           accept_prompts(observer, 1)
         end}
      )

    assert {:ok, ^successor} = ConversationServer.await_registered(ctx.conv.id, 2_000)

    # A disconnected call must not leave an abandoned claim that can replay
    # the accepted work once the five-minute recovery window elapses.
    Repo.update_all(from(r in Request, where: r.id == ^request.id),
      set: [updated_at: DateTime.add(DateTime.utc_now(), -10, :minute)]
    )

    assert %{started: 0, failed: 0, expired: 0} = SandboxQueue.drain(ctx.user.id)
    assert GenServer.call(successor, :delivered_count) == 1
    refute_received {:delivered, 2, _, _}
  end

  test "an explicit provisioning refusal still retries safely", ctx do
    observer = self()

    server =
      start_supervised!(
        {Task,
         fn ->
           {:ok, _} = Horde.Registry.register(Fountain.ConversationRegistry, ctx.conv.id, nil)

           receive do
             {:"$gen_call", from, {:send_prompt, _, _, _}} ->
               GenServer.reply(from, {:error, :provisioning})
               accept_prompts(observer, 0)
           end
         end}
      )

    assert {:ok, ^server} = ConversationServer.await_registered(ctx.conv.id, 2_000)

    assert %{started: 0, failed: 0, expired: 0} = SandboxQueue.drain(ctx.user.id)
    assert Repo.get!(Request, ctx.request.id).attrs == ctx.request.attrs
    assert Repo.get!(Request, ctx.request.id).status == "queued"
    assert GenServer.call(server, :delivered_count) == 0

    assert %{started: 1, failed: 0, expired: 0} = SandboxQueue.drain(ctx.user.id)
    assert_receive {:delivered, 1, "run once", [client_request_id: "work-1"]}
  end

  defp accept_prompts(observer, count) do
    receive do
      {:"$gen_call", from, {:send_prompt, prompt, _images, meta}} ->
        send(observer, {:delivered, count + 1, prompt, meta})
        GenServer.reply(from, :ok)
        accept_prompts(observer, count + 1)

      {:"$gen_call", from, :delivered_count} ->
        GenServer.reply(from, count)
        accept_prompts(observer, count)
    end
  end
end
