defmodule Fountain.Conversations.DeadlineEvents do
  @moduledoc """
  Records deadline outcomes in the same transaction as the failed turn.

  A retryable local notification shares that transaction. The persisted log id
  is the deduplication identity for streams. Notifications may repeat; the
  terminal log event is inserted only once under the execution journal lock. No actor or provider call participates.

  **The atomicity here is deliberate, and it is the exception to the usual
  rule.** Elsewhere a recording is best-effort precisely so that a failed insert
  cannot take its mutation down (ADR 0013). Here it is the opposite: a turn that
  is durably failed while nothing was ever told is the bug this module exists to
  prevent, so `Conversations.log!/1` and `Oban.insert!/1` both raise inside the
  caller's transaction and *should* roll the turn write back. The caller retries; the alternative is a silent
  disagreement between the journal and every reader of it.

  `_unsafe_record!/2` is the one thing that does not raise: it returns `nil`
  when the ownership recheck fails, because a conversation that changed hands is
  not this deadline's to publish on. That path is logged rather than silent.
  """

  require Logger

  alias Fountain.{Conversations, Repo}
  alias Fountain.Conversations.Conversation
  alias Fountain.Workers.TurnDeadlineNotification

  @doc "System journal writer; requires its parent, execution and turn locks."
  def _unsafe_record!(execution, turn) do
    # ownership: recheck the journal's original tenant on the locked parent.
    owner = Repo.get_by(Conversation, id: execution.conversation_id, user_id: execution.user_id)

    if is_nil(owner) or turn.conversation_id != owner.id do
      Logger.warning(
        "deadline outcome for turn #{turn.id} not recorded: conversation " <>
          "#{execution.conversation_id} no longer belongs to #{execution.user_id}"
      )

      nil
    else
      event =
        Conversations.log!(%{
          conversation_id: owner.id,
          turn_id: turn.id,
          kind: "stage",
          stage: "turn",
          state: "failed",
          data:
            Jason.encode!(%{
              turn_id: turn.id,
              turn_number: turn.turn_number,
              limit_reason: "wall_time_limit",
              stop_reason: "wall_time_limit"
            })
        })

      %{"event_id" => event.id, "conversation_id" => owner.id, "user_id" => owner.user_id}
      |> TurnDeadlineNotification.new()
      |> Oban.insert!()

      event.id
    end
  end
end
