defmodule Fountain.Conversations.SessionConfigServerTest do
  @moduledoc """
  ADR 0062 through a real `ConversationServer` and a real `Managoat.ACP.Peer`:
  the agent's session config, as the conversation launched with it, reaches
  the adapter after the model and before the prompt, every turn on a reused
  connection requests the same options, and a refusal fails the turn before it
  prompts.
  """

  use Fountain.ConversationServerCase

  import Fountain.ConversationServerCase.ACP

  alias Fountain.Conversations.PromptDelivery

  setup do
    stub(Managoat.Sandbox.Sprites, :destroy, fn _handle -> :ok end)
    user = insert_verified_user()
    env = insert_env(user_id: user.id)

    agent =
      insert_agent(
        user_id: user.id,
        environment_id: env.id,
        runtime: "claude",
        session_config: %{"effort" => "high", "fast" => false}
      )

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

    {:ok, conv: conv}
  end

  defp effort(current),
    do: %{
      "id" => "effort",
      "category" => "thought_level",
      "type" => "select",
      "currentValue" => current,
      "options" => Enum.map(~w(low medium high max), &%{"value" => &1, "name" => &1})
    }

  defp config_stages(conv_id) do
    for event <- Conversations._unsafe_list_log_events(conv_id),
        event.kind == "stage" and event.stage == "config",
        do: {event.state, Jason.decode!(event.data)}
  end

  @mode %{"id" => "mode", "category" => "mode", "type" => "select", "currentValue" => "default"}

  test "the agent's options are applied after the model and before the prompt; " <>
         "the next turn requests the same and mode is never offered",
       %{conv: conv} do
    stub_happy_sprite()
    ref = stub_acp_transport()
    {pid, _mon, :alive} = start_server(conv, initial_prompt: "first")
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    %{"id" => init_id, "method" => "initialize", "params" => init} = next_write(5_000)
    assert init["clientCapabilities"]["session"]["configOptions"]["boolean"] == %{}

    reply(pid, ref, init_id, %{
      "agentCapabilities" => %{"loadSession" => true, "sessionCapabilities" => %{"resume" => %{}}}
    })

    %{"id" => new_id, "method" => "session/new"} = next_write()

    # No `fast` on this model: requested by the agent, skipped here.
    reply(pid, ref, new_id, %{
      "sessionId" => "sess_1",
      "models" => %{},
      "configOptions" => [@mode, effort("medium")]
    })

    %{"id" => model_id, "method" => "session/set_model"} = next_write()
    reply(pid, ref, model_id, %{})

    assert %{
             "id" => set_id,
             "method" => "session/set_config_option",
             "params" => %{"configId" => "effort", "value" => "high"}
           } = next_write()

    reply(pid, ref, set_id, %{"configOptions" => [@mode, effort("high")]})

    %{"id" => prompt_id, "method" => "session/prompt"} = next_write()
    settle(pid)

    [turn] = Conversations._unsafe_list_turns(conv.id)

    assert turn.config_selection == %{
             "requested" => %{"effort" => "high", "fast" => false},
             "applied" => %{"effort" => "high"},
             "skipped" => ["fast"]
           }

    assert Repo.reload!(conv).session_config_options == [effort("high")]

    assert [
             {"done", %{"outcome" => "applied", "id" => "effort", "confirmed" => "high"}},
             {"done", %{"outcome" => "skipped", "id" => "fast"}}
           ] = config_stages(conv.id)

    reply(pid, ref, prompt_id, %{"stopReason" => "end_turn"})
    settle(pid)

    # The next prompt, on the connection already open: the model is pinned
    # again, and the options, already in force, need no round trip.
    assert :ok = GenServer.call(pid, PromptDelivery.call(pid, "second", [], []))
    %{"id" => model_id, "method" => "session/set_model"} = next_write()
    reply(pid, ref, model_id, %{})
    %{"method" => "session/prompt"} = next_write()
    settle(pid)

    [_first, second] = Conversations._unsafe_list_turns(conv.id)
    assert second.config_selection["requested"] == %{"effort" => "high", "fast" => false}
    refute Map.has_key?(second.config_selection, "restored")
  end

  test "a value the adapter refuses fails the turn before it prompts", %{conv: conv} do
    stub_happy_sprite()
    ref = stub_acp_transport()
    {pid, _mon, :alive} = start_server(conv, initial_prompt: "first")
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    %{"id" => init_id, "method" => "initialize"} = next_write(5_000)
    reply(pid, ref, init_id, %{"agentCapabilities" => %{"loadSession" => true}})
    %{"id" => new_id, "method" => "session/new"} = next_write()

    reply(pid, ref, new_id, %{
      "sessionId" => "sess_1",
      "models" => %{},
      "configOptions" => [effort("medium")]
    })

    %{"id" => model_id, "method" => "session/set_model"} = next_write()
    reply(pid, ref, model_id, %{})

    assert %{
             "id" => set_id,
             "method" => "session/set_config_option",
             "params" => %{"configId" => "effort", "value" => "high"}
           } = next_write()

    line =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => set_id,
        "error" => %{"code" => -32_602, "message" => "Invalid value for config option effort"}
      }) <> "\n"

    send(pid, {:stdout, %{ref: ref}, line})
    settle(pid)

    refute_receive {:wrote, _}, 100

    [turn] = Conversations._unsafe_list_turns(conv.id)
    assert turn.status == "failed"
    assert turn.config_selection["requested"] == %{"effort" => "high", "fast" => false}
    assert turn.config_selection["status"] == "failed"
    assert turn.config_selection["error"] =~ "Invalid value for config option effort"
    assert turn.config_selection["error"] =~ "the agent's session_config"
  end
end
