defmodule Fountain.Conversations.ConversationServer do
  @moduledoc """
  Owns one running conversation: its sprite, the active runtime command (if
  any), and the per-turn state. Streams sprite stdout/stderr into the DB
  (LogEvent rows) and broadcasts on Phoenix.PubSub topic `"conv:<id>"` so
  SSE subscribers can tail it live.

  Lifecycle:
    pending → starting → ready ⇄ running → terminated|failed
  """

  use GenServer, restart: :transient
  require Logger
  require OpenTelemetry.Tracer

  alias Fountain.{
    Agents,
    Conversations,
    Environments,
    Vaults
  }

  alias Fountain.Conversations.{BoundedTurn, CallbackKey, Checkpoints, Connection}
  alias Fountain.Conversations.{Conversation, DetachedRequest, Egress}
  alias Fountain.Conversations.{Lifecycle, MachineEvents, McpServers, Output}
  alias Fountain.Conversations.{Pending, Provisioning, ProvisionWatchdog, Reapply}
  alias Fountain.Conversations.{Reattachment, Redaction, SpriteEnv, TurnLaunch, TurnMachine}

  defguardp retired_or_resetting(reason)
            when reason == :sandbox_reset_pending or
                   (is_struct(reason, Ecto.Changeset) and
                      reason.errors == [status: {"sandbox is retired", []}])

  # ── public api ────────────────────────────────────────────────────────────

  def start_link(args) do
    conv_id = Keyword.fetch!(args, :conversation_id)
    GenServer.start_link(__MODULE__, args, name: via(conv_id))
  end

  def via(conv_id), do: {:via, Horde.Registry, {Fountain.ConversationRegistry, conv_id}}

  def whereis(conv_id) do
    case Horde.Registry.lookup(Fountain.ConversationRegistry, conv_id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @registry_settle_ms 3_000
  @registry_poll_ms 50

  @doc """
  `whereis/1`, but willing to wait for the registry to catch up.

  Horde's registry is a CRDT: a server started on another node is visible here
  only once the delta has synced, milliseconds normally and longer under load.
  A caller that already knows a server *should* exist — the sandbox row says
  `pending` — polls for `:conversation_registry_settle_ms` (#{@registry_settle_ms} ms)
  and never decides on one lookup (#1429). Returns `{:ok, pid}` or `:timeout`.

  This is what keeps a `session/new` + first-prompt pair from provisioning two
  sprites for one conversation when the requests land on different pods (#800):
  the prompt used to miss the registry and take `:create_new` while the first
  server was 20 s from finishing.
  """
  def await_registered(conv_id, timeout_ms \\ nil) do
    timeout_ms =
      timeout_ms ||
        Application.get_env(:fountain, :conversation_registry_settle_ms, @registry_settle_ms)

    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_await_registered(conv_id, deadline, 1)
  end

  # `owed` is lookups still due whatever the clock says: the deadline is set
  # before the first, so a stall used to end this after one poll (#1429, #800).
  defp do_await_registered(conv_id, deadline, owed) do
    case whereis(conv_id) do
      pid when is_pid(pid) ->
        {:ok, pid}

      nil ->
        if owed <= 0 and System.monotonic_time(:millisecond) >= deadline do
          :timeout
        else
          Process.sleep(@registry_poll_ms)
          do_await_registered(conv_id, deadline, owed - 1)
        end
    end
  end

  @doc """
  Send another prompt. If the conversation's GenServer is gone (e.g. server
  restart), transparently wake the conversation — provision a fresh sprite
  and queue this prompt as the first turn of the new sandbox.

  The persisted `runtime_session_id` is what the next turn resumes by
  (`session/resume` under ACP). Note that it only carries the conversation
  while the *sandbox* survives: a runtime session lives in the sandbox
  filesystem, so a wake that provisions a fresh sprite cannot resume it. The
  server clears the id when it provisions fresh (#778, `TurnMachine.forget_runtime_session/4`)
  and the next turn starts a new session on the new disk; `log_events` still
  render the whole transcript.
  """
  def send_prompt(conv_id, prompt, images \\ [], opts \\ []) do
    result =
      case whereis(conv_id) do
        nil ->
          case Conversations.wake_conversation(conv_id, prompt) do
            {:ok, _conv} -> :ok
            {:error, :gone} -> {:error, :gone}
            {:error, :not_found} -> {:error, :not_running}
            {:error, _} = err -> err
          end

        pid ->
          call_server(pid, {:send_prompt, prompt, images})
      end

    # Size and image count, never the text. A prompt is the tenant's content —
    # frequently the most sensitive thing in the system — and #545 is explicit
    # that the trail records that a prompt happened, not what it said.
    audit_lifecycle(conv_id, "conversation.prompted", result, opts, %{
      "prompt_bytes" => byte_size(prompt),
      "image_count" => length(images)
    })

    result
  end

  # Every public entry point calls through here so a GenServer.call exit
  # cannot escape to the caller (#412). The realistic exit is :timeout: a
  # handle_continue(:provision) blocks the mailbox for up to the provision
  # deadline, so any call issued during provisioning waits 30s and then
  # *exits* — which none of the seven controller/LiveView call sites caught,
  # turning prompt/interrupt/terminate into 500s and making
  # delete_conversation/1 return before its Repo.delete. :noproc and
  # shutdown-shaped exits are the server dying between whereis and call.
  defp call_server(pid, msg) do
    GenServer.call(
      pid,
      msg,
      Application.get_env(:fountain, :conversation_call_timeout_ms, 30_000)
    )
  catch
    :exit, {:timeout, _} -> {:error, :provisioning}
    :exit, {:noproc, _} -> {:error, :not_running}
    :exit, {:normal, _} -> {:error, :not_running}
    :exit, {:shutdown, _} -> {:error, :not_running}
    :exit, {{:shutdown, _}, _} -> {:error, :not_running}
  end

  @doc """
  Deliver the prompt a conversation was started for, after the server exists.

  Deliberately not a `start_link` argument. Horde restarts a redistributed
  child from its *stored child spec*, so anything in there is replayed on every
  cluster membership change — which every deploy causes. A prompt in the spec
  therefore re-ran the user's last message on each rollout.

  Takes the pid `start_child` returned, not the conversation id: Horde's
  registry is a CRDT whose registrations propagate asynchronously, and a cast
  to a via-name that hasn't resolved yet is a silent no-op — the server
  provisions, the user's first prompt is simply gone (#367). The pid needs no
  resolution, works across nodes, and is for exactly the server just started;
  if that server already died, losing the cast is the right outcome.

  A cast rather than a call: it queues behind `handle_continue(:provision)`,
  which can take minutes, and no caller is waiting on the turn to finish.
  """
  def queue_initial_prompt(pid, prompt, images \\ []) when is_pid(pid) do
    GenServer.cast(pid, {:initial_prompt, prompt, images})
  end

  @doc """
  Interrupt the turn in flight, if any.

  A miss on the registry does not mean there is nothing to interrupt, and
  `Conversations.wake_for_interrupt/1` owns what a miss means: it wakes a
  conversation the row still calls `running`, and separates "no such
  conversation" (`:not_found`) from "nothing to interrupt" (`:not_running`).
  """
  def interrupt(conv_id, opts \\ []) do
    # ownership: public callers established the conversation's tenant before
    # this boundary. Bounded cancellation commits before any actor/provider I/O.
    result =
      case Fountain.Conversations.ExecutionGuard._unsafe_interrupt(conv_id) do
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

    audit_lifecycle(conv_id, "conversation.interrupted", result, opts)
    result
  end

  defp interrupt_dead(conv_id) do
    case Conversations.wake_for_interrupt(conv_id) do
      {:ok, pid} -> call_server(pid, :interrupt)
      {:error, _} = err -> err
    end
  end

  @doc """
  Answer an outstanding permission request (#940).

  Tenant scoping is the caller's job — reach this through
  `Conversations.answer_permission_request/4`, which establishes ownership
  first.

  `{:error, :no_pending_permission}` covers every "too late": another attached
  client answered it, the timeout denied it, the turn ended, or the server is
  no longer running. That is deliberately not distinguished from "never
  existed" — a client that lost the race and a client guessing ids get the same
  answer.
  """
  @spec answer_permission(binary(), String.t(), String.t()) ::
          :ok | {:error, :no_pending_permission | :unknown_option | :not_running}
  def answer_permission(conv_id, request_id, option_id) do
    case whereis(conv_id) do
      nil -> {:error, :not_running}
      pid -> call_server(pid, {:answer_permission, request_id, option_id})
    end
  end

  ## ─── The tool bridge (#1202, `Fountain.CallerTools`) ─────────────────────

  @doc """
  Park a caller-tool call the agent just made. The call gets an id, a
  `caller_tool`/`started` stage event goes out (which is what closes the
  client's completion with `tool_calls`), and a deadline is armed. `waiter`
  receives `{:caller_tool_result, id, result}` when the call resolves.

  `{:error, :no_turn}` when nothing is running: a call needs a turn to belong
  to, and the client following that turn is the only party that can answer.
  """
  @spec park_caller_tool(binary(), String.t(), map(), pid()) ::
          {:ok, String.t()} | {:error, :not_running | :no_turn}
  def park_caller_tool(conv_id, name, arguments, waiter) do
    case whereis(conv_id) do
      nil -> {:error, :not_running}
      pid -> call_server(pid, {:park_caller_tool, name, arguments, waiter})
    end
  end

  @doc """
  Re-attach `waiter` to a parked call (the MCP handler's in-request wait ran
  out and the agent is asking again). `{:ok, result}` at once if it resolved
  meanwhile — a result is kept until the turn ends, so an answer that landed
  between two waits is not lost.
  """
  @spec await_caller_tool(binary(), String.t(), pid()) ::
          {:ok, {:ok, String.t()} | {:error, String.t()}}
          | :pending
          | {:error, :unknown_call | :not_running}
  def await_caller_tool(conv_id, call_id, waiter) do
    case whereis(conv_id) do
      nil -> {:error, :not_running}
      pid -> call_server(pid, {:await_caller_tool, call_id, waiter})
    end
  end

  @doc "The calls parked and unanswered, oldest first: `%{id, name, arguments, turn_id}`."
  @spec pending_caller_calls(binary()) :: [map()]
  def pending_caller_calls(conv_id) do
    case whereis(conv_id) do
      nil -> []
      pid -> call_server(pid, :pending_caller_calls)
    end
  end

  @doc """
  Resolve parked calls with the client's answers, `%{call_id => content}`.
  Ids that match nothing are ignored; if none match, `{:error, :no_pending_calls}`
  and nothing changes. Returns the turn the calls belong to and whatever is
  still parked, so the controller can emit the remainder at once instead of
  waiting for a stage event that is already behind its cursor.
  """
  @spec answer_caller_tools(binary(), %{String.t() => String.t()}) ::
          {:ok, %{turn_id: binary() | nil, remaining: [map()]}}
          | {:error, :no_pending_calls | :not_running}
  def answer_caller_tools(conv_id, answers) when is_map(answers) do
    case whereis(conv_id) do
      nil -> {:error, :not_running}
      pid -> call_server(pid, {:answer_caller_tools, answers})
    end
  end

  @doc """
  Terminate the conversation. If the GenServer is alive, it tears down the
  sprite. If not, just mark the DB rows terminated so the user can still
  clean up dead conversations after a server restart.

  An enclosing database transaction is refused before contacting the actor or
  updating rows, so teardown cannot escape a caller's rollback.

  Named `terminate_conversation` rather than `terminate`: taking `opts` for
  audit attribution (#545) would have made this `terminate/2`, which is the
  OTP callback below. Two different meanings under one name in one module was
  already a readability trap — `ConversationServer.terminate/1` (stop this
  tenant's conversation) and `terminate/2` (OTP teardown) are unrelated — so
  the client half gets the unambiguous name.
  """
  def terminate_conversation(conv_id, opts \\ []) do
    if Fountain.Repo.in_transaction?() do
      {:error, :provider_transaction_open}
    else
      # ownership: callers established this conversation's tenant. Cleanup must
      # survive a blocked actor, failed provider teardown, or subsequent deletion.
      case Fountain.Conversations.ExecutionGuard._unsafe_interrupt(conv_id) do
        {:ok, _} -> terminate_after_retirement(conv_id, opts)
        {:error, :not_found} -> {:error, :not_running}
        {:error, _} = error -> error
      end
    end
  end

  defp terminate_after_retirement(conv_id, opts) do
    result =
      case whereis(conv_id) do
        nil ->
          case Conversations._unsafe_get_conversation(conv_id) do
            nil ->
              {:error, :not_running}

            conv ->
              with {:ok, terminated} <-
                     Conversations.update_conversation(conv, %{status: "terminated"}) do
                Lifecycle.retire_terminated_sandbox(terminated, opts)
              end
          end

        pid ->
          # This pid is routinely on another pod, and mid-deploy some pods
          # predate the tuple clause: they answer the catch-all with
          # `:unknown_call`, which would leave the sprite running and billing.
          # Retry the bare atom they understand. Only that catch-all produces
          # `:unknown_call` here and it has no side effects, so no double
          # terminate; #1980 keeps the mirror clause for old-pod callers.
          case call_server(pid, {:terminate_conv, Keyword.take(opts, [:actor, :request_ip])}) do
            {:error, :unknown_call} -> call_server(pid, :terminate_conv)
            other -> other
          end
      end

    audit_lifecycle(conv_id, "conversation.terminated", result, opts)
    result
  end

  @doc """
  End the conversation but keep its computer: the conversation goes
  `terminated` (past resuming, its transcript intact), the sandbox row and
  the sprite behind it are left exactly as they are, and this server stops
  holding them. The callback key this server minted is revoked on the way
  out (`terminate/2`), so nothing on the sandbox can act as the retired
  conversation.

  This is how a teammate starts a fresh conversation on the same computer
  (`Fountain.Team.open_fresh_conversation/3`): the successor conversation
  takes the `sandbox_id`, and its first prompt reattaches through the
  ordinary wake path — a new runtime session on the same disk.

  `{:error, :busy}` while a turn runs on a **live** server; nothing is
  interrupted. With no server alive that row is as likely an orphan (see
  `Conversations.wake_for_interrupt/1`), so release proceeds. Unresolved
  bounded execution answers `{:error, :execution_fenced}` either way: a
  durable fact rather than an inference, and bounded (ADR 0046).

  Audited as `conversation.released` unless `audit: false`.
  """
  def release_conversation(conv_id, opts \\ []) do
    result =
      case whereis(conv_id) do
        nil ->
          Conversations._unsafe_release_conversation(conv_id, actor_alive?: false)

        pid ->
          call_server(pid, :release_conv)
      end

    audit_lifecycle(conv_id, "conversation.released", result, opts)
    result
  end

  @doc """
  Apply the conversation's current selection to the machine it is running on.

  The conversation context calls this after it writes the new selection. A
  server that is not running needs nothing: the next wake builds from the row,
  which already says what to build. `revision` lets a server that has already
  loaded that selection answer without doing the work again, which is what a
  notification arriving after the server reloaded on its own looks like. See
  `Fountain.Conversations.Reapply`.

  Three answers, because "nothing is stale" and "a machine has read this" are
  different facts and only the second earns a `configuration`/`done` event:

    * `{:ok, :reloaded}` — a live server has the new selection;
    * `{:ok, :no_server}` / `{:ok, :no_machine}` — there was nothing to tell,
      so nothing was rewritten and the next wake builds from the row;
    * `{:error, reason}` — a live server holds the previous selection and
      could not be told.

  Only the first means a machine was reconfigured. A caller that treats the
  middle pair as success is right about the selection and wrong about the
  machine, which is the distinction `announce_reapply/2` publishes.
  """
  @spec refresh_configuration(String.t(), integer() | nil) ::
          {:ok, :reloaded | :no_server | :no_machine} | {:error, term()}
  def refresh_configuration(conv_id, revision \\ nil) do
    case whereis(conv_id) do
      nil -> {:ok, :no_server}
      pid -> call_server(pid, {:refresh_configuration, revision})
    end
  end

  # Records a lifecycle action against the conversation's owner.
  #
  # Only on success: an attempt against a conversation that is not running
  # changed nothing, and a trail that logged it would show terminations that
  # never happened.
  #
  # `audit: false` suppresses the row where a caller's own higher-level event
  # already describes the action — `delete_conversation/2` and account
  # deletion both cascade through `terminate/2`, and neither is a second thing
  # the user asked for.
  #
  # The `_unsafe_` read is legitimate here under the rule in CLAUDE.md: these
  # are GenServer client functions, reached only after a tenant-scoped fetch
  # established ownership at the controller or LiveView, and the read exists
  # solely to attribute the event to that same owner.
  defp audit_lifecycle(conv_id, action, result, opts, metadata \\ %{}) do
    if Keyword.get(opts, :audit, true) and result == :ok do
      case Conversations._unsafe_get_conversation(conv_id) do
        nil ->
          :ok

        conv ->
          Fountain.Audit.record(%{
            user_id: conv.user_id,
            action: action,
            resource_type: "conversation",
            resource_id: conv_id,
            actor: Keyword.get(opts, :actor, "self"),
            request_ip: Keyword.get(opts, :request_ip),
            metadata: metadata
          })
      end
    end

    :ok
  end

  # ── GenServer ─────────────────────────────────────────────────────────────

  @impl true
  def init(args) do
    # Without trap_exit, terminate/2 only runs on {:stop, …} or a raise — a
    # Horde rebalance or application shutdown (i.e. every deploy) sends an
    # exit signal and skips it, so the callback-token revoke never fired on
    # the most common teardown there is (#322). Trapping makes OTP call
    # terminate/2 on supervisor shutdown, bounded by the child shutdown
    # timeout.
    Process.flag(:trap_exit, true)

    state = %{
      conversation_id: Keyword.fetch!(args, :conversation_id),
      sandbox_id: Keyword.fetch!(args, :sandbox_id),
      runtime_module: Keyword.fetch!(args, :runtime_module),
      user_id: nil,
      handle: nil,
      sprite_env: [],
      # ADR 0019 gate 1a. `brokered` holds the catalog secrets the sandbox
      # never sees (the broker gets them); `broker` is the minted session.
      # Both stay empty/nil on an unbrokered conversation.
      brokered: %{},
      # The tenant's enabled bindings by key (gate 1b), loaded once per
      # provision; what the broker's services are built from.
      broker_bindings: %{},
      # The env var names of the tenant's connections brokered into this
      # conversation (#1178): their access tokens rotate hourly, so each turn
      # kick re-reads them and rewrites the session's rules when one has
      # changed.
      connection_keys: [],
      # Where the tenant's own brokered secrets came from and which keys they
      # were (#1736); `Egress.refresh_before_turn/1` reads the rows again.
      secret_sources: nil,
      tenant_keys: [],
      # This conversation's one resolved MCP configuration (#1404). See
      # `McpServers.resolve_for_session/2`.
      resolved_mcp_servers: nil,
      # The environment's networking shape, enforced at the broker (gate 2).
      broker_network: :unrestricted,
      # What the runtime's default_env/2 is handed (gate 3): the real
      # credentials, or placeholders when the conversation is brokered.
      env_credentials: %{},
      # #1388, ADR 0053: the `InferenceCredentials.Source` that ran this one.
      inference_source: nil,
      inference_model: nil,
      broker: nil,
      current_command: nil,
      current_command_ref: nil,
      turn_execution: nil,
      execution_transport: nil,
      current_turn: nil,
      # The conversation's `configuration_revision` as this server last read
      # it. Turn admission is checked against it (#1565).
      configuration_revision: 0,
      # A runner's processes survive its websocket. Keep an accepted ACP
      # turn busy while its transport reconnects, with one bounded deadline.
      runner_reconnect: nil,
      runner_replay: nil,
      runtime_session_id: nil,
      # OTel span context for the in-flight turn (started in kick_turn,
      # ended in the :exit / :interrupt handlers).
      current_turn_span: nil,
      # Aggregate-metric bookkeeping for the in-flight turn (#536, #535):
      # `%{started_mono: ms, runtime: "claude", provider: "sprites", first_output?: bool}`, set
      # once the turn's command is spawned and dropped on every terminal
      # path. nil whenever no turn is running. Monotonic rather than the
      # turn row's timestamps because `now/0` truncates to the second,
      # which rounds a sub-second turn to a duration of zero.
      turn_metrics: nil,
      # Stream tracer for parsing Claude's stream-json stdout into OTel
      # child spans and events. nil for non-Claude runtimes.
      stream_tracer: nil,
      # The `session_gone` detail this turn has already been restarted for
      # (#1667), or nil. `TurnMachine` reads it to refuse a second restart.
      turn_session_retry: nil,
      # The ACP peer driving the in-flight turn, when the agent has opted in
      # (0014 gate 2). nil on the legacy path, which is the default. Monitored
      # rather than linked: a protocol bug must fail a turn, not take down a
      # server that is holding a sprite handle and a tenant's secrets.
      acp_peer: nil,
      # Timer refusing an unanswered permission request (#940).
      permission_timer: nil,
      # The last `session/request_permission` the peer relayed, as
      # `DetachedRequest.request_line/2` reads it (#1635): the ask that follows
      # carries no params, and the per-request timeout is in theirs.
      acp_request_params: nil,
      # Caller-tool calls parked on the turn (#1202): id => %{name, arguments,
      # turn_id, waiter, timer, result}. `result` is nil while parked and the
      # answer once resolved; entries are dropped when the turn ends.
      caller_calls: %{},
      acp_peer_mon: nil,
      # Timer closing an autonomous turn that went quiet without a
      # `cycle_end` (#817) — an adapter too old to mark its origin must not
      # hold a turn open forever. nil outside an autonomous turn.
      autonomous_quiet: nil,
      # Bytes of replayed output to drop on reattach, keyed by stream.
      # Empty map outside a reattach window. See attempt_session_attach.
      replay_skip: %{},
      # ACP reattach: the `acp` lines already persisted for the in-flight
      # turn, so the sprite's replayed tail is not written twice. Consumed as
      # matches arrive and cleared on a timer; empty outside a reattach
      # window. See attempt_session_attach.
      replay_dedup: MapSet.new(),
      # Per-tenant DEK + decrypted inference credentials. Loaded in
      # handle_continue(:provision) once the conversation row tells us the
      # owning user_id; held for the conversation lifetime; dropped on
      # terminate. See ADR 0008 (BYO inference credentials).
      tenant_key: nil,
      inference_credentials: %{},
      # Plaintext of the per-conversation API key that's injected into the
      # sprite as FOUNTAIN_TOKEN. The hash and a row in `api_keys` is the
      # durable record; we keep the raw value in memory only while this
      # GenServer is alive. Rotated on every fresh provision/reattach;
      # revoked in terminate/2.
      callback_token: nil,
      # The id of the key THIS server minted. Revocation acts only on this
      # id, never on whatever the conversation row currently points at:
      # duplicate servers exist (Horde CRDT merges mass-terminate losers,
      # registry lag starts seconds-apart doubles — #367), and a server
      # that revokes the row's key can be revoking the credential the
      # SURVIVING server's sprite is actively using.
      callback_api_key_id: nil,
      # Sandbox lifetime bookkeeping. `started_at` is set once the sprite
      # exists; `last_activity_at` moves on every turn start and end. See
      # Fountain.Conversations.Lifecycle for what the bounds are and why
      # reclaiming a sandbox does not end the conversation.
      sandbox_started_at: nil,
      last_activity_at: DateTime.utc_now(),
      # Durable-output budget bookkeeping (#331). `output_bytes` is loaded
      # lazily from the DB on the first output of this server's lifetime, so
      # the budget is cumulative per conversation across wakes rather than
      # per BEAM lifetime.
      output_bytes: nil,
      output_capped: false
    }

    Lifecycle.schedule_check()
    ProvisionWatchdog.start(state.conversation_id, state.sandbox_id)
    {:ok, state, {:continue, :provision}}
  end

  @impl true
  # A prompt that lost the race to a reapply: rebuild from the row it has not
  # read, then deliver the prompt against it.
  def handle_continue({:reapply_prompt, prompt, images}, state) do
    case handle_continue(:provision, state) do
      {:noreply, fresh} -> handle_cast({:initial_prompt, prompt, images}, fresh)
      stopped -> stopped
    end
  end

  def handle_continue(:provision, state) do
    conv = Conversations._unsafe_get_conversation(state.conversation_id)
    sandbox = state.sandbox_id && Conversations._unsafe_get_sandbox(state.sandbox_id)

    if is_nil(conv) or is_nil(sandbox) do
      # A conversation or sandbox deleted between start_child and this
      # continue used to raise Ecto.NoResultsError — unrescued, in a
      # restart: :transient child, so the supervisor restarted it straight
      # back into the same raise. That burns the supervisor's SHARED
      # restart budget, and exhausting it terminates every conversation on
      # the node. A server whose rows are gone has nothing to provision.
      Logger.warning(
        "conv #{state.conversation_id}: row missing before provisioning " <>
          "(conversation_gone=#{is_nil(conv)}, sandbox_gone=#{is_nil(sandbox)}); stopping"
      )

      {:stop, :normal, state}
    else
      # ownership: this newly started actor fetched its parent above. A journal
      # left by another incarnation is retired, never reattached or replayed.
      case Fountain.Conversations.ExecutionGuard._unsafe_interrupt(conv.id) do
        {:ok, :unbounded} -> provision_with_rows(state, conv, sandbox)
        {:ok, {:bounded, _}} -> {:stop, :normal, state}
        {:error, _} -> {:stop, :normal, state}
      end
    end
  end

  defp provision_with_rows(state, conv, sandbox) do
    # Non-bang for the same reason as the rows above: a deleted agent must
    # not crash-loop the server. Provisioning proceeds without it, exactly
    # as for a conversation created with no agent.
    agent = conv.agent_id && Agents._unsafe_get_agent(conv.agent_id)

    if conv.agent_id && is_nil(agent) do
      Logger.warning("conv #{conv.id}: agent #{conv.agent_id} is gone; provisioning without it")
    end

    # The conversation's own override wins over the agent's environment (#783);
    # nil falls back to the agent's, resolved fresh each provision.
    #
    # Scoped by the conversation's owner even though create/update_agent and
    # start_conversation already validate ownership: a cross-tenant
    # environment_id that predates that check (or slips in through a future
    # path) must not materialise another tenant's secrets or checkpoint here.
    env_id = conv.environment_id || (agent && agent.environment_id)

    env =
      if env_id do
        case Environments.get_environment(env_id, conv.user_id) do
          nil ->
            Logger.warning(
              "conv #{conv.id}: environment #{env_id} " <>
                "not owned by user #{conv.user_id}; provisioning without it"
            )

            nil

          env ->
            env
        end
      end

    vault = if conv.vault_id, do: Vaults._unsafe_get_vault(conv.vault_id)

    case SpriteEnv.load_tenant_state(conv.user_id) do
      {:ok, dek, own_creds} ->
        # Before the selection: a tenant secret named after a credential wins
        # in the sandbox, so it decides the source too (ADR 0053 decision 5).
        tenant_secrets = SpriteEnv.merge_secrets(env, vault, dek)

        {inference_source, inference_creds} =
          SpriteEnv.select_inference(agent, own_creds, conv.runtime, tenant_secrets)

        bindings = Egress.bindings(conv.user_id)

        {merged, bindings, connection_keys} =
          Egress.add_connection_secrets(conv.user_id, tenant_secrets, bindings, agent)

        {secrets, brokered} = Egress.split_brokered(merged, bindings)

        # The tenant's own brokered keys: what the environment and vault
        # rows contributed, less the connection tokens (#1736). Read again
        # before each turn by `broker_refresh/1`.
        tenant_keys = (brokered |> Map.keys() |> Enum.sort()) -- connection_keys

        {env_creds, brokered, bindings} =
          Egress.split_inference(inference_creds, brokered, bindings)

        state =
          %{
            state
            | user_id: conv.user_id,
              # Load-bearing placement: this is the one state assembly both the
              # fresh-provision and the reattach arms of dispatch_provision/7
              # come through. In either arm instead, a server that reloads
              # after `:configuration_changed` would come back holding the old
              # revision, and kick_turn -> :reapply_prompt -> :provision would
              # spin against the database (#1565).
              configuration_revision: conv.configuration_revision,
              runtime_session_id: conv.runtime_session_id,
              tenant_key: dek,
              inference_credentials: inference_creds,
              inference_source: inference_source,
              inference_model: agent && agent.model,
              env_credentials: env_creds,
              brokered: brokered,
              broker_bindings: bindings,
              connection_keys: connection_keys,
              secret_sources: %{environment_id: env && env.id, vault_id: vault && vault.id},
              tenant_keys: tenant_keys,
              broker_network: Fountain.Broker.network_for(env)
          }

        dispatch_provision(state, conv, sandbox, agent, env, vault, secrets)

      {:error, reason} ->
        Logger.error(
          "ConversationServer could not load tenant credentials for conv #{conv.id} (user #{conv.user_id}): #{inspect(reason)}"
        )

        Output.publish_stage(state.conversation_id, "provision", "failed", %{
          reason: "tenant_credential_load_failed: #{inspect(reason)}"
        })

        {:ok, _} = Conversations.update_sandbox(sandbox, %{status: "failed"})
        Conversations.update_conversation(conv, %{status: "failed"})
        {:stop, :normal, state}
    end
  end

  defp dispatch_provision(state, conv, sandbox, agent, env, _vault, secrets) do
    case McpServers.substitute_agent(agent, env, secrets) do
      {:ok, agent} ->
        state = %{state | resolved_mcp_servers: agent && agent.mcp_servers}

        case sandbox.status do
          s when s in ["ready", "suspended"] ->
            # The sprite already exists at sprites.dev and was fully provisioned
            # in a previous BEAM lifetime. Reattach instead of recreating.
            # `suspended` normally becomes `ready` under the quota reservation
            # in wake_conversation before this server starts; seeing it here
            # means the reaper parked the row mid-wake. Reattaching is still
            # right — the catch-all below would provision a second sprite over
            # a live one — and do_reattach flips the row back to ready.
            reattach(state, conv, sandbox, agent, env, secrets)

          s when s in ["pending", "starting"] ->
            fresh_provision(state, conv, sandbox, agent, env, secrets)

          terminal when terminal in ["terminated", "failed"] ->
            Logger.warning(
              "ConversationServer started for terminal conv #{conv.id} (#{terminal})"
            )

            {:stop, :normal, state}

          _ ->
            fresh_provision(state, conv, sandbox, agent, env, secrets)
        end

      {:error, {:missing_vars, names}} ->
        reason = "missing env/vault keys referenced in mcp_servers: #{Enum.join(names, ", ")}"
        Logger.error("provision failed for conv #{conv.id}: #{reason}")
        Output.publish_stage(state.conversation_id, "provision", "failed", %{reason: reason})
        {:ok, _} = Conversations.update_sandbox(sandbox, %{status: "failed"})
        Conversations.update_conversation(conv, %{status: "failed"})
        {:stop, :normal, state}
    end
  end

  defp fresh_provision(state, conv, sandbox, agent, env, secrets) do
    Fountain.Telemetry.span(
      [:fresh_provision],
      %{conv_id: state.conversation_id, sandbox_id: sandbox.id, env_id: env && env.id},
      fn -> {do_fresh_provision(state, conv, sandbox, agent, env, secrets), %{}} end
    )
  end

  defp do_fresh_provision(state, conv, sandbox, agent, env, secrets) do
    try do
      case Conversations.update_sandbox(sandbox, %{status: "starting"}) do
        {:ok, _} ->
          do_fresh_provision_inner(state, conv, sandbox, agent, env, secrets)

        {:error, reason} when retired_or_resetting(reason) ->
          # No resources were created yet. Leave the winning retirement and
          # any replacement conversation alone, without announcing a start.
          {:stop, :normal, state}

        error ->
          raise MatchError, term: error
      end
    rescue
      exception ->
        stack = __STACKTRACE__
        msg = Exception.format(:error, exception, stack)
        Logger.error("provision raised an unhandled exception:\n#{msg}")

        Output.publish_stage(state.conversation_id, "provision", "failed", %{
          reason: Exception.message(exception),
          stack: Exception.format_stacktrace(stack) |> String.slice(0, 2000)
        })

        {:ok, _} = Conversations.update_sandbox(sandbox, %{status: "failed"})
        Conversations.update_conversation(conv, %{status: "failed"})
        {:stop, :normal, state}
    end
  end

  defp do_fresh_provision_inner(state, conv, sandbox, agent, env, secrets) do
    # Finding the original snapshot already `starting` means an earlier
    # attempt was interrupted mid-provision — a
    # deploy or a Horde rebalance killed the server while it was blocked in
    # this function. The sprite it was building is most likely still there.
    interrupted? = sandbox.status == "starting"

    Output.publish_stage(
      state.conversation_id,
      "provision",
      "started",
      if(interrupted?,
        do: %{retry: "an earlier attempt was interrupted; rebuilding the sandbox"},
        else: %{}
      )
    )

    # A `limited` environment on a backend with no `:network_policy` capability
    # can only fail. It failed closed before, but several steps in, after a
    # sandbox had been created and torn down, and wearing the shape of a
    # transport error. Refuse the pairing here, by name, before anything is
    # provisioned (#935).
    provider = Fountain.Conversations.sandbox_provider_atom(sandbox)

    handle_result =
      with :ok <-
             Fountain.Conversations.Provisioning.check_network_policy_support(
               provider,
               env,
               state.conversation_id
             ),
           :ok <-
             Fountain.Conversations.Provisioning.check_broker_support(
               Egress.brokered?(),
               provider,
               env,
               state.conversation_id
             ),
           :ok <- Provisioning.discard_interrupted_attempt(provider, sandbox, interrupted?) do
        Provisioning.create_sandbox_handle(provider, sandbox)
      end

    case handle_result do
      {:ok, handle} ->
        skills = (agent && agent.skills) || []
        # conv.runtime is validated-required and outlives the agent; the agent
        # fallback covers rows predating it. The mount logs what it skipped.
        runtime = conv.runtime || (agent && agent.runtime) || "claude"
        Fountain.SandboxSkills.mount(handle, runtime, skills)

        {state, conv} = rotate_callback_api_key(state, conv)

        # Looked up once, here, because it is stable for the sandbox's life and
        # the agent needs it in its environment before the first turn runs.
        sandbox_url = Provisioning.record_sandbox_url(sandbox, handle)

        # The broker session is minted before the env is built, because the
        # env carries it; the CA is installed before anything dials out,
        # because nothing dials out without it (ADR 0019 gate 1a).
        # Keep the result outside `with`: its else cannot see the minted state.
        prepared = Egress.prepare_state(state)

        with {:ok, state} <- prepared,
             sprite_env = build_sprite_env(state, agent, env, secrets, sandbox_url),
             # A real step, not best effort: an agent whose MCP servers could
             # not be written would otherwise run without them and report
             # `provision/done`. The runtimes retry the write themselves.
             :ok <-
               Provisioning.write_runtime_config(
                 handle,
                 state.runtime_module,
                 Egress.with_connection_servers(
                   agent,
                   state.user_id,
                   state.conversation_id,
                   state.callback_token
                 )
               ),
             _ = Provisioning.write_instructions(handle, runtime, agent),
             # The file is the machine's; the conversation's identity travels as
             # process env on every spawn (`Fountain.Conversations.Identity`).
             _ =
               Fountain.Conversations.Provisioning.write_env_file(
                 handle,
                 Fountain.Conversations.Identity.disk_env(sprite_env)
               ),
             :ok <- Egress.install_ca(state.broker, handle, state.conversation_id),
             :ok <-
               run_provisioning_pipeline(
                 handle,
                 env,
                 sprite_env,
                 secrets,
                 state.conversation_id,
                 Egress.brokered?()
               ),
             :ok <-
               Provisioning.prepare_runtime_sprite(
                 handle,
                 runtime,
                 state.runtime_module,
                 agent,
                 sprite_env
               ),
             # Record what the disk was built from only if this attempt still
             # owns a live row. Retirement can win while provider I/O runs.
             {:ok, _} <-
               Conversations.update_sandbox(sandbox, %{
                 status: "ready",
                 build_fingerprint: Reapply.fingerprint(env),
                 applied_skills: skills
               }) do
          Output.publish_stage(state.conversation_id, "provision", "done")

          # Best-effort: snapshot the fully-provisioned state so subsequent
          # conversations on this env can warm-start from it. Async so it
          # doesn't block the user's first turn.
          Checkpoints.maybe_create_async(handle, env)

          state = TurnMachine.forget_runtime_session(state, conv)

          # Dated from the sandbox row, not from now, so the absolute lifetime
          # ceiling survives a restart and a reattach rather than resetting.
          new_state = %{
            state
            | handle: handle,
              sprite_env: sprite_env,
              sandbox_started_at: Lifecycle.clock_start(sandbox)
          }

          # Any prompt this conversation was started for arrives as a cast,
          # already queued behind this handle_continue. See
          # queue_initial_prompt/3.
          {:noreply, new_state}
        else
          {:error, reason} when retired_or_resetting(reason) ->
            # This handle and token belong to this attempt. Do not fail the
            # conversation or release every session: a replacement may own it.
            _ = Managoat.Sandbox.destroy(handle)
            Egress.release_prepared(prepared)
            {:ok, prepared_state} = prepared
            {:stop, :normal, prepared_state}

          {:error, reason} ->
            Logger.error("provision step failed: #{inspect(reason)}")
            _ = Managoat.Sandbox.destroy(handle)
            Egress.release_prepared(prepared)
            {:ok, _} = Conversations.update_sandbox(sandbox, %{status: "failed"})

            Output.publish_stage(state.conversation_id, "provision", "failed", %{
              reason: inspect(reason)
            })

            Conversations.update_conversation(conv, %{status: "failed"})
            {:stop, :normal, state}
        end

      {:error, reason} ->
        Logger.error("provision could not start: #{inspect(reason)}")
        {:ok, _} = Conversations.update_sandbox(sandbox, %{status: "failed"})

        Output.publish_stage(state.conversation_id, "provision", "failed", %{
          reason: inspect(reason)
        })

        Conversations.update_conversation(conv, %{status: "failed"})
        {:stop, :normal, state}
    end
  end

  # Try a checkpoint restore first if the env has one. If restore succeeds,
  # skip the slow steps (packages + clone + setup_script) — they all wrote to
  # the disk the checkpoint captured, so restoring it restores their effect.
  # If restore fails, clear the checkpoint id and fall through to the full
  # pipeline.
  #
  # The network policy is **not** one of those steps and is applied on both
  # arms (#989). It is configuration on the sandbox, not a file: a warm start
  # creates a fresh sandbox and pours a disk image into it, and that sandbox
  # carries no policy. Skipping it turned a `limited` environment into an
  # unrestricted one, silently, and reported `provision/done`. It costs one
  # fast API call, so the warm start pays nothing for it.
  defp run_provisioning_pipeline(handle, env, sprite_env, secrets, conv_id, brokered?) do
    case Checkpoints.attempt_warm_start(handle, env, conv_id) do
      :warm_started ->
        Egress.apply_policy(handle, env, conv_id, brokered?)

      :cold ->
        with :ok <-
               Fountain.Conversations.Provisioning.install_packages(
                 handle,
                 env,
                 sprite_env,
                 conv_id
               ),
             :ok <- Egress.apply_policy(handle, env, conv_id, brokered?),
             :ok <-
               Fountain.Conversations.Provisioning.clone_repositories(
                 handle,
                 env,
                 secrets,
                 sprite_env,
                 conv_id
               ) do
          Provisioning.run_setup_script(handle, env, sprite_env, conv_id)
        end
    end
  end

  defp reattach(state, conv, sandbox, agent, env, secrets) do
    Fountain.Telemetry.span(
      [:reattach],
      %{conv_id: state.conversation_id, sprite_name: sandbox.sprite_name},
      fn -> {do_reattach(state, conv, sandbox, agent, env, secrets), %{}} end
    )
  end

  # The `started` event is published **after** the sprite answers, not on the
  # way in, and that is deliberate (#971).
  #
  # A `ConversationServer` is a Horde child, so cluster churn stops and starts
  # it — every rebalance runs this function again from the top. Announcing on
  # entry turned that into a transcript: production logged 51 `reattach`
  # `started` events for one conversation inside one second, in lockstep with a
  # second conversation on the same node, and exactly one of them reached
  # `done`. Fifty of those describe a process that was replaced before it
  # touched anything, which is a fact about our supervision tree and not about
  # the user's conversation.
  #
  # The provider round trip outlives a rebalance, so a start that is going to
  # be replaced is replaced before this line and writes nothing. What survives
  # to publish has a live sprite and is really reattaching.
  #
  # The node is stamped on every reattach event for the same incident: it is
  # what tells a redistribution storm (many nodes, one conversation) from a
  # crash loop (one node, restarting) without guessing.
  defp do_reattach(state, conv, sandbox, agent, env, secrets) do
    handle =
      Managoat.Sandbox.build_handle(
        Fountain.Conversations.sandbox_provider_atom(sandbox),
        sandbox.sprite_name
      )

    # A broker failure lands in the transient arm below: it says nothing
    # about the sandbox, and the next wake mints again.
    with {:ok, _info} <-
           Managoat.Sandbox.Retry.with_backoff(
             fn -> Managoat.Sandbox.get(handle) end,
             label: "sprite lookup on wake"
           ),
         {:ok, state} <- Egress.prepare_state(state),
         :ok <- Egress.reattach_policy(handle, env, state.conversation_id) do
      Output.publish_stage(state.conversation_id, "reattach", "started", %{
        sprite_name: sandbox.sprite_name,
        node: to_string(node())
      })

      {state, _conv} = rotate_callback_api_key(state, conv)
      sprite_env = build_sprite_env(state, agent, env, secrets)

      # The callback token just rotated, and for claude the connection MCP
      # servers carry it in `.mcp.json` (#1178): rewrite the file so the
      # next turn's tools authenticate. Idempotent for an agent without one.
      # Best effort here, like the CA below: the turn's own failure says more
      # than a refused wake would.
      case Provisioning.write_runtime_config(
             handle,
             state.runtime_module,
             Egress.with_connection_servers(
               agent,
               state.user_id,
               state.conversation_id,
               state.callback_token
             )
           ) do
        :ok -> :ok
        {:error, reason} -> Logger.warning("runtime config write on wake: #{inspect(reason)}")
      end

      # A machine provisioned before its tenant was brokered has no CA yet;
      # on one that has it this is an idempotent rewrite. Best effort here:
      # the turn's own failure says more than a refused wake would.
      case Egress.install_ca(state.broker, handle, state.conversation_id) do
        :ok -> :ok
        {:error, reason} -> Logger.warning("broker CA install on wake: #{inspect(reason)}")
      end

      # Refresh the .env file in case secrets/env_vars were edited
      # between the original provision and this reattach.
      # The file is the machine's; the conversation's identity travels as
      # process env on every spawn (`Fountain.Conversations.Identity`).
      Fountain.Conversations.Provisioning.write_env_file(
        handle,
        Fountain.Conversations.Identity.disk_env(sprite_env)
      )

      # An agent's skills reach the existing computer on its next wake too,
      # and a skill it no longer names is taken off the disk (#1565).
      Reapply.mount_skills(handle, conv, agent)

      # Same for the agent's system prompt: an edit reaches the existing
      # computer on its next wake (#848).
      runtime = conv.runtime || (agent && agent.runtime) || "claude"
      Provisioning.write_instructions(handle, runtime, agent)

      # The credential path can change between provision and wake (ADR 0047:
      # a grant connected, revoked or disconnected in between), and codex's
      # auth.json is written at provisioning. Re-prepare so the file matches
      # this spawn; best effort, like the rest of the wake.
      case Provisioning.prepare_runtime_sprite(
             handle,
             runtime,
             state.runtime_module,
             agent,
             sprite_env
           ) do
        :ok -> :ok
        {:error, reason} -> Logger.warning("runtime prepare on wake: #{inspect(reason)}")
      end

      # Validate even a cached ready row: retirement may have won while the
      # provider was waking. Only a suspended wake resets the lifetime clock.
      attrs =
        if sandbox.status == "suspended" do
          %{
            status: "ready",
            last_resumed_at: DateTime.utc_now() |> DateTime.truncate(:second)
          }
        else
          %{status: "ready"}
        end

      case Conversations.update_sandbox(sandbox, attrs) do
        {:ok, sandbox} ->
          new_state = %{
            state
            | handle: handle,
              sprite_env: sprite_env,
              sandbox_started_at: Lifecycle.clock_start(sandbox)
          }

          new_state = Reattachment.reattach_running_turn(%{new_state | current_turn: nil})

          new_state =
            Reattachment.finish_runner_reconnect(
              new_state,
              if(new_state.current_turn, do: "reattached", else: "turn_ended")
            )

          {:noreply, new_state}

        {:error, reason} when retired_or_resetting(reason) ->
          # Wake owns this connection's credentials, not the existing disk or
          # another connection's session. Never destroy the machine here.
          Egress.release_prepared({:ok, state})
          {:stop, :normal, state}

        error ->
          raise MatchError, term: error
      end
    else
      {:error, :not_found} ->
        # The provider says the sandbox is gone. That is the one answer that
        # justifies retiring the row: the disk no longer exists, so the next
        # prompt must provision fresh.
        Logger.warning(
          "reattach failed for sprite #{sandbox.sprite_name}: not found — marking sandbox failed"
        )

        Output.publish_stage(state.conversation_id, "reattach", "failed", %{
          reason: "not_found",
          retryable: false,
          node: to_string(node())
        })

        {:ok, _} =
          Conversations.update_sandbox(sandbox, %{
            status: "failed",
            terminated_at: DateTime.utc_now() |> DateTime.truncate(:second)
          })

        # Don't mark the conversation failed — the user can still send a
        # prompt and auto-wake will spin a fresh sandbox.
        {:stop, :normal, state}

      {:error, reason} ->
        # Anything else — a transport error, a timeout, a 5xx, a credential
        # problem — says nothing about the sandbox, only about our ability to
        # reach the provider right now. The row is left exactly as it was and
        # the server stops; the next prompt takes the same reattach path again.
        #
        # This arm used to mark the row `failed` too. On 2026-08-18 a 70-second
        # DNS outage did exactly that to nine live sandboxes at once (a Horde
        # failover re-ran reattach for every conversation on the partitioned
        # pod, and every probe answered nxdomain), and `SandboxReaper`'s
        # destroy pass would have taken the sprites — one of them holding a
        # completed turn and a live ACP session — an hour later (#799). A
        # transient failure must not become a destroyed disk; the same rule
        # `probe_sandbox/4` applies on the wake path.
        Logger.warning(
          "reattach failed for sprite #{sandbox.sprite_name}: #{inspect(reason)} — " <>
            "transient; sandbox row left untouched"
        )

        running_turn = Reattachment.find_running_turn(state.conversation_id)

        if sandbox.provider == "runner" and
             reason in [
               {:unavailable, :runner_offline},
               {:unavailable, :runner_disconnected}
             ] and not is_nil(running_turn) and not is_nil(running_turn.acp_prompt_id) do
          Reattachment.wait_for_runner(%{state | current_turn: running_turn}, &fail_transport/2)
        else
          Output.publish_stage(state.conversation_id, "reattach", "failed", %{
            reason: inspect(reason),
            retryable: true,
            node: to_string(node())
          })

          {:stop, :normal, state}
        end
    end
  end

  # ── sprite environment and egress (ADR 0019 gate 1a) ──────────────────────

  # The server's half of `SpriteEnv.build/4`: unpack what the state holds and
  # hand it over. The name stays because the tests and the comments that say
  # "build_sprite_env registers the secrets" still mean this call.
  defp build_sprite_env(state, agent, env, secrets, sandbox_url \\ nil) do
    SpriteEnv.build(agent, env, secrets,
      runtime_module: state.runtime_module,
      env_credentials: state.env_credentials,
      callback_token: state.callback_token,
      conversation_id: state.conversation_id,
      sandbox_id: state.sandbox_id,
      sandbox_url: sandbox_url,
      brokered: Egress.sandbox_env(state.broker)
    )
  end

  # The OAuth token was refused: forget it on both sides and, when brokered,
  # re-prepare the vault so the API key is what the substitution carries.
  # Best effort — a broker error here leaves the turn to fail at the proxy,
  # which names the cause, rather than silently injecting a plaintext key.
  defp broker_switch_to_api_key(%{broker: nil} = state), do: state

  defp broker_switch_to_api_key(state) do
    {env_creds, brokered, bindings} =
      Egress.drop_oauth_token(state.inference_credentials, state.brokered, state.broker_bindings)

    state = %{state | brokered: brokered, broker_bindings: bindings, env_credentials: env_creds}

    case Egress.reprepare(state.conversation_id, brokered, bindings, state.sprite_env,
           network: state.broker_network,
           user_id: state.user_id
         ) do
      {:ok, session, sprite_env} ->
        %{state | broker: session, sprite_env: sprite_env}

      {:error, reason} ->
        Logger.warning(
          "conv #{state.conversation_id}: broker re-prepare after OAuth refusal failed: #{inspect(reason)}"
        )

        state
    end
  end

  @impl true
  def handle_call({:send_prompt, prompt, images}, _from, state) do
    if Connection.user_turn_running?(state.current_turn) do
      {:reply, {:error, :busy}, state}
    else
      # This server already owns the conversation. Refuse before superseding
      # autonomous work or touching its connection; turn admission rechecks.
      conv = Conversations._unsafe_get_conversation!(state.conversation_id)

      with :ok <- Conversations._unsafe_check_saved_execution_allowance(conv.id),
           :ok <- TurnMachine.gate(conv.user_id, state.inference_source),
           :ok <- TurnMachine.capacity_gate(state.sandbox_id, conv) do
        state = close_autonomous_turn(state, "superseded_by_prompt")
        agent = if conv.agent_id, do: Agents._unsafe_get_agent!(conv.agent_id)

        # A bounded turn can be refused by admission under its row locks
        # (ADR 0046), and a caller that asked for a turn has to hear that.
        # Every other outcome keeps the cast shape `kick_turn/4` answers in.
        case kick_turn(state, prompt, agent, images) do
          {:error, reason, next} -> {:reply, {:error, reason}, next}
          cast_shape -> replying_ok(cast_shape)
        end
      else
        {:error, _} = err -> {:reply, err, state}
      end
    end
  end

  # Busy means a turn, not a connection (#817): an idle adapter between
  # turns is nothing to interrupt. An autonomous turn is interruptible — it
  # is the one way to cut a background task the agent left running.
  def handle_call(:interrupt, _from, %{current_turn: nil} = state) do
    {:reply, {:error, :idle}, state}
  end

  def handle_call(:interrupt, _from, state) do
    {:reply, :ok, interrupt_turn(state)}
  end

  # First answer wins (`Pending.answer_permission/6`): the web apps and an
  # editor (#708) are peer clients of this door, not fallbacks for one
  # another, so a second answer to the same request is "too late" rather
  # than an error in the caller.
  # `Pending.holds?/2` is the guard a detached request needs (#1635).
  def handle_call({:answer_permission, request_id, option_id}, _from, state) do
    if Pending.holds?(state.current_turn, request_id) do
      {reply, state} = Pending.answer(state, request_id, option_id)
      {:reply, reply, state}
    else
      {:reply, {:error, :no_pending_permission}, state}
    end
  end

  # A call needs a turn to belong to, and the client following that turn is
  # the only party that can answer.
  def handle_call({:park_caller_tool, name, arguments, waiter}, _from, state) do
    case state.current_turn do
      nil ->
        {:reply, {:error, :no_turn}, state}

      turn ->
        {call_id, pending} =
          Pending.park(
            Pending.from_state(state),
            state.conversation_id,
            turn,
            name,
            arguments,
            waiter
          )

        {:reply, {:ok, call_id}, Pending.into_state(state, pending)}
    end
  end

  def handle_call({:await_caller_tool, call_id, waiter}, _from, state) do
    {reply, pending} = Pending.await(Pending.from_state(state), call_id, waiter)
    {:reply, reply, Pending.into_state(state, pending)}
  end

  def handle_call(:pending_caller_calls, _from, state) do
    {:reply, Pending.calls(Pending.from_state(state)), state}
  end

  def handle_call({:answer_caller_tools, answers}, _from, state) do
    {reply, pending} =
      Pending.answer_calls(Pending.from_state(state), state.conversation_id, answers)

    {:reply, reply, Pending.into_state(state, pending)}
  end

  # Keep the legacy request during rollout; callers can adopt attribution
  # only after all nodes understand the tuple form.
  def handle_call(:terminate_conv, from, state),
    do: handle_call({:terminate_conv, []}, from, state)

  def handle_call({:terminate_conv, opts}, _from, state) when is_list(opts) do
    case prepare_termination(state, opts) do
      {:ok, sandbox} -> terminate_machine(state, sandbox)
      {:error, :sandbox_kept} -> terminate_kept_machine(state)
      {:error, _} = error -> {:reply, error, state}
    end
  end

  # End the conversation, keep the sandbox — see release_conversation/2. A
  # running turn is refused rather than interrupted: the caller decides
  # whether to cut the agent off. `handle: nil` on the way out so no stop
  # path (terminate/2 included) touches the sprite; the sandbox row is not
  # written at all — it stays `ready`, a parked disk with no server, exactly
  # what the wake path expects when the successor's first prompt arrives.
  def handle_call(:release_conv, _from, %{current_turn: turn} = state) when not is_nil(turn) do
    {:reply, {:error, :busy}, state}
  end

  def handle_call(:release_conv, _from, state) do
    case Conversations._unsafe_release_conversation(state.conversation_id) do
      :ok ->
        state = drop_connection(state, "released")
        Output.publish_stage(state.conversation_id, "terminate", "done", %{event: "released"})
        {:stop, :normal, :ok, %{state | handle: nil}}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  # A notification for the revision this server already holds is a no-op: it
  # reloaded on its own (`kick_turn`) before the message arrived.
  def handle_call({:refresh_configuration, revision}, from, state) do
    if revision == state.configuration_revision,
      do: {:reply, {:ok, :reloaded}, state},
      else: handle_call(:refresh_configuration, from, state)
  end

  def handle_call(:refresh_configuration, _from, %{current_turn: turn} = state)
      when not is_nil(turn),
      do: {:reply, {:error, :conversation_busy}, state}

  # Nothing to reconfigure without a machine; the next wake builds from the
  # row. Not a failure, and not a reload either: no file was rewritten, so this
  # must not be reported as a machine that holds the new selection.
  def handle_call(:refresh_configuration, _from, %{handle: nil} = state),
    do: {:reply, {:ok, :no_machine}, state}

  # The machine stays. Dropping the connection is what makes the next turn
  # spawn a runtime that reads the rewritten files and the fresh environment.
  def handle_call(:refresh_configuration, _from, state) do
    state = drop_connection(state, "configuration_reapplied")
    {:reply, {:ok, :reloaded}, %{state | handle: nil}, {:continue, :provision}}
  end

  # Catch-all: an unmatched call must not die with a FunctionClauseError at
  # the callback head — that exception's message embeds the full state
  # (plaintext secrets included) in the crash report, and format_status/1
  # cannot redact an exception message (#315).
  def handle_call(msg, _from, state) do
    Logger.warning("conv #{state.conversation_id}: unexpected call #{inspect(msg)}")
    {:reply, {:error, :unknown_call}, state}
  end

  # The prompt a conversation was started for. Ignored if a turn is somehow
  # already running — the cast is queued behind provisioning, so that should not
  # happen, and re-running is the failure this whole mechanism exists to avoid.
  @impl true
  def handle_cast({:initial_prompt, prompt, images}, state) do
    if Connection.user_turn_running?(state.current_turn) do
      Logger.warning(
        "conv #{state.conversation_id}: initial prompt arrived while a turn was running; dropping it"
      )

      {:noreply, state}
    else
      conv = Conversations._unsafe_get_conversation!(state.conversation_id)

      # Ownership: this server owns conv. Policy may have changed since wake.
      with :ok <- Conversations._unsafe_check_saved_execution_allowance(conv.id),
           :ok <- TurnMachine.gate(conv.user_id, state.inference_source) do
        state = close_autonomous_turn(state, "superseded_by_prompt")
        agent = if conv.agent_id, do: Agents._unsafe_get_agent!(conv.agent_id)

        # Admission can refuse under its row locks after these preflights pass.
        # Unlike the `else` below, the connection is already dropped by here.
        case kick_turn(state, prompt, agent, images) do
          {:error, reason, next} -> {:noreply, log_initial_refusal(next, reason)}
          cast_shape -> cast_shape
        end
      else
        {:error, reason} ->
          # A cast has no caller to reply to. Preserve existing work and its
          # connection when this queued prompt cannot be admitted.
          Logger.info(
            "conv #{state.conversation_id}: dropping initial prompt (#{inspect(reason)})"
          )

          {:noreply, state}
      end
    end
  end

  def handle_cast({:sandbox_reset, sandbox_id, reason, by, message}, state) do
    MachineEvents.reset(state, sandbox_id, reason, by, message, &drop_connection/2)
  end

  def handle_cast({:machine_gone, event, reason, message}, state) do
    MachineEvents.gone(state, {event, reason, message}, &interrupt_turn/1, &drop_connection/2)
  end

  # Catch-all for the same reason as the handle_call one above (#315).
  def handle_cast(msg, state) do
    Logger.warning("conv #{state.conversation_id}: unexpected cast #{inspect(msg)}")
    {:noreply, state}
  end

  # ACP path: stdout is protocol, not transcript. The peer frames it, decides
  # what is worth keeping and reports that back as `{:acp, ref, _}` — a
  # JSON-RPC response to `initialize` is not something a user should find in
  # their conversation, and a `session/load` replay is history we already hold.
  @impl true
  def handle_info(message, state) do
    if Map.get(state, :turn_execution) do
      #
      # One unlocked read. Write authorization belongs where a write happens
      # (the transport, and `_unsafe_complete/3` through the retirement below);
      # this runs per inbound message and must not hold the parent lock, or a
      # chatty turn starves the coordinator meant to expire it.
      case BoundedTurn.gate(state) do
        :ok ->
          handle_execution_info(message, state)

        :retire ->
          if message == :lifecycle_check, do: Lifecycle.schedule_check()
          {:noreply, retire_bounded_turn(state)}
      end
    else
      handle_execution_info(message, state)
    end
  end

  defp handle_execution_info({:execution_retired, id}, %{turn_execution: %{id: id}} = state),
    do: {:noreply, retire_bounded_turn(state)}

  defp handle_execution_info(
         {:stdout, %{ref: ref}, data},
         %{current_command_ref: ref, acp_peer: peer} = state
       )
       when is_pid(peer) do
    case Fountain.Conversations.RunnerReplay.feed(state.runner_replay, data) do
      {:ok, replay, output} ->
        if output != "", do: Managoat.ACP.Peer.stdout(peer, output)
        {:noreply, maybe_emit_first_output(%{state | runner_replay: replay})}

      {:error, reason} ->
        fail_transport(state, reason)
    end
  end

  defp handle_execution_info({:stdout, %{ref: ref}, data}, %{current_command_ref: ref} = state) do
    # Raw stdout only arrives here on the legacy path (or from an ACP turn
    # whose peer died mid-turn). The tracer reads protocol lines from the
    # peer's reports, never raw chunks — the dialect tracer that used to eat
    # this stream went with the legacy claude path.
    state = maybe_emit_first_output(state)
    {:noreply, log_with_replay_skip(state, "stdout", data)}
  end

  defp handle_execution_info({:stderr, %{ref: ref}, data}, %{current_command_ref: ref} = state) do
    {:noreply, log_with_replay_skip(state, "stderr", data)}
  end

  # ── ACP peer reports (0014 gate 2) ────────────────────────────────────────

  # No `cycle_end` came. Close the autonomous turn as completed — the updates
  # it collected are real — and say why.
  defp handle_execution_info(
         {:autonomous_quiet, turn_id},
         %{current_turn: %{id: turn_id}} = state
       ) do
    if TurnMachine.autonomous_turn?(state) do
      {:noreply,
       finish_acp_turn(state, "completed", %{"origin" => "quiet"}, %{
         origin: "autonomous",
         cycle: "quiet"
       })}
    else
      {:noreply, state}
    end
  end

  defp handle_execution_info({:autonomous_quiet, _turn_id}, state), do: {:noreply, state}

  # Nobody answered in time. Deny — the only safe default — and say so on the
  # stream so a card stops waiting.
  defp handle_execution_info(
         {:permission_timeout, request_id},
         %{
           runner_reconnect: %{},
           current_turn: %{pending_permission: %{"request_id" => request_id}}
         } = state
       ) do
    state = Pending.resolve(state, request_id, "timeout", nil)
    fail_transport(state, :permission_timeout_during_runner_reconnect)
  end

  defp handle_execution_info({:permission_timeout, request_id}, state) do
    {:noreply, Pending.resolve_if_held(state, request_id, "timeout", nil)}
  end

  # The caller never answered a parked tool call (#1202). The agent gets an
  # error result and carries on; the stream records the outcome.
  defp handle_execution_info({:caller_tool_timeout, call_id}, state) do
    pending =
      Pending.resolve_call(
        Pending.from_state(state),
        state.conversation_id,
        call_id,
        "timeout",
        {:error, "the caller did not answer within the deadline"}
      )

    {:noreply, Pending.into_state(state, pending)}
  end

  # #655: the org has refused this account's Claude OAuth token. The machine
  # words the outcome and ends the turn; what has to happen first, and here,
  # is the swap: the API key sitting in the same `inference_credentials` row
  # replaces the refused token in the sprite env and the broker session for
  # the rest of this server's life. Whether a key was there to swap in is
  # what the machine's message turns on.
  defp handle_execution_info(
         {:acp, ref, {:failed, {:oauth_org_not_allowed, detail}} = payload},
         %{current_command_ref: ref, runtime_module: Managoat.Runtimes.Claude} = state
       ) do
    Logger.warning("conv #{state.conversation_id}: Claude OAuth token refused by org: #{detail}")

    # On a brokered conversation the API key is a placeholder in the env and
    # the value moves to the broker; the vault is re-prepared so its
    # substitution now carries the key instead of the refused OAuth token.
    state = broker_switch_to_api_key(state)

    fallback_env =
      Managoat.Runtimes.Claude.fall_back_to_api_key(state.sprite_env, state.env_credentials)

    switched? = fallback_env != state.sprite_env

    # The API key was never in the sprite env before now, so `build_sprite_env`
    # never registered it for redaction — do it here, or the very value this
    # fix injects prints in plaintext into `log_events`. Registered as a union
    # with the outgoing env, not a replacement: the refused OAuth token is
    # still sitting in the sprite's `/home/sprite/.env` until a wake rewrites
    # it, so it stays worth scrubbing.
    Redaction.put(
      state.conversation_id,
      state.sprite_env ++ fallback_env
    )

    state = %{
      state
      | sprite_env: fallback_env,
        inference_credentials: Map.delete(state.inference_credentials, :claude_code_oauth_token),
        env_credentials: Map.delete(state.env_credentials, :claude_code_oauth_token)
    }

    {:noreply, drive_turn(state, payload, oauth_switched?: switched?)}
  end

  # Every other report is the turn state machine's (#1374): one call, then
  # the effects it hands back, applied in order.
  defp handle_execution_info({:acp, ref, payload}, %{current_command_ref: ref} = state) do
    {:noreply, drive_turn(state, payload)}
  end

  # A report from a superseded turn's peer. The turn it belonged to is already
  # over; acting on it would end the *current* one.
  defp handle_execution_info({:acp, _stale_ref, _payload}, state), do: {:noreply, state}

  # The peer died without reporting. Whatever it was, the turn has no driver
  # any more, and leaving `current_command` set is the #413 shape: every prompt
  # answered `:busy`, idle reclaim suppressed, sprite billing to the ceiling.
  defp handle_execution_info(
         {:DOWN, mon, :process, _pid, reason},
         %{acp_peer_mon: mon, current_turn: turn} = state
       )
       when not is_nil(turn) do
    Logger.error("conv #{state.conversation_id}: acp peer down: #{inspect(reason)}")

    {:noreply,
     finish_acp_turn(state, "failed", %{"error" => "peer_down"}, %{
       reason: "acp peer down: #{inspect(reason)}"
     })}
  end

  # The peer died between turns (#817): a lost connection, not a failed
  # turn. Say so on the transcript, let the adapter go, and let the next
  # prompt spawn a fresh one (`mode: :continue` → `session/resume`).
  defp handle_execution_info({:DOWN, mon, :process, _pid, reason}, %{acp_peer_mon: mon} = state) do
    Logger.warning("conv #{state.conversation_id}: idle acp peer down: #{inspect(reason)}")
    state = %{state | acp_peer: nil, acp_peer_mon: nil}
    {:noreply, drop_connection(state, "peer_down")}
  end

  # The adapter exited between turns (#817): the connection is gone, no turn
  # is. Record it and clear the connection; the next prompt spawns afresh.
  defp handle_execution_info(
         {:exit, %{ref: ref}, code},
         %{current_command_ref: ref, current_turn: nil} = state
       ) do
    Logger.info("conv #{state.conversation_id}: idle acp adapter exited #{code}")
    {:noreply, connection_lost(state, "adapter_exited", %{exit_code: code})}
  end

  defp handle_execution_info(
         {:exit, %{ref: ref}, _code},
         %{current_command_ref: ref, turn_execution: %{}} = state
       ) do
    {:noreply,
     finish_acp_turn(state, "failed", %{"error" => "adapter_exited_before_reply"}, %{
       reason: "adapter_exited_before_reply"
     })}
  end

  defp handle_execution_info({:exit, %{ref: ref}, code}, %{current_command_ref: ref} = state) do
    turn = state.current_turn

    {:ok, turn} =
      Conversations._unsafe_update_turn(turn, %{
        status: if(code == 0, do: "completed", else: "failed"),
        exit_code: code,
        ended_at: now()
      })

    Output.publish_stage(state.conversation_id, "turn", "done", %{
      turn_id: turn.id,
      turn_number: turn.turn_number,
      exit_code: code
    })

    # Finalize stream tracer: close any tool spans still open (abandoned calls).
    TurnMachine.finalize_tracer(state.stream_tracer)

    # An ACP turn can also end here — the adapter exits, is interrupted, or its
    # socket drops before it ever answers `session/prompt`. The peer has nothing
    # left to drive and must not outlive the turn.
    stop_acp_peer(state)

    # Close the OTel turn span we opened in kick_turn.
    TurnMachine.end_span(
      state.current_turn_span,
      if(code == 0, do: :ok, else: :error),
      %{"exit_code" => code}
    )

    emit_turn_completed(state, turn.status)

    {:ok, _} = Conversations._unsafe_idle_after_turn(turn)

    {:noreply,
     %{
       touch_activity(state)
       | current_command: nil,
         current_command_ref: nil,
         current_turn: nil,
         current_turn_span: nil,
         turn_metrics: nil,
         stream_tracer: nil,
         acp_peer: nil,
         acp_peer_mon: nil
     }}
  end

  # An error naming the CURRENT command is terminal for the turn (#413):
  # The adapter sends it when the transport to the sandbox drops mid-run,
  # then stops — and since the command process is neither linked nor
  # monitored, this message is the only signal there will ever be. Ignoring
  # it left current_command set forever: every prompt answered {:error,
  # :busy}, idle reclaim was suppressed (busy? true), the reaper skipped the
  # sandbox (server alive), and the sprite billed until max_lifetime. Fail
  # the turn and return to idle, exactly like a non-zero :exit.
  defp handle_execution_info(
         {:error, %{ref: ref}, reason},
         %{current_command_ref: ref, current_turn: nil} = state
       )
       when not is_nil(ref) do
    Logger.warning("sprite command error between turns: #{inspect(reason)} — connection lost")
    {:noreply, connection_lost(state, "transport_error", %{reason: inspect(reason)})}
  end

  defp handle_execution_info(
         {:error, %{ref: ref}, :runner_disconnected},
         %{
           current_command_ref: ref,
           current_turn: %{acp_prompt_id: prompt_id},
           handle: %{provider: :runner}
         } = state
       )
       when not is_nil(ref) and not is_nil(prompt_id) do
    state = Reattachment.disconnect_runner(state)
    Reattachment.wait_for_runner(state, &fail_transport/2)
  end

  defp handle_execution_info({:error, %{ref: ref}, reason}, %{current_command_ref: ref} = state)
       when not is_nil(ref) do
    fail_transport(state, reason)
  end

  # A stale ref — an error from a command already superseded or finished.
  defp handle_execution_info({:error, _ref, reason}, state) do
    Logger.error("sprite command error: #{inspect(reason)}")
    {:noreply, state}
  end

  defp handle_execution_info(
         {:runner_reconnect, token},
         %{runner_reconnect: %{token: token}, current_turn: turn} = state
       )
       when not is_nil(turn) do
    if Reattachment.runner_reconnect_expired?(state) do
      fail_transport(state, :runner_reconnect_timeout)
    else
      # Reuse the ordinary reattach path, including scoped credentials,
      # command tags, persisted prompt ID and pending permission restoration.
      handle_continue(:provision, state)
    end
  end

  defp handle_execution_info({:runner_reconnect, _token}, state), do: {:noreply, state}

  defp handle_execution_info(
         {:runner_replay_timeout, ref},
         %{current_command_ref: ref, runner_replay: %{}} = state
       ),
       do: fail_transport(state, :runner_replay_boundary_missing)

  defp handle_execution_info({:runner_replay_timeout, _ref}, state), do: {:noreply, state}

  # The ACP reattach window is over; anything still in the set is a persisted
  # line the replay did not repeat, and must not suppress a genuine repeat.
  defp handle_execution_info(:clear_replay_dedup, state) do
    {:noreply, %{state | replay_dedup: MapSet.new()}}
  end

  # ── permissions, reclaim and redaction ────────────────────────────────────

  defp handle_execution_info(:lifecycle_check, state) do
    Lifecycle.schedule_check()

    started_at = state.sandbox_started_at

    cond do
      # No sprite yet: provisioning is still in flight and there is nothing to
      # reclaim. The reaper handles a provision that never finishes.
      is_nil(started_at) ->
        {:noreply, state}

      true ->
        # Busy is a turn in flight, autonomous ones included (#817) — an idle
        # adapter between turns is not a reason to hold the sandbox open.
        case Lifecycle.check(started_at, state.last_activity_at, state.current_turn != nil) do
          {:expired, reason} -> reclaim_sandbox(state, reason)
          :ok -> {:noreply, state}
        end
    end
  end

  # trap_exit is on (see init/1), so exit signals from linked processes
  # arrive here instead of killing the server outright. Preserve the
  # pre-trap semantics: a linked crash still takes the server down (through
  # terminate/2, which is the point), a :normal exit is ignored. Exits from
  # the parent supervisor never reach this clause — OTP intercepts those
  # and calls terminate/2 directly.
  defp handle_execution_info({:EXIT, _from, :normal}, state), do: {:noreply, state}
  defp handle_execution_info({:EXIT, _from, reason}, state), do: {:stop, reason, state}

  defp handle_execution_info(_msg, state), do: {:noreply, state}

  defp fail_transport(%{turn_execution: %{}} = state, _reason) do
    {:noreply,
     finish_acp_turn(state, "failed", %{"error" => "transport_failed"}, %{
       reason: "transport_failed"
     })}
  end

  # `Pending.resolve_held/2` is the family's own (#1369); this call site came
  # from the shared-sandbox reattach fix and moves with it.
  defp fail_transport(state, reason),
    do: Reattachment.fail_transport(Pending.resolve_held(state, "turn_ended"), reason)

  defp prepare_termination(state, opts) do
    opts =
      opts
      |> Keyword.put(:terminating_conversation_id, state.conversation_id)
      |> Keyword.put_new(:reason, "conversation_terminated")

    # ownership: init/1 established this actor's conversation and sandbox.
    case Conversations._unsafe_get_sandbox(state.sandbox_id) do
      nil ->
        {:error, :sandbox_unavailable}

      sandbox ->
        # ownership: the conditional fence rechecks this actor's parent and owner.
        Conversations._unsafe_fence_sandbox_for_teardown(sandbox, opts)
    end
  end

  defp terminate_kept_machine(state) do
    # The machine is shared, or it is the agent's home (ADR 0023): end this
    # conversation and leave the sprite — the same guard the no-server path
    # applies in terminate_conversation/2. A turn of ours still running is
    # cut first, since nothing would be left to drive it; `handle: nil` so
    # no stop path touches the sprite.
    state = if state.current_turn, do: interrupt_turn(state), else: state
    state = drop_connection(state, "terminated")

    finish_termination(%{state | handle: nil}, %{
      sandbox: "kept",
      reason:
        if(Lifecycle.home?(state.sandbox_id),
          do: "persistent_home",
          else: "held_by_another_conversation"
        )
    })
  end

  defp terminate_machine(state, sandbox) do
    state = drop_connection(state, "terminated")
    if state.handle, do: _ = Managoat.Sandbox.destroy(state.handle)
    Egress.release(state.conversation_id)

    {:ok, _} =
      Conversations.update_sandbox(sandbox, %{status: "terminated", terminated_at: now()})

    finish_termination(state, %{})
  end

  defp finish_termination(state, metadata) do
    # Ownership: this actor's IDs came from init; the write rechecks its binding.
    result =
      case Conversations._unsafe_finish_conversation_termination(
             state.conversation_id,
             state.sandbox_id
           ) do
        {:ok, _} ->
          Output.publish_stage(state.conversation_id, "terminate", "done", metadata)
          :ok

        {:error, _} = error ->
          error
      end

    {:stop, :normal, result, state}
  end

  # The server's own clock stamp: the input `Lifecycle.check/4` reads. Nothing
  # but this process writes it.
  defp touch_activity(state), do: %{state | last_activity_at: DateTime.utc_now()}

  # Idle: the machine's verdict, not this conversation's (ADR 0023 step 5).
  defp reclaim_sandbox(state, :idle) do
    if Lifecycle.busy_elsewhere?(state.sandbox_id, state.conversation_id) do
      # This conversation is idle; the machine is not. Another conversation
      # on it is mid-turn or was active more recently than the bound, so the
      # verdict is the machine's to reach, over all of them (ADR 0023 step 5).
      # Checked again on the next tick.
      {:noreply, state}
    else
      case Lifecycle.idle_machine_action(state.conversation_id, state.handle) do
        :park -> park_sandbox(state)
        :destroy -> destroy_sandbox(state, :idle)
      end
    end
  end

  # Max lifetime: `Lifecycle.max_lifetime_action/2` decides, and has already
  # made the suspend call by the time it answers `:park`.
  defp reclaim_sandbox(state, :max_lifetime) do
    case Lifecycle.max_lifetime_action(state.sandbox_id, state.handle) do
      :park -> park_sandbox(state, :max_lifetime)
      :destroy -> destroy_sandbox(state, :max_lifetime)
    end
  end

  # The log line and the connection are the process's; the rest of a park is
  # `Lifecycle.park/4`.
  defp park_sandbox(state, reason \\ :idle) do
    Logger.info(
      "suspending sandbox for conv #{state.conversation_id}: #{reason} " <>
        "(sprite #{inspect(state.handle && state.handle.name)})"
    )

    # A parked sprite never keeps a live adapter (#817).
    state = drop_connection(state, "suspended")
    Lifecycle.park(state.conversation_id, state.sandbox_id, state.handle, reason)

    # The conversation stays idle and resumable; the sprite stays parked.
    {:stop, :normal, %{state | handle: nil}}
  end

  # The same shape for a destroy (`Lifecycle.destroy/4`).
  defp destroy_sandbox(state, reason) do
    Logger.info(
      "reclaiming sandbox for conv #{state.conversation_id}: #{reason} " <>
        "(sprite #{inspect(state.handle && state.handle.name)})"
    )

    with :ok <- Lifecycle.prepare_destroy(state.sandbox_id, reason) do
      state = drop_connection(state, "reclaimed")

      case Lifecycle.destroy(
             state.conversation_id,
             state.sandbox_id,
             state.handle,
             reason
           ) do
        :ok -> {:stop, :normal, %{state | handle: nil}}
        {:error, error} -> reclaim_refused(state, error)
      end
    else
      {:error, error} -> reclaim_refused(state, error)
    end
  end

  defp reclaim_refused(state, error) do
    Logger.warning("reclaim refused for conv #{state.conversation_id}: #{inspect(error)}")
    {:noreply, state}
  end

  # Best-effort revoke of the per-conversation API key when this server
  # exits — clean termination (`:terminate_conv`), crash paths that hit
  # `{:stop, :normal, state}`, and (because init/1 traps exits, #322)
  # supervisor shutdown on deploys and Horde rebalances. `CallbackKey.revoke/2`
  # owns the rule about whose key it is safe to take back.
  @impl true
  def terminate(reason, state) do
    Redaction.delete(state.conversation_id)
    _ = CallbackKey.revoke(state.conversation_id, state.callback_api_key_id)

    # Last and best-effort, so it cannot skip the revocation above.
    _ =
      TurnMachine.orphan_on_normal_stop(reason, state.current_turn, state.conversation_id,
        expected_sandbox_id: state.sandbox_id
      )

    :ok
  end

  # Keeps secrets out of crash reports and :sys.get_status output (#315). The
  # redactor itself is `Redaction.server_state/1`.
  @impl true
  def format_status(status), do: Redaction.server_status(status)

  # ── turns ─────────────────────────────────────────────────────────────────

  @doc """
  The options a sprite's callback key is minted with: `CallbackKey.api_key_opts/0`.

  Re-exported here because `conversation_server_shutdown_revoke_test`,
  `api_key_scope_test` and `audit_coverage_test` pin the scope and expiry
  through this module, and the server tests do not change (#1369).
  """
  def callback_api_key_opts, do: CallbackKey.api_key_opts()

  # Rotate the sandbox's callback key (`CallbackKey.rotate/2`) and hold the
  # result: the plaintext and the row id on success. On failure only the
  # token is cleared; `callback_api_key_id` is left as it was.
  defp rotate_callback_api_key(state, %Conversation{} = conv) do
    case CallbackKey.rotate(conv, state.callback_api_key_id) do
      {:ok, raw, key_id, conv} ->
        {%{state | callback_token: raw, callback_api_key_id: key_id}, conv}

      {:error, conv} ->
        {%{state | callback_token: nil}, conv}
    end
  end

  # End the running turn without a verdict from the agent: the user asked, or
  # the machine under it is going away. Tells the agent before killing its
  # process — `session/cancel` is a notification with no reply, so it costs
  # one write and does not delay the kill, but it is the difference between
  # an agent that stops its tool calls and one that is shot mid-write. This is
  # the other reason stdin stays open on the ACP path.
  # Both halves live in `BoundedTurn` (see its moduledoc): journal logic the
  # actor calls rather than actor logic. `finish_acp_turn/4` is passed in
  # because ending a turn writes through this actor's transcript.
  defp retire_bounded_turn(state),
    do: BoundedTurn.retire(state, &finish_acp_turn(&1, &2, &3, &4))

  defp close_bounded_connection(state), do: Connection.close_bounded(state)

  defp interrupt_turn(%{turn_execution: %{}} = state), do: retire_bounded_turn(state)

  defp interrupt_turn(state) do
    state = Reattachment.finish_runner_reconnect(state, "interrupted")
    if state.acp_peer, do: Managoat.ACP.Peer.cancel(state.acp_peer)
    # EOF before the handle goes: a detachable session survives its client
    # disconnecting, so closing the WebSocket alone would leave the adapter —
    # and whatever background task it was running — alive on the machine.
    if state.current_command, do: Managoat.Sandbox.close_stdin(state.current_command)
    if state.current_command, do: Managoat.Sandbox.stop_command(state.current_command)
    state = cancel_autonomous_quiet(state)

    turn = TurnMachine.mark_interrupted(TurnMachine.from_state(state))

    # An ACP turn can also end here — the adapter exits, is interrupted, or its
    # socket drops before it ever answers `session/prompt`. The peer has nothing
    # left to drive and must not outlive the turn.
    stop_acp_peer(state)

    state = TurnMachine.into_state(state, TurnMachine.close_interrupted(turn))

    %{
      state
      | current_command: nil,
        current_command_ref: nil,
        acp_peer: nil,
        acp_peer_mon: nil,
        runner_reconnect: nil,
        runner_replay: nil
    }
  end

  defp log_initial_refusal(state, reason) do
    Logger.info("conv #{state.conversation_id}: initial turn refused (#{inspect(reason)})")
    state
  end

  # Returns the callback tuple rather than a state, because one outcome needs
  # a continuation: a reapply committed while this server held an older
  # revision, so the turn is not opened, the connection is dropped and the
  # server rebuilds from the row before delivering the prompt (#1565).
  defp kick_turn(state, prompt, agent, images) do
    # A new turn has not been restarted (#1667), whatever the last one did.
    state = touch_activity(%{state | turn_session_retry: nil})

    case TurnMachine.open(
           state.conversation_id,
           state.sandbox_id,
           prompt,
           agent,
           state.configuration_revision
         ) do
      {:ok, conv, turn} ->
        {:noreply, run_turn(state, conv, turn, prompt, agent, images)}

      refused when refused in [:at_capacity, :no_command] ->
        {:noreply, state}

      :configuration_changed ->
        state = drop_connection(state, "configuration_reapplied")
        {:noreply, %{state | handle: nil}, {:continue, {:reapply_prompt, prompt, images}}}

      # Three-element, so a refusal is distinguishable from the other
      # outcomes that also keep the connection-dropping state. `send_prompt`
      # turns it into a reply; the casts below drop the prompt as they always
      # have, because a cast has no caller to answer.
      {:error, reason} ->
        {:error, reason, drop_connection(state, "admission_refused")}
    end
  end

  # `kick_turn/4` answers a cast's shape; a call needs `:ok` in front of it.
  defp replying_ok({:noreply, state}), do: {:reply, :ok, state}
  defp replying_ok({:noreply, state, continuation}), do: {:reply, :ok, state, continuation}

  defp run_turn(state, conv, turn, prompt, agent, images) do
    # ownership: admission committed this journal with the actor's new turn.
    execution = Fountain.Conversations.ExecutionGuard._unsafe_for_turn(turn.id)

    state =
      if execution,
        do: drop_connection(state, "bounded_turn_requires_fresh_connection"),
        else: state

    state = %{state | inference_model: agent && agent.model, turn_execution: execution}

    # Before either path (#1736): a fresh spawn takes the env this rebuilds, an
    # idle peer holds its token, and one whose token was replaced is closed.
    {state, replaced?} = Egress.refresh_before_turn(state)
    # A bounded turn already discarded its old connection before registration
    # entered actor state. Refreshing credentials must not retire the NEW journal
    # and accidentally route this turn through the legacy spawn branch.
    state =
      if replaced? and is_nil(execution),
        do: drop_connection(state, "broker_session_replaced"),
        else: state

    TurnMachine.store_images(turn, images)

    # A bounded turn generates no title. Titling is a second inference call that
    # the journal does not bound and the allowance does not price, so spending
    # it under a wall-clock ceiling would be usage the caller asked to cap and
    # cannot see. The cost is real and is a known gap, not an oversight: a
    # conversation whose *first* turn is bounded has no title until an unbounded
    # turn follows, because titling only ever runs once. ADR 0046 records it.
    unless execution,
      do: TurnMachine.generate_title(conv, turn, prompt, state.inference_credentials)

    # Keyed on the conversation's runtime, not the agent: a conversation
    # outlives its agent (deletion nilifies agent_id), and for a supported
    # runtime the legacy spawn path no longer exists to fall back to.
    acp? = Fountain.RuntimeDispatch.acp_enabled?(conv.runtime)

    # An idle peer carries the next turn without spawn, handshake or resume
    # (#817). It applies the model before prompting; background tasks and
    # Codex session grants survive.
    if is_nil(execution) and acp? and Connection.alive?(Connection.from_state(state)) do
      resume_acp_connection(state, conv, turn, prompt, images)
    else
      run_fresh_turn(state, conv, turn, prompt, agent, images, acp?)
    end
  end

  # The launch itself lives in `TurnLaunch` (see its moduledoc): this module's
  # line count only ratchets down, and a pure launch given a state it does not
  # own is the natural seam. `fail_turn_before_start/6` stays here because it
  # writes through this actor's logger and owns `current_turn`.
  defp run_fresh_turn(state, conv, turn, prompt, agent, images, acp?) do
    TurnLaunch.run(
      state,
      conv,
      turn,
      prompt,
      agent,
      images,
      acp?,
      &fail_turn_before_start(&1, &2, &3, &4, &5, &6)
    )
  end

  defp fail_turn_before_start(state, turn, reason, what, exit_code, output) do
    detail = TurnMachine.failure_detail(reason, exit_code)
    Logger.error("#{what}: #{detail}")

    # current_turn is nil on this path — it is only assigned once the prompt
    # is away — and persist_output reads it for the turn_id, so stand it up
    # for the duration and clear it again before returning.
    state =
      Enum.reduce(output, %{state | current_turn: turn}, fn {stream, data}, acc ->
        log_output(acc, stream, data)
      end)

    TurnMachine.fail_before_start(turn, state.conversation_id, what, detail, exit_code)

    state = %{state | current_turn: nil, turn_session_retry: nil}

    # A bounded turn that never started still holds a journal and a transport.
    # Closing is retirement intent, not a confirmed stop; the coordinator confirms.
    if state.turn_execution, do: close_bounded_connection(state), else: state
  end

  # Time to first token (#535), one-shot per turn: `TurnMachine.maybe_emit_first_output/1`.
  defp maybe_emit_first_output(state) do
    TurnMachine.into_state(
      state,
      TurnMachine.maybe_emit_first_output(TurnMachine.from_state(state))
    )
  end

  # The aggregate turn-duration event (#536), from every path that ends a turn
  # which actually ran: `TurnMachine.emit_completed/2`.
  defp emit_turn_completed(state, status),
    do: TurnMachine.emit_completed(TurnMachine.from_state(state), status)

  # Persistence for peer-relayed lines: the log budget, redaction and the
  # legacy replay skip all live on this path; the tracer reads protocol lines
  # from the peer's reports, never raw chunks.
  defp persist_acp_lines(state, stream, data) do
    new_state = log_with_replay_skip(state, stream, data)

    # Each "acp" report is one session/update line; the tracer turns tool_call
    # / tool_call_update into child spans. Peer-relayed lines carry no byte
    # replay-suffix arithmetic: a fresh peer's lines never replay, and an
    # attached peer's replayed lines were matched by content before this.
    tracer =
      if stream == "acp" do
        Managoat.ACP.Tracer.handle_line(new_state.stream_tracer, data)
      else
        new_state.stream_tracer
      end

    %{
      new_state
      | stream_tracer: tracer,
        acp_request_params: DetachedRequest.request_line(stream, data) || state.acp_request_params
    }
  end

  # Terminal path for an ACP turn. The order matters: stdin closes first so the
  # adapter starts exiting while we do the bookkeeping, and `current_command_ref`
  # is cleared at the end so the `{:exit, …}` that follows finds no match and
  # falls through to the catch-all. A turn ends on the prompt response *or* the
  # process exit, whichever arrives first, and never waits for both.
  #
  # End a turn, and only a turn (#817). The connection — `current_command`,
  # `current_command_ref`, `acp_peer` — is left alive and idle for the next
  # `prompt/3`; what is cleared here is the turn's own bookkeeping. The
  # connection is closed elsewhere, by `drop_connection/2`, when the sandbox
  # stops being this server's.
  defp finish_acp_turn(state, status, span_attrs, stage_meta) do
    # Resolve a held permission request as the turn ends (#940): a card left
    # open is a client waiting on an answer that can never come, and the
    # turn's `pending_permission` would stay set on a turn that is over.
    # Unless the agent asked to keep it (#1635): `:detach_permission` marked
    # the row first, the connection is dropped right after this (the peer is
    # still holding the request), and the answer arrives as a new turn.
    state =
      if Pending.detached?(state.current_turn),
        do: state,
        else: Pending.resolve_held(state, "turn_ended")

    state = Pending.drop(state, "turn_ended")
    state = cancel_autonomous_quiet(state)

    turn = TurnMachine.finish(TurnMachine.from_state(state), status, span_attrs, stage_meta)
    state = touch_activity(TurnMachine.into_state(state, turn))
    if state.turn_execution, do: close_bounded_connection(state), else: state
  end

  # One peer report through the turn state machine (#1374): the turn the
  # server holds goes in, the next one comes back with the effects to apply,
  # in order. `ctx` is what the machine needs that is not the turn's own.
  defp drive_turn(state, payload, extra \\ []),
    do: TurnMachine.drive(state, payload, extra, &apply_effect/2)

  # What the machine hands back: the server's state, processes, timers,
  # output persistence and pending registries, one clause each.
  defp apply_effect(state, {:persist_lines, stream, data}),
    do: persist_acp_lines(state, stream, data)

  defp apply_effect(state, :open_autonomous_turn), do: open_autonomous_turn(state)
  defp apply_effect(state, :arm_autonomous_quiet), do: arm_autonomous_quiet(state)

  defp apply_effect(state, {:session_id, id}),
    do: TurnMachine.accept_runtime_session(state, id)

  # The row must stop naming a session that is not on the disk, or every later
  # turn resumes the same absent one. Re-read for the reason the clause above
  # re-reads it: what is written goes onto the row as it is now.
  defp apply_effect(state, {:forget_runtime_session, reason, detail}),
    do: TurnMachine.forget_turn_session(state, reason, detail)

  defp apply_effect(state, {:restart_session, detail}),
    do: restart_session(state, detail)

  defp apply_effect(state, {:ask_permission, request_id, tool, options}),
    do: Pending.ask(state, request_id, tool, options)

  defp apply_effect(state, :detach_permission), do: Pending.detach(state)

  defp apply_effect(state, {:finish, status, span_attrs, stage_meta}),
    do: finish_acp_turn(state, status, span_attrs, stage_meta)

  defp apply_effect(state, {:drop_connection, why}), do: drop_connection(state, why)

  # ── the connection (#817) ─────────────────────────────────────────────────

  # This turn rides the open connection (`Connection.resume/7`): the span, the
  # stage event and the peer's answer are the connection's; the turn fields
  # they land in are the server's. A peer that refuses the prompt is dropped
  # and the turn runs on a fresh spawn against the row that already exists.
  defp resume_acp_connection(state, conv, turn, prompt, images) do
    case Connection.resume(
           Connection.from_state(state),
           state.conversation_id,
           state.user_id,
           conv,
           turn,
           prompt,
           images
         ) do
      {:ok, turn_span, tracer, started_mono} ->
        %{
          touch_activity(state)
          | current_turn: turn,
            current_turn_span: turn_span,
            turn_metrics:
              TurnMachine.start_metrics(conv.runtime, state.handle.provider, started_mono),
            stream_tracer: tracer
        }

      {:error, _reason} ->
        state = drop_connection(state, "peer_refused_reuse")
        run_fresh_turn(state, conv, turn, prompt, TurnMachine.agent_for(conv), images, true)
    end
  end

  # The failed resume never prompted. Keep the initialized peer, remote
  # command and admitted execution so its original deadline and fences hold.
  defp restart_session(%{current_turn: nil} = state, _detail), do: state

  defp restart_session(state, detail) do
    case TurnMachine.try_forget_turn_session(state, "session_gone", detail) do
      {:ok, state} ->
        restart_current_session(state, detail)

      {:error, state} ->
        abandon_session_restart(state)
    end
  end

  defp abandon_session_restart(%{turn_execution: %{}} = state), do: retire_bounded_turn(state)

  defp abandon_session_restart(state) do
    state
    |> TurnMachine.into_state(TurnMachine.abandon_fenced(TurnMachine.from_state(state)))
    |> drop_connection("restart_fenced")
  end

  defp restart_current_session(state, detail) do
    case restart_acp_peer(state.acp_peer) do
      :ok ->
        TurnMachine.into_state(
          state,
          TurnMachine.note_session_restart(TurnMachine.from_state(state), detail)
        )

      {:error, reason} ->
        drive_turn(state, {:failed, reason})
    end
  end

  defp restart_acp_peer(nil), do: {:error, :acp_peer_unavailable}

  defp restart_acp_peer(peer) do
    Managoat.ACP.Peer.restart_session(peer)
  catch
    :exit, _ -> {:error, :acp_peer_unavailable}
  end

  # Close the connection (`Connection.close/3`). An autonomous turn still open
  # is completed first: its updates are real, and ending a turn resolves what
  # the turn holds pending and stamps its row, which is the server's work. The
  # first clause is why a server with no connection skips that finish too.
  defp drop_connection(%{turn_execution: %{}} = state, _why),
    do: retire_bounded_turn(state)

  defp drop_connection(%{acp_peer: nil, current_command: nil} = state, _why), do: state

  defp drop_connection(state, why) do
    state = close_autonomous_turn(state, "connection_closed")

    _ = why

    Connection.into_state(
      state,
      Connection.close(Connection.from_state(state), state.conversation_id, state.handle)
    )
  end

  # The adapter went away between turns with no turn to fail
  # (`Connection.lost/5`).
  defp connection_lost(state, reason, meta) do
    Connection.into_state(
      state,
      Connection.lost(
        Connection.from_state(state),
        state.conversation_id,
        state.handle,
        reason,
        meta
      )
    )
  end

  # An out-of-turn protocol line opened a background cycle
  # (`Connection.open_autonomous_turn/3`). The row, its span and its tracer are
  # the server's to hold; the quiet timer is armed in this process.
  defp open_autonomous_turn(state) do
    case Connection.open_autonomous_turn(state.conversation_id, state.user_id, state.sandbox_id) do
      {:error, _} ->
        drop_connection(state, "admission_refused")

      {turn, turn_span, tracer} ->
        arm_autonomous_quiet(%{
          touch_activity(state)
          | current_turn: turn,
            current_turn_span: turn_span,
            turn_metrics: nil,
            stream_tracer: tracer
        })
    end
  end

  defp close_autonomous_turn(state, why) do
    if TurnMachine.autonomous_turn?(state) do
      finish_acp_turn(state, "completed", %{"origin" => why}, %{origin: "autonomous", cycle: why})
    else
      state
    end
  end

  defp arm_autonomous_quiet(state) do
    Connection.into_state(
      state,
      Connection.arm_quiet(Connection.from_state(state), state.current_turn)
    )
  end

  defp cancel_autonomous_quiet(state),
    do: Connection.into_state(state, Connection.cancel_quiet(Connection.from_state(state)))

  defp stop_acp_peer(state), do: Connection.stop_peer(Connection.from_state(state))

  # ── output (#331) ─────────────────────────────────────────────────────────

  # One chunk of sandbox output onto the transcript, against the durable
  # budget: `Output.log/4`.
  defp log_output(state, stream, data),
    do:
      Output.into_state(
        state,
        Output.log(Output.from_state(state), Output.ctx(state), stream, data)
      )

  # The same, minus the bytes a reattach is replaying: `Output.log_with_replay_skip/4`.
  defp log_with_replay_skip(state, stream, data) do
    Output.into_state(
      state,
      Output.log_with_replay_skip(Output.from_state(state), Output.ctx(state), stream, data)
    )
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
