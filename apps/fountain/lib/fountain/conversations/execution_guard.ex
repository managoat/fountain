defmodule Fountain.Conversations.ExecutionGuard do
  @moduledoc """
  Durable arbitration between a bounded turn finishing and its deadline expiring.

  Conversation then journal row locks serialize registration, completion, and
  termination claims. Provider I/O is deliberately outside these transactions:
  `claim_termination` persists an attempt before handing a worker permission for
  exactly one write. A lost reply leaves a fence; it never grants another write.

  These unscoped operations are for an already-owned conversation server or the
  system deadline worker. Registration derives ownership from persisted parents;
  callers cannot supply a tenant, sandbox name, or provider. A provider-issued
  session identity must be bound by the trusted command transport, never stdout.

  This module is a journal primitive. API admission, transport binding, deadline
  scheduling and lifecycle integration must use it before enforcement is shipped.
  """
  import Ecto.Query

  alias Fountain.{Audit, Repo}
  alias Fountain.Conversations.{Conversation, ExecutionLimits, Sandbox, Turn, TurnExecution}
  alias Fountain.Conversations.{DeadlineEvents, LogEvent}
  alias Fountain.Machines.Admission

  @fenced ~w(awaiting_identity ready submitted uncertain)
  @terminal_turns ~w(completed failed interrupted)

  @doc """
  Register a bounded turn's journal inside the caller's admission transaction.

  Deliberately a step rather than a replacement for
  `Conversations._unsafe_create_turn_on_sandbox/3`. That function already holds
  the per-sandbox advisory lock, takes `FOR UPDATE` on the parent so the
  allowance's foreign key cannot deadlock against it (#1790), proves the
  conversation is still attached to a **non-terminal** sandbox owned by the same
  tenant (#1761, #1764), and rechecks the saved allowance under those locks.
  Re-implementing admission here would drop every one of those; adding a step to
  it keeps them and still commits the journal with the turn.

  A turn with no configured allowance registers nothing: the journal is for
  bounded turns, and an unbounded turn has nothing to expire.
  """
  def _unsafe_register_bounded(turn, sandbox_id, conv) do
    limits = resolve_turn_limits(conv)

    if map_size(limits) == 0 do
      :unbounded
    else
      # A journal row needs an absolute deadline. A request carrying only SDK
      # controls cannot be admitted by inventing an allowance nobody asked for.
      unless Map.has_key?(limits, "wall_time_seconds"),
        do: Repo.rollback({:execution_limits_invalid, "wall_time_seconds_required"})

      sandbox = Repo.get(Sandbox, sandbox_id) || Repo.rollback(:sandbox_not_found)
      if sandbox.provider != "sprites", do: Repo.rollback(:provider_not_supported)

      case Managoat.Runtimes.ACP.execution_limits(
             conv.runtime,
             ExecutionLimits.sdk_options(limits)
           ) do
        {:ok, _} -> :ok
        {:error, reason} -> Repo.rollback(reason)
      end

      if is_nil(turn.started_at), do: Repo.rollback(:turn_not_started)
      deadline = DateTime.add(turn.started_at, limits["wall_time_seconds"], :second)

      case _unsafe_register(turn.id, Ecto.UUID.generate(), deadline) do
        {:ok, execution} -> {:bounded, execution}
        {:error, reason} -> Repo.rollback(reason)
      end
    end
  end

  @doc "Whether an unresolved bounded execution fences this conversation. Caller holds the parent lock."
  def _unsafe_open_execution?(conversation_id), do: open_execution?(conversation_id)

  @doc "Refuse a new prompt or wake while an earlier bounded execution is unresolved."
  def _unsafe_admission_gate(conversation_id) do
    transaction(fn ->
      lock_parent(conversation_id) || Repo.rollback(:not_found)
      if open_execution?(conversation_id), do: Repo.rollback(:execution_fenced)
      {:ok, nil, nil}
    end)
    |> case do
      {:ok, :ok} -> :ok
      error -> error
    end
  end

  @doc "Persist cancellation without waiting for the conversation actor or provider."
  def _unsafe_interrupt(conversation_id) do
    transaction(fn ->
      lock_parent(conversation_id) || Repo.rollback(:not_found)

      # `limit: 1` is exact rather than a guess: `turn_executions_open_conversation_index`
      # is a unique index on `conversation_id` partial to
      # `state NOT IN ('completed','stopped')`, so a conversation has at most
      # one open journal by construction. The `order_by` only makes the choice
      # deterministic if that invariant were ever dropped.
      execution =
        Repo.one(
          from e in TurnExecution,
            where:
              e.conversation_id == ^conversation_id and e.state not in ["completed", "stopped"],
            order_by: [desc: e.inserted_at],
            limit: 1,
            lock: "FOR UPDATE"
        )

      if execution do
        lock_turn(execution.turn_id)
        {decision, changed, event} = complete(execution, "interrupted", DateTime.utc_now())
        {{:bounded, decision.execution.id}, changed, event}
      else
        {:unbounded, nil, nil}
      end
    end)
  end

  @doc """
  Release only a durably idle parent; refusal never retires or interrupts execution.

  An actor supplies `:sandbox_id`, including an explicit nil for no sandbox.
  Its binding is compared under the parent lock that protects the status write.
  Recovery without an actor omits the key and releases the current binding.
  """
  def _unsafe_release_parent(conversation_id, writer, opts \\ []) do
    transaction(fn ->
      conv = lock_parent(conversation_id) || Repo.rollback(:not_running)
      if rebound?(opts, conv), do: Repo.rollback(:ownership_changed)

      # A `running` turn row is evidence of a live turn only when there is a
      # server to run it. Without one it is as likely an orphan — a deploy, a
      # Horde rebalance or a plain `{:stop, :normal, _}` left it behind, which
      # `wake_for_interrupt/1` spells out — and release is what an owner
      # reaches for in exactly that state. Refusing there took away a release
      # that always worked. The caller says whether a server is alive.
      if Keyword.get(opts, :actor_alive?, true) do
        running? =
          Repo.exists?(
            from t in Turn, where: t.conversation_id == ^conversation_id and t.status == "running"
          )

        if running?, do: Repo.rollback(:busy)
      end

      # The durable fence is unconditional. An unresolved bounded execution
      # means a remote command may still be running, and releasing would drop
      # the row that says so. This one has an age rather than being permanent
      # — `_unsafe_retire_unresolved/2` writes it off — so the refusal is
      # bounded, unlike the running-turn check it used to sit beside.
      if open_execution?(conversation_id), do: Repo.rollback(:execution_fenced)

      case writer.(conv) do
        {:ok, updated} -> {%{applied: true, conversation: updated}, nil, nil}
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc "Find the immutable journal for an already-owned actor's turn."
  def _unsafe_for_turn(turn_id), do: Repo.get_by(TurnExecution, turn_id: turn_id)

  def _unsafe_register(turn_id, connection_id, %DateTime{} = deadline_at, opts \\ []) do
    transaction(fn ->
      turn = Repo.get(Turn, turn_id) || Repo.rollback(:not_found)
      observed = Repo.get(Conversation, turn.conversation_id) || Repo.rollback(:not_found)
      lock_sandbox(observed.sandbox_id)
      conv = lock_parent(turn.conversation_id) || Repo.rollback(:not_found)
      if conv.sandbox_id != observed.sandbox_id, do: Repo.rollback(:ownership_changed)
      turn = lock_turn(turn_id) || Repo.rollback(:not_found)
      if turn.conversation_id != conv.id, do: Repo.rollback(:ownership_changed)
      existing = lock_execution_by_turn(turn_id)
      now = Keyword.get(opts, :now, DateTime.utc_now())

      cond do
        existing && existing.connection_id == connection_id &&
            DateTime.compare(existing.deadline_at, deadline_at) == :eq ->
          {existing, nil, nil}

        existing ->
          Repo.rollback(:immutable_execution)

        turn.status != "running" ->
          Repo.rollback(:turn_not_running)

        DateTime.compare(deadline_at, now) != :gt ->
          Repo.rollback(:deadline_expired)

        open_execution?(conv.id) ->
          Repo.rollback(:execution_fenced)

        true ->
          sandbox = Repo.get(Sandbox, conv.sandbox_id) || Repo.rollback(:sandbox_not_found)
          if sandbox.user_id != conv.user_id, do: Repo.rollback(:ownership_changed)
          if sandbox.status != "ready", do: Repo.rollback(:sandbox_not_ready)

          # Bounded turns never inherit a warm process: it may retain background
          # work or SDK allowances from its previous prompt.
          if prior_connection(connection_id), do: Repo.rollback(:connection_retired)

          limits = resolve_turn_limits(conv)
          enforce_deadline_ceiling!(turn, deadline_at, limits)

          attrs = %{
            execution_limits: limits,
            turn_id: turn.id,
            conversation_id: conv.id,
            user_id: conv.user_id,
            sandbox_id: sandbox.id,
            sandbox_name: sandbox.machine_name,
            provider: sandbox.provider,
            connection_id: connection_id,
            deadline_at: deadline_at
          }

          case %TurnExecution{} |> TurnExecution.changeset(attrs) |> Repo.insert() do
            {:ok, execution} -> {execution, execution, "registered"}
            {:error, changeset} -> Repo.rollback(changeset)
          end
      end
    end)
  end

  @doc "Record one spawn intent before opening its transport; an unknown spawn is never replayed."
  def _unsafe_claim_spawn(id, opts \\ []) do
    with_execution(id, fn execution ->
      now = Keyword.get(opts, :now, DateTime.utc_now())

      cond do
        execution.state != "active" or not is_nil(execution.provider_session_id) or
            not is_nil(execution.spawn_submitted_at) ->
          Repo.rollback(:spawn_not_ready)

        DateTime.compare(now, execution.deadline_at) != :lt ->
          Repo.rollback(:deadline_expired)

        not match?(%Turn{status: "running"}, Repo.get(Turn, execution.turn_id)) ->
          Repo.rollback(:turn_not_running)

        not current_binding?(execution) ->
          Repo.rollback(:ownership_changed)

        true ->
          updated = update!(execution, %{spawn_submitted_at: now})
          {updated, updated, "spawn_submitted"}
      end
    end)
  end

  def _unsafe_bind_identity(id, connection_id, session_id) do
    if valid_session_id?(session_id) do
      with_execution(id, fn execution ->
        cond do
          execution.connection_id != connection_id ->
            Repo.rollback(:stale_connection)

          execution.provider_session_id == session_id ->
            {execution, nil, nil}

          execution.state not in [
            "active",
            "awaiting_identity",
            "ready",
            "submitted",
            "uncertain"
          ] ->
            Repo.rollback(:execution_closed)

          not is_nil(execution.provider_session_id) ->
            updated =
              update!(execution, %{state: "uncertain", last_error: "conflicting_identity"})

            fail_running_turn(execution.turn_id, DateTime.utc_now())
            {updated, updated, "identity_uncertain"}

          execution.state not in ["active", "awaiting_identity"] ->
            Repo.rollback(:execution_closed)

          is_nil(execution.spawn_submitted_at) ->
            Repo.rollback(:spawn_not_submitted)

          true ->
            state = if execution.state == "awaiting_identity", do: "ready", else: "active"
            updated = update!(execution, %{provider_session_id: session_id, state: state})
            {updated, updated, "identity_bound"}
        end
      end)
    else
      {:error, :invalid_session_id}
    end
  end

  @doc "Authorize an immediate write to the original identified execution."
  def _unsafe_authorize_write(id, connection_id, opts \\ []) do
    with_execution(id, fn execution ->
      now = Keyword.get(opts, :now, DateTime.utc_now())

      cond do
        execution.connection_id != connection_id ->
          Repo.rollback(:stale_connection)

        execution.state != "active" ->
          Repo.rollback(:execution_fenced)

        DateTime.compare(now, execution.deadline_at) != :lt ->
          {decision, changed, event} = expire(execution, now)
          {Map.put(decision, :permitted, false), changed, event}

        is_nil(execution.provider_session_id) ->
          Repo.rollback(:identity_unconfirmed)

        not match?(%Turn{status: "running"}, Repo.get(Turn, execution.turn_id)) ->
          Repo.rollback(:turn_not_running)

        not current_binding?(execution) ->
          Repo.rollback(:ownership_changed)

        true ->
          {%{permitted: true, execution: execution}, nil, nil}
      end
    end)
  end

  @doc """
  May this actor still handle its own messages? One unlocked read.

  Deliberately not `_unsafe_authorize_write/3`. That one is a transaction with
  `FOR UPDATE` on the conversation, the journal row and the turn, and it belongs
  where a provider write or a terminal outcome actually happens — the transport
  (#1748) and `_unsafe_complete/3`. Running it per inbound message meant six
  queries and three row locks for every `{:stdout, ...}` chunk and every
  `{:acp, ...}` report of a chatty turn, and because it took the parent lock it
  serialized against admission, release, reset and the coordinator's own expire:
  the hotter the turn, the longer the coordinator queued behind the very turn it
  was supposed to expire.

  The inbound stream cannot reach the provider by itself, so it does not need
  write authorization — only "is this still mine, and is it still inside its
  deadline". Three columns answer that. `:retire` is not the durable decision
  either: the caller's retirement takes the locks and `_unsafe_complete/3`
  arbitrates completion against expiry there, so a missing row, a superseded
  connection, a closed state and a passed deadline all converge on the same
  authoritative write one frame later.
  """
  def _unsafe_actor_gate(id, connection_id, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    case Repo.one(
           from e in TurnExecution,
             where: e.id == ^id,
             select: %{
               state: e.state,
               connection_id: e.connection_id,
               deadline_at: e.deadline_at
             }
         ) do
      %{state: "active", connection_id: ^connection_id, deadline_at: deadline} ->
        if DateTime.compare(now, deadline) == :lt, do: :ok, else: :retire

      _ ->
        :retire
    end
  end

  @doc "End an actor-owned turn under parent, journal and turn locks; the callback only writes rows."
  def _unsafe_end_actor_turn(%Turn{} = observed, sandbox_id, status, attrs, writer) do
    transaction(fn ->
      with %Conversation{} = conv <- lock_parent(observed.conversation_id),
           true <-
             Admission.bound?(conv, sandbox_id) and conv.status not in ["terminated", "failed"],
           execution = lock_execution_by_turn(observed.id),
           %Turn{} = turn <- lock_turn(observed.id),
           true <- turn.conversation_id == conv.id,
           true <- is_nil(execution) or current_binding?(execution),
           true <- turn.status == "running" or turn.status in @terminal_turns do
        {ending, changed, event} = actor_ending(turn, execution, status, attrs)

        {writer.(conv, ending), changed, event}
      else
        _ -> {:noop, nil, nil}
      end
    end)
  end

  defp actor_ending(turn, nil, status, attrs) do
    running? = turn.status == "running"

    allowed =
      if running?,
        do:
          Map.merge(attrs, %{
            status: status,
            ended_at: DateTime.truncate(DateTime.utc_now(), :second)
          }),
        else: %{}

    {%{
       turn: turn,
       attrs: allowed,
       announce?: running?,
       materialize?: running?,
       idle_allowed?: true
     }, nil, nil}
  end

  defp actor_ending(turn, execution, status, attrs) do
    {decision, changed, event} = complete(execution, status, DateTime.utc_now())

    allowed =
      if Map.get(decision, :terminal_changed, false), do: Map.take(attrs, [:exit_code]), else: %{}

    # A successful waiting turn detached its request before completion. The
    # journal clears held permissions, but this metadata must survive so the
    # terminal stage can name the request that now outlives the command.
    allowed =
      if Map.get(decision, :terminal_changed, false) and decision.turn.status == "completed" and
           turn.waiting,
         do: Map.put(allowed, :pending_permission, turn.pending_permission),
         else: allowed

    announce? =
      turn.status == "running" and decision.turn.status in @terminal_turns and
        is_nil(decision.execution.deadline_event_id)

    {%{
       turn: decision.turn,
       attrs: allowed,
       announce?: announce?,
       materialize?: turn.status == "running",
       idle_allowed?: decision.execution.state != "active"
     }, changed, event}
  end

  @doc "A completion after the absolute deadline becomes a failed, fenced turn."
  def _unsafe_complete(id, status, opts \\ []) when status in @terminal_turns do
    with_execution(id, fn execution ->
      complete(execution, status, Keyword.get(opts, :now, DateTime.utc_now()))
    end)
  end

  @doc "Serialize a turn's parent update with admission and retirement; callbacks only write rows."
  def _unsafe_write_parent(%Turn{} = observed, mode, writer) when mode in [:idle, :session] do
    transaction(fn ->
      conv = lock_parent(observed.conversation_id) || Repo.rollback(:not_found)
      execution = lock_execution_by_turn(observed.id)
      turn = lock_turn(observed.id) || Repo.rollback(:turn_missing)
      if turn.conversation_id != conv.id, do: Repo.rollback(:ownership_changed)

      {execution, turn, changed, event} = parent_execution(execution, turn)

      allowed =
        latest_turn?(conv.id, turn.id) and parent_write_allowed?(conv, turn, execution, mode)

      if allowed do
        case writer.(conv) do
          {:ok, updated} -> {%{applied: true, conversation: updated}, changed, event}
          {:error, reason} -> Repo.rollback(reason)
        end
      else
        {%{applied: false, conversation: conv}, changed, event}
      end
    end)
  end

  @doc """
  Retire an orphan's execution before recovery writes, in parent/journal/turn lock order.

  `:sandbox_id` is the recovering actor's own binding. `cleanup_binding?/1`
  already refuses a bounded turn whose journal names a sandbox the parent no
  longer points at, but an unbounded turn has no journal row and nothing else
  records which machine was driving it. An actor that supplies the option and
  finds the locked parent reassigned recovers nothing: the rollback happens
  before `retire_orphan/2`, so a stale actor writes neither the turn nor the
  journal. Supplying `nil` is an expectation of "no sandbox", not an absent one;
  omitting the key entirely is what the system reaper does, because it is
  recovering on nobody's behalf. The comparison itself is
  `Fountain.Machines.Admission.bound?/2`, the one definition of the fence
  (ADR 0058 stage 8a).
  """
  def _unsafe_recover_turn(%Turn{} = observed, writer, opts \\ []) do
    transaction(fn ->
      conv = lock_parent(observed.conversation_id) || Repo.rollback(:not_found)
      execution = lock_execution_by_turn(observed.id)
      turn = lock_turn(observed.id) || Repo.rollback(:turn_missing)
      if turn.conversation_id != conv.id, do: Repo.rollback(:ownership_changed)

      if rebound?(opts, conv), do: Repo.rollback(:ownership_changed)
      if execution && not cleanup_binding?(execution), do: Repo.rollback(:ownership_changed)
      running? = turn.status == "running"
      {turn, changed, event} = retire_orphan(execution, turn)

      if running? do
        result = writer.(turn, conv, latest_turn?(conv.id, turn.id), not is_nil(execution))
        {result, changed, event}
      else
        {:noop, changed, event}
      end
    end)
  end

  defp retire_orphan(nil, turn), do: {turn, nil, nil}

  defp retire_orphan(execution, turn) do
    status = if turn.status == "running", do: "interrupted", else: turn.status
    {decision, changed, event} = complete(execution, status, DateTime.utc_now())
    {decision.turn, changed, event}
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

  @doc "An idle legacy connection may clear only its unchanged session, before any successor starts."
  def _unsafe_clear_idle_session(conv_id, expected, writer) do
    transaction(fn ->
      conv = lock_parent(conv_id) || Repo.rollback(:not_found)

      running? =
        Repo.exists?(
          from t in Turn, where: t.conversation_id == ^conv_id and t.status == "running"
        )

      bounded? = Repo.exists?(from e in TurnExecution, where: e.conversation_id == ^conv_id)

      if conv.status in ["running", "idle"] and conv.runtime_session_id == expected and
           not running? and not bounded? do
        case writer.(conv) do
          {:ok, updated} -> {%{applied: true, conversation: updated}, nil, nil}
          {:error, reason} -> Repo.rollback(reason)
        end
      else
        {%{applied: false, conversation: conv}, nil, nil}
      end
    end)
  end

  defp parent_execution(nil, turn), do: {nil, turn, nil, nil}

  defp parent_execution(execution, turn) do
    now = DateTime.utc_now()

    if execution.state == "active" and current_binding?(execution) and
         DateTime.compare(now, execution.deadline_at) != :lt do
      {decision, changed, event} = expire(execution, now)
      {decision.execution, decision.turn, changed, event}
    else
      {execution, turn, nil, nil}
    end
  end

  defp parent_write_allowed?(conv, turn, execution, mode) do
    bound? = is_nil(execution) or current_binding?(execution)

    case mode do
      :idle ->
        bound? and conv.status == "running" and turn.status in @terminal_turns and
          (is_nil(execution) or execution.state != "active")

      :session ->
        bound? and conv.status in ["running", "idle"] and turn.status == "running" and
          (is_nil(execution) or execution.state == "active")
    end
  end

  @doc "Serialize transcript writes with retirement; the callback must contain only database work."
  def _unsafe_write_event(conv_id, turn_id, writer) do
    case turn_id && Repo.get_by(TurnExecution, turn_id: turn_id) do
      nil ->
        {:ok, writer.()}

      execution ->
        with_execution(execution.id, fn current ->
          now = DateTime.utc_now()

          cond do
            current.conversation_id != conv_id or not current_binding?(current) ->
              {nil, nil, nil}

            current.state != "active" ->
              {nil, nil, nil}

            DateTime.compare(now, current.deadline_at) != :lt ->
              {_decision, changed, event} = expire(current, now)
              {nil, changed, event}

            not match?(%Turn{status: "running"}, Repo.get(Turn, current.turn_id)) ->
              {nil, nil, nil}

            true ->
              {writer.(), nil, nil}
          end
        end)
    end
  end

  @doc """
  Serialize the existing turn writer with deadline and termination state.

  Ordinary turn updates run here, bounded or not: permission requests, prompt
  ids and model selections. Actor completion uses `_unsafe_end_actor_turn/5`
  so its sandbox binding, reply and parent idle write share this journal's
  arbitration and lock order. The unbounded path therefore pays
  one indexed lookup on `turn_executions.turn_id` (unique index) and nothing
  else: no row, no transaction, straight through to `writer`. That cost is
  deliberate: both ordinary updates and actor completion consult the journal
  before writing a turn result.
  """
  def _unsafe_write_turn(%Turn{} = turn, attrs, writer) do
    case Repo.get_by(TurnExecution, turn_id: turn.id) do
      nil ->
        writer.(turn, attrs)

      execution ->
        with_execution(execution.id, fn current ->
          now = DateTime.utc_now()
          requested_status = attrs[:status] || attrs["status"]

          {decision, changed, event} =
            cond do
              requested_status in @terminal_turns ->
                complete(current, requested_status, now)

              current.state == "active" and DateTime.compare(now, current.deadline_at) != :lt ->
                expire(current, now)

              true ->
                {%{execution: current, turn: lock_turn(current.turn_id)}, nil, nil}
            end

          row = decision.turn || Repo.rollback(:turn_missing)

          # Once retired, a stale actor cannot rewrite its prompt, selection,
          # reply or permission state. The winning terminal transition may
          # retain its exit code; delayed usage has its own once-only writer.
          allowed =
            cond do
              decision.execution.state == "active" ->
                attrs

              Map.get(decision, :terminal_changed, false) ->
                Map.take(attrs, [:exit_code, "exit_code"])

              true ->
                %{}
            end

          case writer.(row, allowed) do
            {:ok, result} -> {result, changed, event}
            {:error, reason} -> Repo.rollback(reason)
          end
        end)
    end
  end

  defp complete(execution, status, now) do
    turn = lock_turn(execution.turn_id)

    cond do
      is_nil(turn) and execution.state == "active" ->
        missing_turn(execution)

      is_nil(turn) ->
        {%{execution: execution, turn: nil}, nil, nil}

      execution.state == "active" and DateTime.compare(now, execution.deadline_at) != :lt ->
        expire(execution, now)

      execution.state == "active" and not is_nil(execution.spawn_submitted_at) and
          is_nil(execution.provider_session_id) ->
        uncertain_spawn(execution, turn, now)

      execution.state == "active" and turn.status in ["failed", "interrupted"] ->
        stop(execution, turn, turn.status, now)

      execution.state == "active" and turn.status == "completed" ->
        stop(execution, turn, "completed", now)

      execution.state == "active" and status in ["failed", "interrupted"] ->
        stop(execution, turn, status, now)

      execution.state == "active" and status == "completed" and
          is_nil(execution.provider_session_id) ->
        Repo.rollback(:execution_not_started)

      execution.state == "active" and DateTime.compare(now, execution.deadline_at) == :lt ->
        stop(execution, turn, status, now)

      true ->
        {%{execution: execution, turn: Repo.get(Turn, execution.turn_id)}, nil, nil}
    end
  end

  def _unsafe_expire(id, opts \\ []) do
    with_execution(id, fn execution ->
      now = Keyword.get(opts, :now, DateTime.utc_now())

      if execution.state == "active" and DateTime.compare(now, execution.deadline_at) != :lt do
        expire(execution, now)
      else
        {%{execution: execution, turn: Repo.get(Turn, execution.turn_id)}, nil, nil}
      end
    end)
  end

  @doc "Serialize a terminal stage with expiration; reuse an existing deadline event."
  def _unsafe_terminal_stage(conv_id, turn_id, status, writer) do
    case Repo.get_by(TurnExecution, turn_id: turn_id) do
      nil ->
        {:ok, {:new, writer.()}}

      execution when execution.conversation_id != conv_id ->
        {:ok, {:existing, nil}}

      execution ->
        with_execution(execution.id, fn current ->
          now = DateTime.utc_now()

          {decision, changed, event} =
            if current.state == "active" and DateTime.compare(now, current.deadline_at) != :lt,
              do: expire(current, now),
              else: {%{execution: current, turn: lock_turn(current.turn_id)}, nil, nil}

          result = terminal_event(decision, conv_id, turn_id, status, writer)

          {result, changed, event}
        end)
    end
  end

  defp terminal_event(decision, conv_id, turn_id, status, writer) do
    execution = decision.execution
    turn = decision.turn

    cond do
      execution.conversation_id != conv_id or is_nil(turn) ->
        {:existing, nil}

      execution.deadline_event_id || turn.limit_reason == "wall_time_limit" ->
        stored =
          if execution.deadline_event_id,
            do:
              Repo.get_by(LogEvent,
                id: execution.deadline_event_id,
                conversation_id: conv_id,
                turn_id: turn_id
              )

        {:existing, stored}

      not current_binding?(execution) ->
        {:existing, nil}

      Map.get(
        %{"done" => "completed", "failed" => "failed", "interrupted" => "interrupted"},
        status
      ) != turn.status ->
        {:existing, nil}

      true ->
        {:new, writer.()}
    end
  end

  @doc "Persist one provider-write attempt; never replay a submitted or uncertain attempt."
  def _unsafe_claim_termination(id, opts \\ []) do
    with_execution(id, fn execution ->
      now = Keyword.get(opts, :now, DateTime.utc_now())

      cond do
        execution.state != "ready" ->
          Repo.rollback(:not_ready)

        not cleanup_binding?(execution) ->
          updated = update!(execution, %{state: "uncertain", last_error: "ownership_changed"})
          {%{permitted: false, execution: updated}, updated, "termination_uncertain"}

        true ->
          updated =
            update!(execution, %{
              state: "submitted",
              attempt_id: Ecto.UUID.generate(),
              submitted_at: now
            })

          {%{permitted: true, execution: updated}, updated, "termination_submitted"}
      end
    end)
  end

  @doc "Apply only the result of the recorded attempt, including a late acknowledgment."
  def _unsafe_record_termination(id, attempt_id, result, opts \\ []) do
    with_execution(id, fn execution ->
      now = Keyword.get(opts, :now, DateTime.utc_now())

      cond do
        is_nil(attempt_id) or execution.attempt_id != attempt_id ->
          Repo.rollback(:stale_attempt)

        execution.state == "stopped" and result == :ok ->
          {execution, nil, nil}

        execution.state not in ["submitted", "uncertain"] ->
          Repo.rollback(:execution_closed)

        execution.state == "uncertain" and execution.last_error != "termination_unconfirmed" ->
          Repo.rollback(:binding_uncertain)

        result == :ok ->
          updated = update!(execution, %{state: "stopped", confirmed_at: now, last_error: nil})
          {updated, updated, "termination_confirmed"}

        true ->
          updated =
            update!(execution, %{state: "uncertain", last_error: "termination_unconfirmed"})

          {updated, updated, "termination_uncertain"}
      end
    end)
  end

  @doc "Recover lost termination owners without authorizing another provider write."
  def _unsafe_recover_submissions(%DateTime{} = cutoff, limit \\ 50) when limit in 1..100 do
    ids =
      Repo.all(
        from e in TurnExecution,
          where: e.state == "submitted" and e.submitted_at <= ^cutoff,
          order_by: [asc: e.submitted_at, asc: e.id],
          limit: ^limit,
          select: e.id
      )

    Enum.map(ids, fn id ->
      with_execution(id, fn execution ->
        if execution.state == "submitted" and
             DateTime.compare(execution.submitted_at, cutoff) != :gt do
          updated =
            update!(execution, %{state: "uncertain", last_error: "termination_unconfirmed"})

          {updated, updated, "termination_uncertain"}
        else
          {execution, nil, nil}
        end
      end)
    end)
  end

  @doc """
  Write off an obligation nothing can resolve, without ever replaying it.

  `awaiting_identity` and `uncertain` are reached when the provider never named
  the session, named two, or left a termination unacknowledged. Nothing can move
  them on its own: a claim needs `ready`, and an acknowledgment needs the
  `attempt_id` of an attempt whose owner is gone. Left alone they fence their
  conversation and their machine for good, which costs an owner the two
  recoveries — a new turn, and `reset_sandbox/2` — that exist for exactly this.

  So the fence is an obligation with an age, not a life sentence. Past `cutoff`
  the row retires to `stopped` and keeps `last_error`, so the trail still says
  the operation was never confirmed. This authorizes no provider write; it gives
  up on one. A session that really did survive is the `SandboxReaper`'s to find,
  the same as every unbounded turn's.
  """
  def _unsafe_retire_unresolved(%DateTime{} = cutoff, limit \\ 50) when limit in 1..100 do
    ids =
      Repo.all(
        from e in TurnExecution,
          where: e.state in ["awaiting_identity", "uncertain"] and e.updated_at <= ^cutoff,
          order_by: [asc: e.updated_at, asc: e.id],
          limit: ^limit,
          select: e.id
      )

    Enum.map(ids, fn id ->
      with_execution(id, fn execution ->
        if execution.state in ["awaiting_identity", "uncertain"] and
             DateTime.compare(execution.updated_at, cutoff) != :gt do
          updated =
            update!(execution, %{
              state: "stopped",
              last_error: execution.last_error || "unresolved_obligation_expired"
            })

          {updated, updated, "obligation_abandoned"}
        else
          {execution, nil, nil}
        end
      end)
    end)
  end

  @doc "Rows needing deadline or termination handling; this read grants no provider write."
  def _unsafe_due(now \\ DateTime.utc_now(), limit \\ 50) when limit in 1..100 do
    Repo.all(
      from e in TurnExecution,
        where: (e.state == "active" and e.deadline_at <= ^now) or e.state == "ready",
        order_by: [asc: e.deadline_at, asc: e.id],
        limit: ^limit
    )
  end

  @doc "Deadline candidates only; pending provider cleanup must not starve expiration."
  def _unsafe_due_deadlines(now, limit \\ 50) when limit in 1..100 do
    Repo.all(
      from e in TurnExecution,
        where: e.state == "active" and e.deadline_at <= ^now,
        order_by: [asc: e.deadline_at, asc: e.id],
        limit: ^limit,
        select: e.id
    )
  end

  @doc "Known sessions awaiting their one termination claim, independently of deadlines."
  def _unsafe_ready_terminations(limit \\ 50) when limit in 1..100 do
    Repo.all(
      from e in TurnExecution,
        where: e.state == "ready",
        order_by: [asc: e.deadline_at, asc: e.id],
        limit: ^limit,
        select: e.id
    )
  end

  @doc "Unfinished remote work also prevents reset after its local turn has ended."
  def _unsafe_sandbox_open?(sandbox_id) do
    Repo.exists?(
      from e in TurnExecution,
        where: e.sandbox_id == ^sandbox_id and e.state not in ["completed", "stopped"]
    )
  end

  def _unsafe_fenced?(conversation_id) do
    Repo.exists?(
      from e in TurnExecution,
        where: e.conversation_id == ^conversation_id and e.state in ^@fenced
    )
  end

  defp expire(execution, now) do
    turn = lock_turn(execution.turn_id)

    # A different completion path may already have ended the row. It cannot
    # authorize terminating the connection now used by a later turn.
    cond do
      is_nil(turn) ->
        missing_turn(execution)

      turn.status in ["failed", "interrupted"] ->
        stop(execution, turn, turn.status, now)

      turn.status == "completed" ->
        stop(execution, turn, "completed", now)

      true ->
        state =
          cond do
            execution.provider_session_id -> "ready"
            execution.spawn_submitted_at -> "awaiting_identity"
            true -> "stopped"
          end

        updated = update!(execution, %{state: state})

        turn =
          update!(turn, %{
            status: "failed",
            limit_reason: "wall_time_limit",
            exit_code: nil,
            ended_at: DateTime.truncate(now, :second),
            pending_permission: nil
          })

        # ownership: expire holds the original journal, parent and turn locks;
        # the event writer also checks the parent against the saved tenant.
        event_id = DeadlineEvents._unsafe_record!(updated, turn)
        updated = update!(updated, %{deadline_event_id: event_id})

        {%{execution: updated, turn: turn}, updated, "deadline_expired"}
    end
  end

  # No local turn outcome proves the command stopped. Even a successful reply
  # may leave background work; every bounded connection requires remote cleanup.
  defp stop(execution, turn, status, now) do
    state =
      cond do
        execution.provider_session_id -> "ready"
        execution.spawn_submitted_at -> "awaiting_identity"
        true -> "stopped"
      end

    updated = update!(execution, %{state: state})
    changed = turn.status == "running"

    turn =
      if changed,
        do:
          update!(turn, %{
            status: status,
            ended_at: DateTime.truncate(now, :second),
            pending_permission: nil
          }),
        else: turn

    {%{execution: updated, turn: turn, terminal_changed: changed}, updated, "stop_requested"}
  end

  defp uncertain_spawn(execution, turn, now) do
    updated = update!(execution, %{state: "awaiting_identity", last_error: "spawn_unconfirmed"})

    turn =
      update!(turn, %{
        status: "failed",
        exit_code: nil,
        pending_permission: nil,
        ended_at: DateTime.truncate(now, :second)
      })

    {%{execution: updated, turn: turn}, updated, "spawn_uncertain"}
  end

  defp missing_turn(execution) do
    updated = update!(execution, %{state: "uncertain", last_error: "turn_missing"})
    {%{execution: updated, turn: nil}, updated, "termination_uncertain"}
  end

  defp fail_running_turn(turn_id, now) do
    case lock_turn(turn_id) do
      %Turn{status: "running"} = turn ->
        update!(turn, %{
          status: "failed",
          exit_code: nil,
          pending_permission: nil,
          ended_at: DateTime.truncate(now, :second)
        })

      _ ->
        :ok
    end
  end

  # A persisted retirement survives parent deletion. The original sandbox row
  # must still prove its tenant/name/provider binding; a surviving conversation
  # must also remain bound to it. Missing or changed sandbox identity stays
  # uncertain. Reset cannot reuse this row while its journal remains open.
  defp cleanup_binding?(execution) do
    sandbox_matches =
      Repo.exists?(
        from s in Sandbox,
          where:
            s.id == ^execution.sandbox_id and s.user_id == ^execution.user_id and
              s.machine_name == ^execution.sandbox_name and s.provider == ^execution.provider
      )

    parent_matches =
      case Repo.get(Conversation, execution.conversation_id) do
        nil -> true
        conv -> conv.user_id == execution.user_id and conv.sandbox_id == execution.sandbox_id
      end

    sandbox_matches and parent_matches
  end

  # The other half of the same question, for a turn that has no journal row to
  # ask it of. `cleanup_binding?/1` above compares the *journal's* recorded
  # sandbox identity; this compares the *actor's* — the only record that exists
  # when there is no `TurnExecution`.
  #
  # That is not a corner case. Whether a journal row exists is decided by
  # execution limits (`resolve_turn_limits/1`), not by turn capacity, and limits
  # ship inert: `host_ceiling/0` is `%{}` and `enforced_controls/1` is `[]`
  # (#1773-#1793). So today every production turn takes the no-journal path and
  # this guard is the only thing standing between a stale actor and another
  # machine's turn. Do not delete it as exotic.
  #
  # An explicit `nil` is an expectation of "no sandbox" and fences; only an
  # absent key means the caller is recovering on nobody's behalf, which is why
  # this is `Keyword.fetch/2` and not `Keyword.get/2`. The comparison is the
  # owner's (`Admission.bound?/2`), the same one `_unsafe_end_actor_turn/5`
  # makes, so the two ending paths cannot drift apart about what "bound" means.
  defp rebound?(opts, conv) do
    case Keyword.fetch(opts, :sandbox_id) do
      {:ok, actor_sandbox_id} -> not Admission.bound?(conv, actor_sandbox_id)
      :error -> false
    end
  end

  defp current_binding?(execution) do
    Repo.exists?(
      from c in Conversation,
        join: s in Sandbox,
        on: s.id == c.sandbox_id,
        where:
          c.id == ^execution.conversation_id and c.user_id == ^execution.user_id and
            s.id == ^execution.sandbox_id and s.user_id == ^execution.user_id and
            s.machine_name == ^execution.sandbox_name and s.provider == ^execution.provider and
            s.status not in ["failed", "terminated"]
    )
  end

  defp with_execution(id, fun) do
    transaction(fn ->
      existing = Repo.get(TurnExecution, id) || Repo.rollback(:not_found)
      lock_parent(existing.conversation_id)
      execution = Repo.one!(from e in TurnExecution, where: e.id == ^id, lock: "FOR UPDATE")
      # Acquire every row lock before callbacks read the clock. A legacy writer
      # holding just the turn row must not extend a completion or spawn deadline.
      lock_turn(execution.turn_id)
      fun.(execution)
    end)
  end

  # Same namespace/order as sandbox reset: machine lock, then parent, then journal.
  # The reset retires its row under this lock before any provider I/O.
  defp lock_sandbox(id) do
    Repo.query!("SELECT pg_advisory_xact_lock($1, $2)", [4316, :erlang.phash2(id)])
  end

  defp lock_parent(id),
    do: Repo.one(from c in Conversation, where: c.id == ^id, lock: "FOR UPDATE")

  defp lock_execution_by_turn(id),
    do: Repo.one(from e in TurnExecution, where: e.turn_id == ^id, lock: "FOR UPDATE")

  defp lock_turn(id),
    do: Repo.one(from t in Turn, where: t.id == ^id, lock: "FOR UPDATE")

  defp prior_connection(connection_id),
    do:
      Repo.one(
        from e in TurnExecution,
          where: e.connection_id == ^connection_id,
          order_by: [desc: e.inserted_at],
          limit: 1
      )

  defp open_execution?(conversation_id),
    do:
      Repo.exists?(
        from e in TurnExecution,
          where: e.conversation_id == ^conversation_id and e.state not in ["completed", "stopped"]
      )

  # The allowance this turn is admitted under, resolved once under the parent
  # lock and frozen onto the journal row. The saved conversation allowance is
  # `execution_allowances` (#1790), not a column on the parent: it carries a
  # revision, so a launch and a resume cannot silently overwrite each other.
  #
  # `for_new_turn/3` tightens rather than re-resolves — a later turn may be
  # narrower than the saved allowance but never wider, so raising an account
  # ceiling mid-conversation does not widen a conversation that was already
  # admitted under a lower one.
  defp resolve_turn_limits(conv) do
    user = Repo.get!(Fountain.Accounts.User, conv.user_id)

    saved = saved_allowance(conv.id)

    case ExecutionLimits.for_new_turn(
           ExecutionLimits.host_ceiling(),
           user.execution_limits,
           saved
         ) do
      {:ok, limits} -> limits
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp saved_allowance(conversation_id) do
    case Repo.one(
           from a in Fountain.Conversations.ExecutionAllowance,
             where: a.conversation_id == ^conversation_id,
             select: a.limits
         ) do
      nil -> %{}
      limits when is_map(limits) -> limits
      _ -> Repo.rollback({:execution_limits_invalid, "object_required"})
    end
  end

  # A journal row's deadline is absolute, so the wall-clock allowance is checked
  # against it here rather than trusted from the caller that computed it. A
  # caller that asks for a deadline beyond the allowance is refused, not clamped
  # — silently shortening someone's requested bound is the worse answer.
  defp enforce_deadline_ceiling!(turn, deadline_at, %{"wall_time_seconds" => seconds}) do
    if is_nil(turn.started_at), do: Repo.rollback(:turn_not_started)
    ceiling = DateTime.add(turn.started_at, seconds, :second)

    if DateTime.compare(deadline_at, ceiling) == :gt,
      do: Repo.rollback({:execution_limits_widen, "wall_time_seconds"})
  end

  defp enforce_deadline_ceiling!(_turn, _deadline_at, _limits), do: :ok

  # A session id is interpolated into a provider termination request, so it is
  # validated as an opaque token rather than trusted as a string: unreserved
  # URL characters only (RFC 3986 minus `.` and `~`), bounded length. Every
  # session id the pinned adapters issue is a UUID or a base62 token, and both
  # fit. This is deliberately narrower than "what a provider might send" — a
  # rejected identity fails loudly at bind time, where the turn is still the
  # owner's to retry, and that is the better half of the trade against a
  # separator reaching a URL path.
  defp valid_session_id?(id),
    do: is_binary(id) and byte_size(id) in 1..256 and Regex.match?(~r/\A[A-Za-z0-9_-]+\z/, id)

  defp update!(%TurnExecution{} = row, attrs),
    do: row |> TurnExecution.changeset(attrs) |> Repo.update!()

  defp update!(%Turn{} = row, attrs), do: row |> Turn.changeset(attrs) |> Repo.update!()

  defp record_event(execution, event) do
    Audit.record(%{
      user_id: execution.user_id,
      action: "conversation.execution_#{event}",
      resource_type: "conversation",
      resource_id: execution.conversation_id,
      actor: "system:turn_deadline",
      metadata: %{"turn_id" => execution.turn_id}
    })
  end

  defp transaction(fun) do
    case Repo.transaction(fun) do
      {:ok, {result, execution, event}} ->
        if event, do: record_event(execution, event)

        {:ok, result}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
