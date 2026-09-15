defmodule Fountain.Conversations.Interruption do
  @moduledoc """
  Interrupt: the client half that decides where a turn in flight is retired,
  and the row writes for the turn it marks interrupted.

  Moved out of `Fountain.Conversations.ConversationServer` and
  `Fountain.Conversations` in #2213 (one owner per lifecycle verb, #2175), so
  this module is the only writer of the interrupted turn row. The server
  keeps `handle_call(:interrupt)`, `interrupt_turn/1` and
  `retire_bounded_turn/1`: they act on `current_command`, `acp_peer` and the
  quiet timer, state this module cannot see from outside the process.

  Tenant scoping is the caller's job: `interrupt/2` is reached only after a
  tenant-scoped fetch established ownership at the controller, exactly as
  when it lived on the server. `ConversationServer.interrupt/2` delegates
  here so no caller moved.
  """

  import Ecto.Query
  import Fountain.Conversations.ConversationServer, only: [whereis: 1, call_server: 2]

  alias Fountain.Conversations
  alias Fountain.Conversations.{Conversation, ExecutionGuard, Termination, Turn, Wake}
  alias Fountain.Repo

  @doc """
  Interrupt the turn in flight, if any.

  A miss on the registry does not mean there is nothing to interrupt, and
  `wake_for_interrupt/1` owns what a miss means: it wakes a conversation the
  row still calls `running`, and separates "no such conversation"
  (`:not_found`) from "nothing to interrupt" (`:not_running`).
  """
  def interrupt(conv_id, opts \\ []) do
    # ownership: public callers established the conversation's tenant before
    # this boundary. Bounded cancellation commits before any actor/provider I/O.
    result =
      case ExecutionGuard._unsafe_interrupt(conv_id) do
        {:ok, {:bounded, id}} ->
          if pid = whereis(conv_id), do: send(pid, {:execution_retired, id})
          :ok

        {:ok, :unbounded} ->
          case whereis(conv_id) do
            nil -> interrupt_dead(conv_id)
            pid -> call_server(pid, :interrupt)
          end

        {:error, _} = error ->
          error
      end

    Termination.audit_lifecycle(conv_id, "conversation.interrupted", result, opts)
    result
  end

  @doc """
  The journal door for the provision continue before a reattach
  (`ConversationServer.handle_continue(:provision, _)`) and the delete
  cascade (`Conversations.delete_conversation/2`): a journal left by another
  incarnation, or by the conversation being deleted, is retired rather than
  reattached or replayed (ADR 0046: a bounded journal means the actor stops
  instead of reattaching). Returns the guard's `{:ok, _} | {:error, _}`
  unchanged.
  """
  def retire_journal_before_reattach(conv_id) do
    # ownership: the server already holds this conversation's row (fetched at
    # the top of the provision continue); the delete cascade runs after its
    # own tenant-scoped fetch. Both callers established ownership before here.
    ExecutionGuard._unsafe_interrupt(conv_id)
  end

  defp interrupt_dead(conv_id) do
    # A remote self-call (not a bare local call): Mimic's copy renames the
    # original module's compiled code, so only a call through the module's
    # own name is routed through a stub in test (`audit_guardrail_test.exs`).
    case __MODULE__.wake_for_interrupt(conv_id) do
      {:ok, pid} -> call_server(pid, :interrupt)
      {:error, _} = err -> err
    end
  end

  @doc """
  Reach a conversation whose `ConversationServer` is gone, so a caller can
  interrupt the turn it left behind.

  A missing server does not mean there is nothing to interrupt: the process
  can have exited (deploy, Horde rebalance, a plain `{:stop, :normal, _}`)
  while a turn was still marked `running`. Waking reattaches to a live sprite
  session if one exists, or reconciles the orphaned turn itself when none
  does. Only a row that says `running` is worth a wake — an idle, terminated
  or unknown conversation has nothing running regardless, and must not pay
  for one it does not need.

  The two misses are different answers, and #1179 is what conflating them
  looked like from a client. `:not_found` is no such conversation row.
  `:not_running` is a row that exists in no state to be interrupted. Only the
  first is a 404, because every caller establishes ownership before reaching
  here, so answering "wrong id, or it belongs to another account" for a
  conversation the same key can `GET` is a lie.
  """
  @spec wake_for_interrupt(binary()) :: {:ok, pid()} | {:error, :not_found | :not_running}
  def wake_for_interrupt(conv_id) when is_binary(conv_id) do
    # ownership: every caller of interrupt/2 established this conversation's
    # tenant before reaching here (the controller's scoped fetch); this reads
    # the same conversation, not a lookup by another key.
    case Conversations._unsafe_get_conversation(conv_id) do
      nil ->
        {:error, :not_found}

      %Conversation{status: "running"} ->
        with {:ok, conv} <- Wake.wake_conversation_for(conv_id, nil, :interrupt),
             pid when is_pid(pid) <- whereis(conv.id) do
          {:ok, pid}
        else
          _ -> {:error, :not_running}
        end

      _ ->
        {:error, :not_running}
    end
  end

  @doc """
  Mark an actor-owned turn interrupted while retaining the conversation's
  status until the peer has stopped. Uses the same binding and terminal guards
  as completion, with reply activation after commit.
  """
  def _unsafe_interrupt_turn(%Turn{} = turn, sandbox_id),
    do: Conversations.end_running_turn(turn, sandbox_id, "interrupted", false)

  @doc """
  Release the conversation `TurnMachine.mark_interrupted/1` left running.

  Caller requirement: call only from `TurnMachine.close_interrupted/1` after
  its matching `mark_interrupted/1` successfully retired the turn. The public
  `_unsafe_` helper does not enforce this requirement for another caller.

  The binding check belongs to that successful mark: `_unsafe_interrupt_turn/2`
  checks the actor's sandbox binding under the parent lock, and only success
  sets `interrupted?`. `close_interrupted/1` calls this helper only when that
  flag is true. Neither `from_state/1` nor `into_state/2` carries the flag, so
  it cannot survive a mailbox round-trip. `ConversationServer.interrupt_turn/1`
  runs both halves synchronously, separated only by `stop_acp_peer/1`, whose
  `GenServer.stop/3` has a one-second timeout. The server's `sandbox_id` is set
  at init and never changed. An actor already stale at the mark cannot reach
  this write; a rebind after a successful mark can still reach it.

  This half deliberately takes no `sandbox_id` and does not repeat the binding
  check. It writes no turn result. Under the parent and turn locks, it requires
  a `running` parent, an `interrupted` turn and `ExecutionGuard.latest_turn?/2`.
  A successor admitted while the peer was stopping prevents the idle write;
  an older turn left `running` does not. Admission inserts its turn and sets
  the parent `running` in the same transaction under the same parent lock, so
  it cannot slip between this check and the write.

  Rechecking the binding here could leave the parent `running` after the
  first half retired its last running turn. `AutonomousTurnReaper.sweep_stuck_turns/0`
  selects running turns, and `ExecutionGuard._unsafe_recover_turn/3` returns
  `:noop` for a retired turn, so those recovery paths cannot repair that state.
  Other paths can idle the parent: `MachineEvents.gone/5` and the lifecycle's
  park and reclaim paths do so when they run.

  `follow_cotenants/2` sends `:machine_gone` before rebinding with `update_all`,
  so a server that receives the cast has `gone/5`'s cleanup as a backstop.
  `gone/5` ignores a notification naming another sandbox and
  `_unsafe_finish_machine_gone/2` answers `:noop` for a moved conversation
  (#2006), but its idle write is deliberately not conditioned on the binding,
  so a parent left `running` with no running turn is still released. The
  backstop this paragraph relies on therefore survives the rebind.
  `MachineEvents.tell_cotenants/5` skips the cast when `ConversationServer.whereis/1` misses,
  including a cross-pod registry miss, while the rebind still applies. The
  parent can then remain `running` until another cleanup path runs.
  `_unsafe_sandbox_busy_elsewhere?/4` reads co-tenant turns and `updated_at`
  for conversations without turns, not the parent's status; a stuck parent
  alone does not keep the shared sandbox busy or extend its billing lifetime.

  This second half only releases the interrupted turn it marked. General
  completion can separately release an already-ended latest turn without
  changing its result or publishing another outcome.
  """
  def _unsafe_idle_interrupted_turn(%Turn{} = turn) do
    {:ok, result} =
      Repo.transaction(fn ->
        conversation_query =
          from(c in Conversation, where: c.id == ^turn.conversation_id, lock: "FOR UPDATE")

        turn_query =
          from(t in Turn,
            where: t.id == ^turn.id and t.conversation_id == ^turn.conversation_id,
            lock: "FOR UPDATE"
          )

        with %Conversation{status: "running"} = conv <- Repo.one(conversation_query),
             %Turn{status: "interrupted"} <- Repo.one(turn_query),
             true <- ExecutionGuard.latest_turn?(conv.id, turn.id) do
          conv |> Conversation.changeset(%{status: "idle"}) |> Repo.update!()
        else
          _ -> :noop
        end
      end)

    case result do
      %Conversation{} = conv ->
        Conversations.broadcast_sidebar_update(conv.user_id)
        :ok

      :noop ->
        :noop
    end
  end
end
