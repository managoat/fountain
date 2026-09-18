defmodule Fountain.Conversations.MachineEvents do
  @moduledoc false

  import Ecto.Query

  alias Fountain.Conversations
  alias Fountain.Conversations.ConversationServer
  alias Fountain.Conversations.Output
  alias Fountain.Repo

  # A reset fence admitted no running turn, and forbids another on that
  # machine. A notification must never interrupt a later turn. The conditional
  # write also rechecks the persisted binding if a wake races this mailbox.
  #
  # The cast is the evidence of a reset (ADR 0058 stage 9b). Only the reset's
  # completion sends `{:sandbox_reset, ...}` (`Conversations.record_reset_completed/3`),
  # so the write asks only that the machine is terminated. Until 9b it also
  # asked for `reset_requested_at`, which never told a reset from a teardown —
  # the teardown fence set it too — and which 9b stopped reading. A late notice
  # that arrives after a *later* teardown of the same machine could still bring
  # a conversation back to `idle`, as it could with the column: an accepted
  # residual, not a regression.
  def reset(
        %{sandbox_id: sandbox_id, current_turn: nil, turn_execution: nil} = state,
        sandbox_id,
        reason,
        by,
        message,
        drop
      ) do
    {matched, _} =
      Repo.update_all(
        from(c in Conversations.Conversation,
          join: s in Conversations.Sandbox,
          on: s.id == c.sandbox_id,
          where:
            c.id == ^state.conversation_id and c.user_id == ^state.user_id and
              c.sandbox_id == ^sandbox_id and c.status in ["idle", "running"] and
              s.status == "terminated"
        ),
        set: [status: "idle", updated_at: DateTime.utc_now() |> DateTime.truncate(:second)]
      )

    if matched == 1 do
      Phoenix.PubSub.broadcast(
        Fountain.PubSub,
        "sidebar:#{state.user_id}",
        {:sidebar_update, state.user_id}
      )

      # No provider/connection operation occurs while the row is locked.
      state = drop.(state, "reset")

      Output.publish_stage(state.conversation_id, "sandbox", "done", %{
        event: "reset",
        reason: reason,
        by: by,
        message: message
      })

      {:stop, :normal, %{state | handle: nil}}
    else
      {:noreply, state}
    end
  end

  def reset(state, _sandbox_id, _reason, _by, _message, _drop), do: {:noreply, state}

  # Handle a notification for this actor's sandbox; ignore another sandbox's.
  # The server supplies its connection/turn teardown callbacks. Keeping the
  # transcript handling here leaves the actor's mailbox clauses small.
  #
  # Cleanup runs before the guarded context transition, outside its
  # transaction. A moved or terminal conversation, or a newer running turn,
  # emits no sandbox event. A moved one can still be released: this is the
  # backstop `_unsafe_idle_interrupted_turn/1` names, so the write that idles a
  # parent stranded `running` with no running turn survives the rebind, while
  # the transcript event does not. The obsolete actor still stops after
  # cleanup, because its handle is already gone with the machine.
  def gone(
        %{sandbox_id: sandbox_id} = state,
        sandbox_id,
        {event, reason, message},
        interrupt,
        drop
      )
      when is_binary(sandbox_id) do
    state = if state.current_turn, do: interrupt.(state), else: state
    state = drop.(state, event)

    # Ownership: the actor supplies the sandbox whose local handle it closed.
    case Conversations._unsafe_finish_machine_gone(state.conversation_id, sandbox_id) do
      :ok ->
        Output.publish_stage(state.conversation_id, "sandbox", "done", %{
          event: event,
          reason: reason,
          by: "another_conversation",
          message: message
        })

      :noop ->
        :ok
    end

    {:stop, :normal, %{state | handle: nil}}
  end

  def gone(state, _sandbox_id, _notification, _interrupt, _drop), do: {:noreply, state}

  @doc """
  The one sender of the `{:machine_gone, ..}` cast that `reset/6` and `gone/5`
  above receive. A park, a destroy or a replaced machine is a machine
  operation: every other conversation on the sandbox loses its handle with
  it. Tell their servers, so each records what happened on its own transcript
  and stops — the next prompt then takes the wake path, the only path that
  brings the machine back. A cast: a co-tenant whose server is already gone
  (including a cross-pod registry miss) is not an error here.
  """
  @spec tell_cotenants([String.t()], String.t() | nil, String.t(), String.t(), String.t()) ::
          :ok
  def tell_cotenants(ids, sandbox_id, event, reason, message) do
    Enum.each(ids, fn id ->
      case ConversationServer.whereis(id) do
        nil -> :ok
        pid -> GenServer.cast(pid, {:machine_gone, sandbox_id, event, reason, message})
      end
    end)
  end
end
