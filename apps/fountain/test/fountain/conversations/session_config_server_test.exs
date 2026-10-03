defmodule Fountain.Conversations.SessionConfigServerTest do
  @moduledoc """
  ADR 0062 through a real `ConversationServer` and a real `Managoat.ACP.Peer`:
  the conversation's session config reaches the adapter after the model and
  before the prompt, a prompt's own options reach the next turn on the reused
  connection, and a refusal fails that turn before it prompts.
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
        session_config: %{"fast" => false}
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
        status: "pending",
        session_config: %{"effort" => "high"}
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

  test "the conversation's options are applied after the model and before the prompt; " <>
         "a prompt's apply to its turn alone",
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
      "configOptions" => [effort("medium")]
    })

    %{"id" => model_id, "method" => "session/set_model"} = next_write()
    reply(pid, ref, model_id, %{})

    assert %{
             "id" => set_id,
             "method" => "session/set_config_option",
             "params" => %{"configId" => "effort", "value" => "high"}
           } = next_write()

    reply(pid, ref, set_id, %{"configOptions" => [effort("high")]})

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

    # The next prompt names its own effort, on the connection already open.
    assert :ok =
             GenServer.call(
               pid,
               PromptDelivery.call(pid, "second", [], session_config: %{"effort" => "max"})
             )

    # The model is pinned again on every turn, then the options.
    %{"id" => model_id, "method" => "session/set_model"} = next_write()
    reply(pid, ref, model_id, %{})

    assert %{
             "id" => set_id,
             "method" => "session/set_config_option",
             "params" => %{"configId" => "effort", "value" => "max"}
           } = next_write()

    # The adapter refuses it: the turn fails and no prompt is written.
    line =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => set_id,
        "error" => %{"code" => -32_602, "message" => "Invalid value for config option effort"}
      }) <> "\n"

    send(pid, {:stdout, %{ref: ref}, line})
    settle(pid)

    refute_receive {:wrote, _}, 100

    [_first, second] = Conversations._unsafe_list_turns(conv.id)
    assert second.status == "failed"
    assert second.config_selection["requested"] == %{"effort" => "max", "fast" => false}
    assert second.config_selection["status"] == "failed"
    assert second.config_selection["error"] =~ "Invalid value for config option effort"
  end
end
