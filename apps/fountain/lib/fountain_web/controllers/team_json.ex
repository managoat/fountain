defmodule FountainWeb.TeamJSON do
  @moduledoc false

  alias FountainWeb.{AgentJSON, ConversationJSON, TeamPresenter}

  def index(%{teammates: teammates}), do: %{data: Enum.map(teammates, &data/1)}
  def show(%{teammate: teammate}), do: %{data: data(teammate)}

  def conversations(%{conversations: convs, current_id: current_id}) do
    %{
      data:
        Enum.map(convs, fn conv ->
          conv |> ConversationJSON.data() |> Map.put(:current, conv.id == current_id)
        end)
    }
  end

  @doc "One roster entry: the agent, its current conversation, and what the roster line shows."
  def data(%{agent: agent, conversation: conv, last_turn: last_turn, name: name} = teammate) do
    %{
      agent_id: agent.id,
      name: name,
      agent: AgentJSON.data(agent),
      conversation: ConversationJSON.data(conv),
      presence: TeamPresenter.presence(conv),
      unread: Fountain.Conversations.unread?(conv),
      # Across every conversation the agent has had on the team (#827).
      usage_total: teammate.usage_total,
      last_turn: last_turn && turn_summary(last_turn),
      preview: preview(TeamPresenter.preview(teammate))
    }
  end

  defp turn_summary(turn) do
    %{
      id: turn.id,
      turn_number: turn.turn_number,
      prompt: turn.prompt,
      status: turn.status,
      inserted_at: turn.inserted_at,
      usage: ConversationJSON.turn_usage(turn.usage)
    }
  end

  defp preview(nil), do: nil
  defp preview(:typing), do: %{kind: "typing", text: nil}
  defp preview({:you, text}), do: %{kind: "you", text: text}
  defp preview({:them, text}), do: %{kind: "them", text: text}
end
