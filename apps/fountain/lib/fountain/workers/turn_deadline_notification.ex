defmodule Fountain.Workers.TurnDeadlineNotification do
  @moduledoc """
  Delivers a persisted deadline stage independently of the conversation actor.

  This job notifies local subscribers and telemetry; retries reuse the same
  event id. Deleted transcripts or changed ownership suppress notification
  without touching the remote execution journal.
  """
  # Its own queue, not `:maintenance`, which is concurrency 1 behind eight
  # sweeps: a notification whose whole job is to be prompt must not queue behind
  # the retention pruner.
  #
  # Three attempts, not twenty. The event is already durable, so a retry only
  # re-pushes it to live SSE subscribers; a subscriber that missed the first
  # three is not helped by the twentieth, and reads the outcome from the
  # transcript when it reconnects.
  use Oban.Worker, queue: :notifications, max_attempts: 3

  import Ecto.Query

  require Logger

  alias Fountain.{Conversations, Repo}
  alias Fountain.Conversations.{Conversation, LogEvent}

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"event_id" => id, "conversation_id" => conv_id, "user_id" => user_id}
      }) do
    event =
      Repo.one(
        from e in LogEvent,
          join: c in Conversation,
          on: e.conversation_id == c.id,
          where: e.id == ^id and c.id == ^conv_id and c.user_id == ^user_id
      )

    if event do
      # ownership: the event query above scopes its conversation to the saved tenant.
      Conversations._unsafe_notify_stage(event)
    else
      # Deleted transcript, or a conversation that changed hands. Suppressing
      # the notification is right, but doing it silently is not: this is the
      # only place that knows a persisted deadline outcome reached nobody.
      Logger.warning(
        "deadline notification #{id} skipped: no event for conversation " <>
          "#{conv_id} under its saved tenant"
      )
    end

    :ok
  end
end
