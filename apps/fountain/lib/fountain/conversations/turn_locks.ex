defmodule Fountain.Conversations.TurnLocks do
  @moduledoc """
  Parent-before-turn row locks for the writes that end a turn or change its
  conversation on the turn's behalf.

  Every function here takes `FOR UPDATE` on the conversation first and the
  turn second, the same order admission
  (`Conversations._unsafe_create_turn_on_sandbox/4`) uses, so an ending, a
  recovery and an admission serialize instead of interleaving. Callbacks run
  inside the transaction and must contain only database work.

  These are unscoped: callers are a conversation's own server or a system
  recovery path that already owns the turn it passes.

  This module used to be the unbounded half of ADR 0046's `ExecutionGuard`;
  the journal half was removed with that ADR (2026-10-13), and what remains is
  the locking every turn already relied on.
  """
  import Ecto.Query

  alias Fountain.Repo
  alias Fountain.Conversations.{Conversation, Turn}
  alias Fountain.Machines.Admission

  @terminal_turns ~w(completed failed interrupted)

  @doc """
  End an actor-owned turn under the parent and turn locks.

  A conversation no longer bound to `sandbox_id`, or one that is terminal,
  answers `{:ok, :noop}` without calling `writer`. Otherwise `writer` gets the
  locked conversation and an ending: the locked turn, the attributes to apply
  (empty when the turn had already ended) and whether it was still running.
  """
  def _unsafe_end_actor_turn(%Turn{} = observed, sandbox_id, status, attrs, writer) do
    Repo.transaction(fn ->
      with %Conversation{} = conv <- lock_parent(observed.conversation_id),
           true <-
             Admission.bound?(conv, sandbox_id) and conv.status not in ["terminated", "failed"],
           %Turn{} = turn <- lock_turn(observed.id),
           true <- turn.conversation_id == conv.id,
           true <- turn.status == "running" or turn.status in @terminal_turns do
        running? = turn.status == "running"

        allowed =
          if running?,
            do:
              Map.merge(attrs, %{
                status: status,
                ended_at: DateTime.truncate(DateTime.utc_now(), :second)
              }),
            else: %{}

        writer.(conv, %{turn: turn, attrs: allowed, running?: running?})
      else
        _ -> :noop
      end
    end)
  end

  @doc """
  Serialize a turn's parent update with admission; the callback only writes rows.

  `:idle` applies only when the turn has ended and the parent is still
  `running`; `:session` only while the turn runs and the parent is live. Both
  require the turn to be the conversation's newest generation.

  `:sandbox_id` is the writing actor's own binding. Without it a stale actor
  whose conversation Wake moved to a replacement sandbox would still pass
  (#2402). With it, a reassigned parent rolls back `:ownership_changed` before
  the writer runs.
  """
  def _unsafe_write_parent(%Turn{} = observed, mode, writer, opts \\ [])
      when mode in [:idle, :session] do
    Repo.transaction(fn ->
      conv = lock_parent(observed.conversation_id) || Repo.rollback(:not_found)
      turn = lock_turn(observed.id) || Repo.rollback(:turn_missing)
      if turn.conversation_id != conv.id, do: Repo.rollback(:ownership_changed)
      if rebound?(opts, conv), do: Repo.rollback(:ownership_changed)

      if latest_turn?(conv.id, turn.id) and parent_write_allowed?(conv, turn, mode) do
        case writer.(conv) do
          {:ok, updated} -> %{applied: true, conversation: updated}
          {:error, reason} -> Repo.rollback(reason)
        end
      else
        %{applied: false, conversation: conv}
      end
    end)
  end

  defp parent_write_allowed?(conv, turn, :idle),
    do: conv.status == "running" and turn.status in @terminal_turns

  defp parent_write_allowed?(conv, turn, :session),
    do: conv.status in ["running", "idle"] and turn.status == "running"

  @doc """
  Recover an orphaned running turn under the parent and turn locks.

  `:sandbox_id` is the recovering actor's own binding: an actor that supplies
  it and finds the locked parent reassigned recovers nothing. Supplying `nil`
  is an expectation of "no sandbox", not an absent one; omitting the key
  entirely is what the system reaper does, because it is recovering on
  nobody's behalf. The comparison is `Fountain.Machines.Admission.bound?/2`,
  the one definition of the fence (ADR 0058 stage 8a).

  `writer` is called as `writer.(turn, conv, latest?)` only for a turn that is
  still running; anything else answers `{:ok, :noop}`.
  """
  def _unsafe_recover_turn(%Turn{} = observed, writer, opts \\ []) do
    Repo.transaction(fn ->
      conv = lock_parent(observed.conversation_id) || Repo.rollback(:not_found)
      turn = lock_turn(observed.id) || Repo.rollback(:turn_missing)
      if turn.conversation_id != conv.id, do: Repo.rollback(:ownership_changed)
      if rebound?(opts, conv), do: Repo.rollback(:ownership_changed)

      if turn.status == "running",
        do: writer.(turn, conv, latest_turn?(conv.id, turn.id)),
        else: :noop
    end)
  end

  @doc """
  Release only a durably idle parent; refusal never interrupts execution.

  An actor supplies `:sandbox_id`, including an explicit nil for no sandbox.
  Its binding is compared under the parent lock that protects the status write.
  Recovery without an actor omits the key and releases the current binding.

  A `running` turn row is evidence of a live turn only when there is a server
  to run it. Without one it is as likely an orphan — a deploy, a Horde
  rebalance or a plain `{:stop, :normal, _}` leaves one behind — and release is
  what an owner reaches for in exactly that state. The caller says whether a
  server is alive (`:actor_alive?`, default true); only then does a running
  turn refuse with `:busy`.
  """
  def _unsafe_release_parent(conversation_id, writer, opts \\ []) do
    Repo.transaction(fn ->
      conv = lock_parent(conversation_id) || Repo.rollback(:not_running)
      if rebound?(opts, conv), do: Repo.rollback(:ownership_changed)

      if Keyword.get(opts, :actor_alive?, true) and running_turn?(conversation_id),
        do: Repo.rollback(:busy)

      case writer.(conv) do
        {:ok, updated} -> %{applied: true, conversation: updated}
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc "An idle legacy connection may clear only its unchanged session, before any successor starts."
  def _unsafe_clear_idle_session(conv_id, expected, writer) do
    Repo.transaction(fn ->
      conv = lock_parent(conv_id) || Repo.rollback(:not_found)

      if conv.status in ["running", "idle"] and conv.runtime_session_id == expected and
           not running_turn?(conv_id) do
        case writer.(conv) do
          {:ok, updated} -> %{applied: true, conversation: updated}
          {:error, reason} -> Repo.rollback(reason)
        end
      else
        %{applied: false, conversation: conv}
      end
    end)
  end

  @doc """
  Is this turn the conversation's newest generation?

  The predicate every parent write is gated on: a turn that is not the highest
  `turn_number` on its conversation has been superseded, so its ending says
  nothing about whether the conversation is still working. It is deliberately
  ordered on `turn_number` rather than asking whether some other turn is
  `running` — an abandoned older turn left `running` must not stop the current
  generation from idling its parent, and a superseded turn must not idle it
  even when nothing else is running. Callers hold the parent lock, so admission
  cannot land between this read and the write it guards.
  """
  def latest_turn?(conv_id, turn_id) do
    Repo.one(
      from t in Turn,
        where: t.conversation_id == ^conv_id,
        order_by: [desc: t.turn_number],
        limit: 1,
        select: t.id
    ) == turn_id
  end

  # An explicit `nil` is an expectation of "no sandbox" and fences; only an
  # absent key means the caller is recovering on nobody's behalf, which is why
  # this is `Keyword.fetch/2` and not `Keyword.get/2`. The comparison is the
  # owner's (`Admission.bound?/2`), the same one `_unsafe_end_actor_turn/5`
  # makes, so the ending paths cannot drift apart about what "bound" means.
  defp rebound?(opts, conv) do
    case Keyword.fetch(opts, :sandbox_id) do
      {:ok, actor_sandbox_id} -> not Admission.bound?(conv, actor_sandbox_id)
      :error -> false
    end
  end

  defp running_turn?(conv_id),
    do:
      Repo.exists?(from t in Turn, where: t.conversation_id == ^conv_id and t.status == "running")

  defp lock_parent(id),
    do: Repo.one(from c in Conversation, where: c.id == ^id, lock: "FOR UPDATE")

  defp lock_turn(id),
    do: Repo.one(from t in Turn, where: t.id == ^id, lock: "FOR UPDATE")
end
