defmodule Fountain.Conversations.ActorStatus do
  @moduledoc """
  Status reports from a conversation actor after external work returns.

  The actor's sandbox comes from its init arguments, never a refreshed parent.
  The binding predicate and status write share one SQL statement, so a wake
  that replaces the binding wins before or after the entire write. A stale
  report publishes no terminal stage against the replacement's transcript.
  Machine retirement remains the machine owner's separate responsibility.
  """

  import Ecto.Query

  alias Fountain.Conversations
  alias Fountain.Conversations.{Conversation, Output}
  alias Fountain.Repo

  @doc "Fail the actor's current binding and announce only an accepted failure."
  def fail(state, metadata) do
    with :ok <- write(state, "failed") do
      Output.publish_stage(state.conversation_id, "provision", "failed", metadata)
      :ok
    end
  end

  @doc "Record a successful session attach against the actor's current binding."
  def running(state), do: write(state, "running")

  defp write(%{conversation_id: conversation_id, sandbox_id: sandbox_id}, status)
       when is_binary(sandbox_id) do
    # Ownership: these are the actor's own init arguments (or its watchdog's),
    # not request input. Rechecking the binding in UPDATE also serializes with
    # the parent lock held by turn admission and termination.
    query =
      from c in Conversation,
        where: c.id == ^conversation_id and c.sandbox_id == ^sandbox_id,
        where: c.status not in ["terminated", "failed"],
        select: c.user_id

    case Repo.update_all(query, set: [status: status, updated_at: DateTime.utc_now()]) do
      {1, [user_id]} ->
        Conversations.broadcast_sidebar_update(user_id)
        :ok

      {0, []} ->
        :stale
    end
  end

  defp write(_state, _status), do: :stale
end
