defmodule Managoat.ACP.Peer.State do
  @moduledoc false
  defstruct [
    :owner,
    :owner_mon,
    :writer,
    :ref,
    :prompt,
    :mode,
    :session_id,
    :cwd,
    :started_mono,
    images: [],
    session_options: %{mcp_servers: [], additional_directories: [], execution_limits: nil},
    model: nil,
    model_selection: %{result: %{}, effective: nil, source: nil},
    # Session config options beyond the model (managoat/fountain#2537).
    # `requested` is what the owner asked for, id to value; `options` is the
    # latest set the agent advertised (a session result, a setter response or
    # a `config_option_update`), nil until one arrives; `queue` is what is left
    # to apply before this turn's prompt. `baseline` is, per id this session
    # has changed, the value the agent reported just before the first change:
    # what a later turn that does not name the id is put back to.
    config: %{requested: %{}, options: nil, queue: [], baseline: %{}},
    client_capabilities: nil,
    # The effective per-tool permission policy for this turn (#939). Already
    # merged and clamped by `Permissions.effective/2` before it gets here —
    # the peer applies it, it does not resolve it.
    permission_policy: %{},
    # `ask`: the JSON-RPC id of a `session/request_permission` the agent is
    # still blocked on, with the options it offered. One at a time — the
    # agent cannot proceed until it is answered — so a single slot is
    # enough. nil whenever nothing is outstanding.
    pending_permission: nil,
    transcript: %{buffer: "", plans: %Managoat.ACP.Plans{}},
    next_id: 1,
    pending: %{},
    phase: :initializing,
    failed_session_setup: nil,
    replay_discard?: false,
    # `%{quiet_ms:, max_ms:}`, from opts in `init/1`; the defaults live on the
    # peer module.
    replay_window: nil,
    replay_result: nil,
    replay_last_ms: nil,
    replay_until_ms: nil,
    capabilities: %{},
    # `:choice` is which advertised method to `authenticate` with: `:api_key`
    # (the first method whose `_meta` names an api key), `:none` (never
    # authenticate; the agent's ambient credentials are the session's), or a
    # method id. `:methods` is what the agent advertised on `initialize`.
    auth: %{choice: :api_key, methods: [], authenticated?: false},
    # `attach: prompt_id` mode: joined a turn already in flight, so replayed
    # responses to ids we never sent are expected, and the first chunk may
    # start mid-line.
    attached?: false,
    drop_partial_line?: false
  ]
end

defmodule Managoat.ACP.Peer do
  @moduledoc """
  One ACP connection, for as many turns as its owner sends it.

  The peer drives `initialize` → (`session/new` | `session/resume` |
  `session/load`) → `session/prompt` over whatever transport the host gives
  it (`Managoat.ACP.Transport`), translates nothing itself, and — once the
  prompt is answered — waits in `:idle` for the next `prompt/3` rather than
  ending. The connection ends when the owner calls `close/1`, when the owner
  dies, or when a write fails.

  Built as gate 2 of Fountain's ADR 0014 and widened by #817; the issue
  numbers below are that repository's, kept because each one is a measured
  agent behaviour the code is shaped around.

  ## Why this is its own process

  The host owns the sandbox (or port, or socket), the turn record and the
  output budget; the peer owns a protocol conversation with states and a
  correlation table. They fail differently and should not share a mailbox.
  A protocol bug here must fail a *turn*, so the peer is deliberately
  unlinked from its owner in both directions and monitored instead: linking
  would make it take down an owner that is also holding a sandbox handle and
  a tenant's secrets.

  ## Lifetime is the wake, not the turn

  0014 as first written scoped the connection to the turn: one `session/prompt`,
  take the `stopReason`, close. #817 measured what that costs. The adapter
  treats the connection as the session, so closing it at `end_turn` kills
  everything Claude Code left running in the background — a `Monitor`, a
  `run_in_background` shell, a `ScheduleWakeup` — and throws away codex's
  "Allow for Session" grant; and ACP allows `session/update` *out of turn*,
  which a client that stops reading at the prompt response never sees.

  So the peer outlives its prompt. After the prompt's response it reports
  `{:done, stop, usage}` and moves to `:idle`, where the owner may send the
  next turn with `prompt/3` on the same connection — no second `initialize`,
  no `session/resume`, model selection before each prompt. Updates that arrive while idle are still
  reported as `{:lines, "acp", …}`; an autonomous cycle (a background task's
  follow-up) is marked at its end by `{:cycle_end, kind}` when the adapter's
  `usage_update` carries an origin from its autonomous set. The owner decides
  what a turn is; the peer only parses the protocol.

  What stays scoped to the turn is the *owner's* accounting — its turn
  record, its output budget, its notion of busy — and what bounds the
  connection is the owner: it closes the peer with `close/1` when the
  transport stops being its own (the sandbox is parked or destroyed, the
  owner shuts down), never at turn end. The durable identity is the session
  id the agent returned, which the owner keeps and hands to `session/resume`
  on the next connection.

  ## Resumption, and why `session/load` is the unhappy path

  `session/resume` restores context and returns. `session/load` "**MUST** replay
  the entire conversation to the Client in the form of `session/update`
  notifications" before responding — and an owner that persists what the
  peer reports already holds that history, so relaying the replay would
  duplicate the whole transcript on every turn after the first. While a
  `session/load` is outstanding the peer runs in replay-discard mode and
  drops updates on the floor.

  **The response is not the end of the replay, and we do not treat it as one.**
  Gemini answers `session/load` before replaying — its `streamHistory` is a
  floating promise — so a window closed on the response misses the replay
  entirely (#657, live: one assistant message rendered twice). The window
  closes instead on a bounded quiet period: keep discarding until the stream
  has been silent for `@replay_quiet_ms`, then prompt, giving up after
  `@replay_max_ms` because a turn held open disarms idle reclaim (#413).

  We prefer `resume` whenever the adapter advertises it, which the pinned Claude
  adapter does. `load` is kept because the capability is per-adapter and per
  version, and discovering at runtime that this build cannot resume is better
  handled by taking the expensive path than by failing the turn.

  ## Reattaching after a restart

  A deploy restarts every owner, and with it every peer — but an adapter in
  a sandbox is a detachable session that keeps running, mid-turn, with a
  `session/prompt` still outstanding. `attach: prompt_id`
  starts a peer for that turn without a handshake: it joins the stream already
  in flight, answers the agent's requests (a `session/request_permission`
  nobody answers is a turn that never ends), and closes the turn on the
  response to `prompt_id`. Everything else in the replayed prefix — the
  handshake responses, a model rejection the previous peer already reported —
  is history and is dropped rather than re-acted-on.

  The prompt id has to come from the caller because it is the only way to
  tell the prompt's answer from a replayed handshake response; the peer
  reports `{:prompt_sent, id}` the moment it writes the prompt so the owner
  can persist it for exactly this purpose. Without it a reattached turn cannot
  be resumed at all, and the caller orphans it instead.

  A sandbox that replays its buffer on attach replays the **tail** (Sprites,
  measured: one 16 KiB chunk, starting mid-line — not from the beginning), so
  an attached peer drops the partial first line and leaves de-duplicating the
  replayed lines to the owner, by content, not by byte count.

  ## What it sends back

  Everything goes to the owner as `{:acp, ref, payload}` — the peer persists
  nothing and writes nothing but protocol. An owner keeps its own invariants
  (an output budget, a redaction pass, replay de-duplication) on its own
  persistence path, and a peer writing rows directly would bypass them all.
  The README lists every payload and what an owner is expected to do with it.
  """

  use GenServer

  require Logger

  alias Managoat.ACP.Peer.State
  alias Managoat.ACP.{ExecutionLimits, Permissions, Protocol, Usage}

  # How long the replay has to stay quiet before we believe it is over, and how
  # long we will wait for that in total. See `handle_response(:load_session, …)`.
  @replay_quiet_ms 250
  @replay_max_ms 10_000

  # The adapter's own set (claude-agent-acp `AUTONOMOUS_RESULT_ORIGINS`,
  # re-verified at 0.70.0 in #817): a result whose origin is one of these
  # "must never touch the user-turn lifecycle" — it is a background task's
  # follow-up, not the answer to a prompt.
  @autonomous_origins ~w(task-notification peer coordinator observer observer-activity)

  @typedoc """
  What the peer reports upward, as `{:acp, ref, payload}`. `ref` is whatever
  the owner passed as `:ref`.
  """
  @type payload ::
          {:lines, stream :: String.t(), data :: String.t()}
          | {:session, String.t()}
          | {:prompt_sent, pos_integer()}
          | {:model_selected, String.t() | nil, String.t() | nil, String.t() | nil}
          | {:config_selected, id :: String.t(), requested :: config_value(), confirmed :: term()}
          | {:config_skipped, id :: String.t(), requested :: config_value()}
          | {:config_restored, id :: String.t(), confirmed :: term()}
          | {:config_options, [map()]}
          | {:handshake_ms, non_neg_integer(), method :: String.t()}
          | {:done, stop_reason :: String.t(), usage :: map() | nil}
          | {:cycle_end, kind :: String.t()}
          | {:permission_ask, request_id :: String.t(), tool :: String.t() | nil,
             options :: [map()]}
          | {:permission_denied, tool :: String.t() | nil, verdict :: String.t()}
          | {:failed, term()}

  @typedoc "A requested session config value: a select option's value, or a boolean."
  @type config_value :: String.t() | boolean()

  # ── public api ────────────────────────────────────────────────────────────

  @doc """
  Start a peer and send its first turn.

  Required: `:owner` (the pid reports go to, monitored), `:writer` (a
  `t:Managoat.ACP.Transport.writer/0`), `:ref` (echoed in every report),
  `:prompt`, `:mode` (`:run` opens a session with `session/new`; `:continue`
  resumes `:session_id` with `session/resume` or `session/load`) and
  `:session_id` (`nil` for `:run`).

  Optional: `:cwd` (default `"/home/sprite"`), `:images` (`[%{media_type:,
  data:}]`, raw bytes), `:mcp_servers` (already in ACP's shape), `:model`
  (pinned through `session/set_config_option` or `session/set_model` when the
  agent advertises either), `:permission_policy` (see
  `Managoat.ACP.Permissions`), `:pending_permission` (a held request handed
  back on reattach), `:client_capabilities` (default
  `Managoat.ACP.Protocol.default_client_capabilities/0`), `:replay_quiet_ms`
  and `:replay_max_ms` (the `session/load` window), `:auth` (which
  advertised method to `authenticate` with: `:api_key`, the default, picks
  the first method whose `_meta` names an api key; `:none` never
  authenticates, for an agent whose credentials the host has already put
  where it reads them; a method id picks that one when advertised), and
  `:attach`.

  `:additional_directories` is a list of absolute paths the agent may use
  beyond `:cwd` — ACP's `additionalDirectories`, which codex-acp adds to its
  sandbox's writable roots and claude-agent-acp to the SDK's. It is sent on
  session creation/load/resume only when the agent advertises
  `sessionCapabilities.additionalDirectories`, and left off otherwise, so a
  runtime without the concept is never handed a field it did not offer. An
  entry that is not an absolute path returns an error before any handshake
  bytes are written.

  `:config` is a map of session config option id to value (a string or a
  boolean) applied through `session/set_config_option` after the model and
  before every prompt — reasoning effort, fast mode, whatever the agent
  advertises. Ids and values are the agent's own and are not checked against
  a list here: an id the agent does not advertise is skipped and reported,
  and a value it refuses fails the turn. An option an earlier turn changed
  that the current request does not name is put back to the value the agent
  reported before the session's first change to it (`{:config_restored, id,
  confirmed}`). `"model"` is not accepted here; `:model` owns it. See the
  README's "Session config options".

  `:execution_limits` accepts a validated `Managoat.ACP.ExecutionLimits` value.
  It is sent on session creation/load/resume and retained on this connection.
  Invalid limits return an error before any handshake bytes are written. The
  host owns compatible adapter selection, ceilings and durable accounting.

  `attach: prompt_id` skips the handshake and resumes a turn whose
  `session/prompt` (with that JSON-RPC id) is already outstanding on the
  transport — see the moduledoc. `:session_id` must be the live session's id
  so `cancel/1` still works.

  The peer is started unlinked (`GenServer.start/2`): the owner monitors it,
  it monitors the owner, and neither takes the other down.
  """
  @spec start(keyword()) :: GenServer.on_start()
  def start(opts) do
    _ = writer!(opts)

    with :ok <- validate_directories(Keyword.get(opts, :additional_directories, [])),
         :ok <- validate_config(Keyword.get(opts, :config) || %{}),
         {:ok, _limits} <- ExecutionLimits.validate(Keyword.get(opts, :execution_limits)) do
      GenServer.start(__MODULE__, opts)
    end
  end

  @doc """
  Feed a chunk of inbound bytes. Chunks respect no message boundary.

  The host calls this from wherever its bytes arrive — a sandbox's stdout
  message, a port's data message, a socket frame.
  """
  @spec stdout(pid(), binary()) :: :ok
  def stdout(pid, data), do: GenServer.cast(pid, {:stdout, data})

  @doc """
  Send the next turn on a connection that is `:idle` — the previous prompt was
  answered and the peer stayed up (#817).

  Reuses the session already open on this connection: no handshake, no
  `session/resume`, model selection before each prompt. Reports `{:prompt_sent, id}` exactly as the
  first prompt did, so the reattach contract is unchanged. Refused with
  `{:error, {:not_idle, phase}}` while a prompt is outstanding or the
  connection is still being set up — never a silent second prompt on the wire.
  """
  @spec prompt(pid(), String.t(), [map()]) :: :ok | {:error, {:not_idle, atom()}}
  def prompt(pid, prompt, images \\ []) when is_binary(prompt) do
    prompt(pid, prompt, images, [])
  end

  @doc """
  Send a turn with an updated model; selection completes before the prompt is written.
  `:config` replaces the requested session config options for this turn and
  the ones after it (`nil` clears them); omitting it keeps the previous
  request. A malformed map returns `{:error, :invalid_config}`.
  An explicit `:execution_limits` must equal the existing connection limits.
  Changed or malformed limits return an error without sending a prompt.
  """
  @spec prompt(pid(), String.t(), [map()], keyword()) ::
          :ok | {:error, atom() | {:not_idle, atom()}}
  def prompt(pid, prompt, images, opts) when is_binary(prompt) do
    GenServer.call(pid, {:prompt, prompt, images, opts})
  end

  @doc """
  Start a fresh session after a failed resume/load, on the same initialized connection.

  The host decides whether the resumption error means its session is gone and
  whether losing that context is acceptable. This call is allowed only after a
  resume/load response failed before a prompt was sent. It retains the prompt,
  images, model, permissions, MCP servers, execution limits, request sequence
  and original monotonic start time. It sends `session/new`, without another
  `initialize` or a new transport. A failed `session/new` cannot restart again.

  The host still owns its retry budget, recovery notice and absolute execution
  deadline. The writer remains the same, including any durable write fencing.
  """
  @spec restart_session(pid()) ::
          :ok | {:error, :not_restartable | :acp_session_restart_failed}
  def restart_session(pid), do: GenServer.call(pid, :restart_session)

  @doc """
  Close the connection cleanly.

  The owner calls this when the transport stops being its own — the sandbox
  is parked or destroyed, the owner shuts down. The peer stops with
  `:normal`; the transport is the owner's to stop. Safe to call on a peer that has
  already gone.
  """
  @spec close(pid()) :: :ok
  def close(pid), do: GenServer.cast(pid, :close)

  @doc """
  Ask the agent to stop the current turn.

  `session/cancel` is a notification with no reply; the agent answers the
  original `session/prompt` with a `cancelled` stop reason, which is what
  actually ends the turn.
  """
  def cancel(pid), do: GenServer.cast(pid, :cancel)

  @doc """
  Answer an outstanding `session/request_permission` with one of the options
  the agent offered.

  `option_id` must be an id from that request's own option list; anything else
  is refused rather than forwarded, which is the fail-closed rule applied to
  the answer side. Returns `{:error, :no_pending_permission}` when the request
  has already been answered — by another client, by the timeout, or by the turn
  ending — so a caller can tell "too late" from "wrong option".
  """
  @spec answer_permission(pid(), String.t(), String.t()) ::
          :ok | {:error, :no_pending_permission | :unknown_option}
  def answer_permission(pid, request_id, option_id) do
    GenServer.call(pid, {:answer_permission, request_id, option_id})
  end

  @doc """
  Refuse an outstanding permission request without a human answering.

  This is what the timeout fires, and what the turn's end calls if a request is
  still open. Picks a `reject_*` the agent offered, or `cancelled` when it
  offered none — never an allow.
  """
  @spec deny_permission(pid(), String.t()) :: :ok
  def deny_permission(pid, request_id) do
    GenServer.cast(pid, {:deny_permission, request_id})
  end

  # ── callbacks ─────────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    owner = Keyword.fetch!(opts, :owner)

    state = %State{
      owner: owner,
      owner_mon: Process.monitor(owner),
      writer: writer!(opts),
      ref: Keyword.fetch!(opts, :ref),
      prompt: Keyword.fetch!(opts, :prompt),
      mode: Keyword.fetch!(opts, :mode),
      session_id: Keyword.fetch!(opts, :session_id),
      cwd: Keyword.get(opts, :cwd, "/home/sprite"),
      images: Keyword.get(opts, :images, []),
      session_options: %{
        mcp_servers: Keyword.get(opts, :mcp_servers, []),
        additional_directories: Keyword.get(opts, :additional_directories, []),
        execution_limits: Keyword.get(opts, :execution_limits)
      },
      permission_policy: Keyword.get(opts, :permission_policy) || %{},
      pending_permission: restore_pending(Keyword.get(opts, :pending_permission)),
      model: Keyword.get(opts, :model),
      config: %{
        requested: Keyword.get(opts, :config) || %{},
        options: nil,
        queue: [],
        baseline: %{}
      },
      client_capabilities:
        Keyword.get(opts, :client_capabilities) || Protocol.default_client_capabilities(),
      replay_window: %{
        quiet_ms: Keyword.get(opts, :replay_quiet_ms, @replay_quiet_ms),
        max_ms: Keyword.get(opts, :replay_max_ms, @replay_max_ms)
      },
      auth: %{choice: Keyword.get(opts, :auth, :api_key), methods: [], authenticated?: false},
      started_mono: System.monotonic_time(:millisecond)
    }

    case Keyword.get(opts, :attach) do
      nil ->
        {:ok, state, {:continue, :initialize}}

      prompt_id when is_integer(prompt_id) ->
        {:ok,
         %{
           state
           | phase: :prompting,
             pending: %{prompt_id => :prompt},
             next_id: prompt_id + 1,
             attached?: true,
             drop_partial_line?: true
         }}
    end
  end

  # Checked at start rather than at the first write, so a host that passes
  # the old `command:` option (or nothing) fails on `start/1` with a message
  # naming the seam, not mid-handshake with a badfun.
  defp writer!(opts) do
    case Keyword.get(opts, :writer) do
      writer when is_function(writer, 1) ->
        writer

      other ->
        raise ArgumentError,
              "Managoat.ACP.Peer.start/1 needs writer: (iodata -> :ok | {:error, term}), " <>
                "got #{inspect(other)}; see Managoat.ACP.Transport"
    end
  end

  @impl true
  def handle_continue(:initialize, state) do
    send_request(
      state,
      :initialize,
      "initialize",
      Protocol.initialize_params(state.client_capabilities)
    )
    |> noreply()
  end

  @impl true
  def handle_cast({:stdout, data}, %State{drop_partial_line?: true} = state) do
    # The replay starts wherever the sandbox's buffer happens to start, which is
    # mid-line unless we are lucky. A fragment that does not open a JSON object
    # can only be the tail of a line we cannot parse: drop through its newline.
    # A chunk with no newline yet is the same fragment still arriving.
    cond do
      String.starts_with?(data, "{") ->
        handle_cast({:stdout, data}, %{state | drop_partial_line?: false})

      String.contains?(data, "\n") ->
        [_partial, rest] = String.split(data, "\n", parts: 2)
        handle_cast({:stdout, rest}, %{state | drop_partial_line?: false})

      true ->
        {:noreply, state}
    end
  end

  def handle_cast({:stdout, data}, state) do
    {messages, buffer} = Protocol.feed(state.transcript.buffer, data)

    messages
    |> Enum.reduce(put_in(state.transcript.buffer, buffer), &handle_message/2)
    |> noreply()
  end

  def handle_cast(:cancel, %State{session_id: id} = state) when is_binary(id) do
    state
    |> write(Protocol.notification("session/cancel", %{sessionId: id}))
    |> noreply()
  end

  def handle_cast(:cancel, state), do: {:noreply, state}

  def handle_cast(:close, state), do: {:stop, :normal, state}

  def handle_cast({:deny_permission, request_id}, state) do
    case state.pending_permission do
      %{request_id: ^request_id, id: id, options: options} ->
        outcome = Permissions.deny_outcome(options)

        state
        |> write(Protocol.response(id, %{outcome: outcome}))
        |> Map.put(:pending_permission, nil)
        |> noreply()

      _ ->
        {:noreply, state}
    end
  end

  # Fountain's catch-all rule (#2380): an unmatched cast must not take the
  # session down. The shape only — a cast can carry adapter output.
  def handle_cast(msg, state) do
    Logger.warning("acp peer: unexpected cast #{message_shape(msg)}")
    {:noreply, state}
  end

  defp message_shape(msg) when is_tuple(msg) and tuple_size(msg) > 0,
    do: "{#{inspect(elem(msg, 0))}, ...}/#{tuple_size(msg)}"

  defp message_shape(msg) when is_atom(msg), do: inspect(msg)
  defp message_shape(_msg), do: "a non-tuple term"

  @impl true
  def handle_call(
        :restart_session,
        _from,
        %State{phase: :failed, failed_session_setup: tag} = state
      )
      when tag in [:resume_session, :load_session] do
    state =
      start_new_session(%{
        state
        | mode: :run,
          session_id: nil,
          transcript: %{buffer: state.transcript.buffer, plans: %Managoat.ACP.Plans{}},
          phase: :starting_session,
          failed_session_setup: nil,
          replay_discard?: false,
          replay_result: nil,
          replay_last_ms: nil,
          replay_until_ms: nil
      })

    result = if state.phase == :failed, do: {:error, :acp_session_restart_failed}, else: :ok
    {:reply, result, state}
  end

  def handle_call(:restart_session, _from, state),
    do: {:reply, {:error, :not_restartable}, state}

  def handle_call({:prompt, prompt, images, opts}, _from, %State{phase: :idle} = state) do
    requested = Keyword.get(opts, :execution_limits, state.session_options.execution_limits)

    with {:ok, limits} <- ExecutionLimits.validate(requested),
         true <- limits == state.session_options.execution_limits,
         :ok <- validate_config(Keyword.get(opts, :config, state.config.requested) || %{}) do
      prompt_on_connection(state, prompt, images, opts)
    else
      false -> {:reply, {:error, :acp_execution_limits_changed}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:prompt, _prompt, _images, _opts}, _from, state) do
    {:reply, {:error, {:not_idle, state.phase}}, state}
  end

  # Answering is a `call` so the caller learns whether the answer landed: the
  # request may already have been resolved by another attached client, by the
  # timeout, or by the turn ending, and "too late" and "wrong option" are
  # different things to tell a user.
  def handle_call({:answer_permission, request_id, option_id}, _from, state) do
    case state.pending_permission do
      %{request_id: ^request_id, id: id, options: options} ->
        if Enum.any?(options, &(&1["optionId"] == option_id)) do
          state =
            write(
              state,
              Protocol.response(id, %{outcome: %{outcome: "selected", optionId: option_id}})
            )

          {:reply, :ok, %{state | pending_permission: nil}}
        else
          # Never forward an id the agent did not offer. The adapter would at
          # best error and at worst match something unrelated.
          {:reply, {:error, :unknown_option}, state}
        end

      _ ->
        {:reply, {:error, :no_pending_permission}, state}
    end
  end

  @impl true
  def handle_info({:DOWN, mon, :process, _pid, _reason}, %State{owner_mon: mon} = state) do
    # The owner is gone; there is nobody to report to and the transport is
    # its property, not ours.
    {:stop, :normal, state}
  end

  def handle_info(:replay_check, %State{phase: :draining_replay} = state) do
    quiet_for = now_ms() - state.replay_last_ms

    if quiet_for >= state.replay_window.quiet_ms or now_ms() >= state.replay_until_ms do
      %{state | replay_discard?: false}
      |> pin_model_then_prompt(state.replay_result)
      |> noreply()
    else
      state |> schedule_replay_check(state.replay_window.quiet_ms - quiet_for) |> noreply()
    end
  end

  # A turn that failed or was answered while a check was in flight.
  def handle_info(:replay_check, state), do: {:noreply, state}

  def handle_info(msg, state) do
    Logger.debug("acp peer: unexpected message #{inspect(msg)}")
    {:noreply, state}
  end

  # ── message dispatch ──────────────────────────────────────────────────────

  # The host must route one process stream to one peer. Check the identity
  # before replay accounting, persistence, or autonomous-cycle handling too:
  # a foreign frame is never this session's history (issue #5).
  defp handle_message(
         {:notification, "session/update", %{"sessionId" => incoming}},
         %State{session_id: expected} = state
       )
       when not is_nil(incoming) and not is_nil(expected) and incoming != expected do
    Logger.warning("acp peer: dropping update for a different session")
    state
  end

  # Fail closed without consulting this peer's policy or holding a question
  # for its owner. `cancelled` is valid even when no reject option is offered.
  defp handle_message(
         {:request, id, "session/request_permission", %{"sessionId" => incoming}},
         %State{session_id: expected} = state
       )
       when not is_nil(incoming) and not is_nil(expected) and incoming != expected do
    Logger.warning("acp peer: cancelling permission request for a different session")
    write(state, Protocol.response(id, %{outcome: %{outcome: "cancelled"}}))
  end

  defp handle_message({:notification, "session/update", params}, state) do
    {params, plans} = Managoat.ACP.Plans.normalize(params, state.transcript.plans)
    state = put_in(state.transcript.plans, plans)

    if state.replay_discard? do
      # Replay of history we already hold. Dropped, not persisted — see the
      # moduledoc. The timestamp is what the quiet period below measures.
      %{state | replay_last_ms: now_ms()}
    else
      state
      |> persist("acp", Protocol.notification("session/update", params))
      |> report_cycle_end(params)
      |> track_config_options(params)
    end
  end

  defp handle_message({:notification, _method, _params}, state), do: state

  defp handle_message({:response, id, result}, state) do
    case pop_pending(state, id) do
      {nil, %State{attached?: true} = state} ->
        # A replayed answer to the previous peer's handshake. Expected.
        state

      {nil, state} ->
        Logger.warning("acp peer: response to unknown request #{inspect(id)}")
        state

      {tag, state} ->
        handle_response(tag, result, state)
    end
  end

  # A refusal must stop before inference; the host cannot retract bytes already written.
  defp handle_message({:error_response, id, error}, %State{phase: :setting_model} = state)
       when is_map_key(state.pending, id) do
    {_tag, state} = pop_pending(state, id)
    fail(state, {:model_selection_failed, state.model, error_detail(error)})
  end

  # The same rule for a config option the agent advertised: its refusal is the
  # check (there is no list of valid values here), and it names the fault in
  # its own words, so the turn fails with them rather than running on a
  # setting nobody asked for (managoat/fountain#724 is the model precedent).
  defp handle_message({:error_response, id, error}, %State{phase: :setting_config} = state)
       when is_map_key(state.pending, id) do
    case pop_pending(state, id) do
      {{:set_config, config_id, value}, state} ->
        fail(state, {:config_selection_failed, config_id, value, error_detail(error)})

      # Nobody asked for a restore, so its refusal must not fail a turn that
      # asked for nothing. The baseline goes (it is evidently not a value
      # this agent takes any more) and the turn runs on what is there; the
      # `:config_options` report after the queue says what that is.
      {{:restore_config, config_id, value}, state} ->
        Logger.warning(
          "acp peer: could not restore #{config_id} to #{inspect(value)}: " <>
            error_detail(error)
        )

        state
        |> update_in([Access.key!(:config), :baseline], &Map.delete(&1, config_id))
        |> apply_next_config()
    end
  end

  # Attached mid-turn: an error for an id we never sent is a replay of one the
  # previous peer already handled — a `session/set_config_option` refusal is the
  # common one, and it was reported as a stage event at the time. Only the
  # prompt's own error can fail this turn.
  defp handle_message({:error_response, id, _error}, %State{attached?: true} = state)
       when not is_map_key(state.pending, id),
       do: state

  # Backstop for an agent that advertises no auth method at `initialize` and
  # then refuses anyway. The eager path above covers everything measured; this
  # covers being wrong about that, once, rather than failing the turn outright.
  defp handle_message({:error_response, id, error}, state) do
    {tag, state} = pop_pending(state, id)

    cond do
      session_setup?(tag) and auth_error?(error) and not state.auth.authenticated? and
          auth_method(state) ->
        method = auth_method(state)
        Logger.info("acp peer: #{tag} needs authentication; retrying with #{method}")

        send_request(
          %{state | auth: %{state.auth | authenticated?: true}},
          :authenticate,
          "authenticate",
          %{methodId: method}
        )

      # Claude's own error kind for "the Anthropic org owning this OAuth token
      # has disabled subscription (Claude Code) access" (#655). It arrives
      # over ACP as a generic JSON-RPC -32603 "Internal error" — nothing in
      # `code` marks it, so the kind has to be found in the error body's text
      # rather than read off a field. Scoped to the `:prompt` call: session
      # setup can fail for unrelated reasons, and the auth-retry clause above
      # already owns those.
      tag == :prompt and oauth_org_not_allowed?(error) ->
        fail(state, {:oauth_org_not_allowed, error_detail(error)})

      # The provider refused the model itself (#970). Here rather than in the
      # generic arm for the same reason as the clause above: the tenant can act
      # on it, but only if it reaches them as a sentence.
      tag == :prompt and model_unavailable?(error) ->
        fail(state, {:model_unavailable, state.model, error_detail(error)})

      true ->
        fail(state, {:acp_error, tag, error})
    end
  end

  # `session/request_permission` is the channel gate 3 exists to use. Gate 2
  # answered it with a constant auto-allow, which was parity with the legacy
  # path's `--dangerously-skip-permissions` and friends. #939 made that a
  # policy: `Permissions` decides per tool, and `auto_allow` — still the
  # default — keeps the old ladder verbatim, so this is parity until someone
  # writes a policy.
  #
  # Answering *something* is not optional: the agent blocks on this request, and
  # a blocked agent is a turn in flight, which for a metered sandbox means a
  # bill that runs to the ceiling.
  #
  # The verdict is reported to the owner so a denial reaches the audit trail
  # (0013 — in the context, tool and verdict, never values). Allows are not
  # recorded: a turn makes dozens of tool calls, and a row each would make the
  # trail a transcript.
  defp handle_message({:request, id, "session/request_permission", params}, state) do
    tool = Permissions.tool_name(params)
    verdict = Permissions.verdict_for_request(state.permission_policy, params)

    cond do
      held?(state, id) ->
        # The replay of a request this peer already holds, which is what a
        # reattach reads out of the sandbox's buffer (#967). Raising it again
        # would publish a second card for one question, and — because the id a
        # client answers with is minted per hold — would leave the card someone
        # is actually looking at unanswerable. The agent is still blocked on
        # the request we are already holding, so there is nothing to do.
        state

      verdict == "ask" ->
        hold_permission(state, id, tool, params)

      true ->
        if verdict != "auto_allow", do: report(state, {:permission_denied, tool, verdict})

        write(
          state,
          Protocol.response(id, %{
            outcome: Permissions.outcome(state.permission_policy, params)
          })
        )
    end
  end

  defp handle_message({:request, id, method, _params}, state) do
    Logger.warning("acp peer: refusing unsupported client method #{method}")
    write(state, Protocol.error(id, Protocol.method_not_found(), "#{method} is not supported"))
  end

  # Adapters and the Node runtime under them write warnings and stack traces to
  # stdout. Those are output, not protocol, and the transcript is more useful
  # with them in it.
  defp handle_message({:invalid, line}, state), do: persist(state, "stdout", [line, "\n"])

  # A `usage_update` whose origin is in the adapter's autonomous set marks the
  # end of a background cycle (#817). Reported as its own payload so the owner
  # can close the autonomous turn it opened without re-parsing persisted
  # lines. A plain `usage_update` — the user turn's own — reports nothing.
  defp report_cycle_end(state, params) do
    case autonomous_origin(params) do
      nil -> state
      kind -> tap(state, &report(&1, {:cycle_end, kind}))
    end
  end

  defp autonomous_origin(params) do
    update = Map.get(params, "update") || %{}

    with "usage_update" <- Map.get(update, "sessionUpdate"),
         kind when is_binary(kind) <- origin_kind(update) || origin_kind(params),
         true <- kind in @autonomous_origins do
      kind
    else
      _ -> nil
    end
  end

  # Both pinned adapters announce a changed option set this way — claude's when
  # fast mode drops into cooldown, for instance — so the next turn starts from
  # what the agent last said rather than from the session result.
  defp track_config_options(state, %{"update" => %{"sessionUpdate" => "config_option_update"} = u}),
       do: remember_config_options(state, u)

  defp track_config_options(state, _params), do: state

  defp origin_kind(%{"_meta" => %{"_claude/origin" => %{"kind" => kind}}}), do: kind
  defp origin_kind(_), do: nil

  # Whether this is the request the peer is already holding open. An agent
  # cannot have two requests outstanding under one JSON-RPC id, so a matching
  # id while something is held means the line was replayed, not re-asked.
  defp held?(%{pending_permission: %{id: held_id}}, id), do: held_id == id
  defp held?(_state, _id), do: false

  # `ask`: do not answer. The agent stays blocked while a human decides, which
  # is the whole point, and is also why a timeout is not optional — see the
  # owner, which arms one.
  #
  # The request line is persisted to the `acp` stream so it renders as a
  # `permission_request` block inline in the transcript, exactly where the tool
  # card it is about appears. The resolution is a separate `request` stage
  # event: log events are immutable, so a block cannot become "answered" — the
  # client pairs the two on `request_id`.
  defp hold_permission(state, id, tool, params) do
    options = Enum.filter(Map.get(params, "options") || [], &is_map/1)
    request_id = mint_request_id(id)

    state =
      persist(state, "acp", Protocol.request(request_id, "session/request_permission", params))

    report(state, {:permission_ask, request_id, tool, options})

    %{
      state
      | pending_permission: %{id: id, request_id: request_id, options: options, tool: tool}
    }
  end

  # The id a client answers with, which is **not** the adapter's own JSON-RPC
  # id. Measured against claude-agent-acp 0.66 in production: it numbers its
  # requests from 0 *per turn*, so every conversation's second permission
  # request arrives as id 0 again. Two live consequences, both from one cause:
  #
  # - a client pairing the resolution to the request on `request_id` (which is
  #   the contract) marks the new card resolved the moment it renders, because
  #   turn 2's `request`/`done` already named that id;
  # - answering from a stale card would land on whatever request is open *now*,
  #   approving a tool the person never saw.
  #
  # So the peer mints the public id: the adapter's own id, a dot, and eight
  # random bytes. The adapter id stays in front because a transcript is read
  # beside adapter logs, and `restore_pending/1` reads it back to answer with
  # the id the agent is actually blocked on. A stale card now misses and gets
  # the same 409 as any other lost race.
  defp mint_request_id(id) do
    "#{id}.#{Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)}"
  end

  # We declared no filesystem or terminal capabilities, so nothing should ask.
  # If something does, it gets a JSON-RPC error rather than silence.

  # ── responses ─────────────────────────────────────────────────────────────

  defp handle_response(:initialize, result, state) do
    caps = Map.get(result, "agentCapabilities") || %{}

    state = %{
      state
      | capabilities: caps,
        auth: %{state.auth | methods: Map.get(result, "authMethods") || []}
    }

    # Labelled with the session-setup call we are about to make, not with the
    # owner's idea of the mode: an owner may persist a generated session id
    # before the first turn spawns, and by the time this lands cannot tell a
    # `session/new` from a resume. A resume and a new session pay different
    # prices, and averaging them hides whichever is the problem.
    method = if state.mode == :run, do: "session/new", else: resume_method(state)

    report(
      state,
      {:handshake_ms, System.monotonic_time(:millisecond) - state.started_mono, method}
    )

    # Authenticate *before* opening a session, when the agent offers a method.
    #
    # This was reactive at first — authenticate only when a call is refused —
    # and that is too late to be useful. Gemini will happily open a session
    # from ambient credentials without being told which auth method to use, but
    # it does not *persist* one: the next turn's `session/load` answers "No
    # previous sessions found for this project", so the retry authenticates
    # correctly and then finds nothing to load. The session has to be created
    # under a chosen method to exist at all.
    #
    # Safe to do eagerly because an agent that needs nothing advertises
    # nothing: claude's adapter returns `authMethods: []` (measured), so
    # `auth_method/1` is nil and this is skipped entirely for it.
    case auth_method(state) do
      nil ->
        start_session(state)

      chosen ->
        send_request(
          %{state | auth: %{state.auth | authenticated?: true}},
          :authenticate,
          "authenticate",
          %{
            methodId: chosen
          }
        )
    end
  end

  defp handle_response(:new_session, result, state) do
    case Map.get(result, "sessionId") do
      id when is_binary(id) ->
        report(state, {:session, id})

        %{state | session_id: id}
        |> remember_config_options(result)
        |> pin_model_then_prompt(result)

      _ ->
        fail(state, {:acp_no_session_id, result})
    end
  end

  defp handle_response(:resume_session, result, state),
    do: state |> remember_config_options(result) |> pin_model_then_prompt(result)

  # ACP says the agent MUST replay the conversation as `session/update`
  # notifications *before* responding to `session/load`, which would make this
  # response the end of the replay. Gemini does not: it calls its
  # `streamHistory` as a floating promise and answers first, so the replay
  # arrives after this point and would land in `log_events` — duplicating the
  # transcript on every turn after the first (#657, measured against a live
  # agent: two `:text` blocks reading `"ECHO-5ECHO-5"`).
  #
  # So the response is not the signal. We keep discarding until the stream has
  # been quiet for `replay_quiet_ms`, then prompt. Timing is the only thing
  # separating replay from answer here — both arrive as `session/update` on the
  # same session, and the fresh answer cannot begin before we send
  # `session/prompt`, which the quiet period gates. Do not "fix" this by
  # widening the discard past the prompt; that drops the answer.
  #
  # The wait is capped: an agent that never goes quiet must not hold a turn
  # open, because a turn in flight disarms idle reclaim (#413). The cost is
  # cheap next to gemini's ~2.8s handshake, and it comes off entirely when the
  # upstream `await` lands.
  defp handle_response(:load_session, result, state) do
    state = remember_config_options(state, result)

    schedule_replay_check(%{
      state
      | phase: :draining_replay,
        replay_result: result,
        replay_last_ms: now_ms(),
        replay_until_ms: now_ms() + state.replay_window.max_ms
    })
  end

  defp handle_response(:set_model, result, state) do
    state = remember_config_options(state, result)
    effective = current_model(result)

    if is_binary(effective) and not same_model?(effective, state.model) do
      fail(
        state,
        {:model_selection_failed, state.model,
         "Runtime confirmed a different model: #{effective}"}
      )
    else
      source = if effective, do: "runtime", else: "selection_ack"

      model_settled(%{
        state
        | model_selection: %{
            state.model_selection
            | effective: effective || state.model,
              source: source
          }
      })
    end
  end

  # The setter answers with the whole option set as it now stands, which is
  # how a value the agent normalised or clamped gets reported as what it is.
  defp handle_response({:set_config, config_id, value}, result, state) do
    state = remember_config_options(state, result)
    confirmed = Map.get(find_option(state.config.options, config_id) || %{}, "currentValue")
    report(state, {:config_selected, config_id, value, confirmed})
    apply_next_config(state)
  end

  defp handle_response({:restore_config, config_id, _value}, result, state) do
    state = remember_config_options(state, result)
    confirmed = Map.get(find_option(state.config.options, config_id) || %{}, "currentValue")
    report(state, {:config_restored, config_id, confirmed})
    apply_next_config(state)
  end

  # Authenticated; open (or reopen) the session.
  defp handle_response(:authenticate, _result, state), do: start_session(state)

  # The turn's usage rides along with the stop reason (#827): it is the one
  # end-of-turn figure the runtime reports, and the response is the only place
  # it appears. nil when the runtime reports none.
  #
  # The turn is over; the connection is not (#817). `:idle` is where the next
  # `prompt/3` is accepted, and where out-of-turn updates keep flowing up.
  defp handle_response(:prompt, result, state) do
    stop =
      case Map.get(result, "stopReason") do
        reason when is_binary(reason) and byte_size(reason) > 0 -> reason
        _ -> "unknown"
      end

    report(state, {:done, stop, Usage.from_prompt_result(result)})
    %{state | phase: :idle}
  end

  # ── authentication ────────────────────────────────────────────────────────

  defp session_setup?(tag), do: tag in [:new_session, :resume_session, :load_session]

  defp auth_error?(%{"code" => -32_000}), do: true

  defp auth_error?(%{"message" => message}) when is_binary(message),
    do: String.contains?(String.downcase(message), "auth")

  defp auth_error?(_), do: false

  # inspect/1 rather than pattern-matching a specific key: the adapter's exact
  # placement of the kind (top-level, `data.details`, `data.kind`, ...) has
  # not been pinned down against a live org-disallowed account, and a
  # substring search over the whole payload is total — it cannot raise on a
  # shape we did not anticipate, unlike a `get_in` chain would.
  defp oauth_org_not_allowed?(error),
    do: error |> inspect() |> String.contains?("oauth_org_not_allowed")

  # The provider retired the model, or never had it, or this key cannot reach
  # it. Google's is the one that prompted this (#970), and it is the awkward
  # shape: the model was in the host's own catalog, `session/set_model`
  # accepted it (google's listing endpoint still advertises models it has
  # retired), and the refusal arrived only when the turn called it.
  #
  #     "This model models/gemini-2.5-pro is no longer available to new users.
  #      Please update your code to use models/gemini-3.1-pro-preview ..."
  #
  # Left in the generic arm, that reached the tenant as an inspected
  # `{:acp_error, :prompt, %{...}}` tuple: the one thing they have to change,
  # printed in the one register they cannot act on.
  #
  # There is no field to key off. Google sends this as a 500, anthropic and
  # openai as a 404 their adapters re-wrap, and none of the three marks the
  # kind — so it is read out of the sentence. Both halves are required, a
  # phrase *and* the word model, so that a "not found" about a file, a session
  # or an MCP server is never read as a model refusal.
  @model_gone_phrases [
    "no longer available",
    "does not exist or you do not have access",
    "is not found for api version",
    "model_not_found",
    "model not found",
    "unknown model",
    "invalid model"
  ]

  defp model_unavailable?(error) do
    text = error |> inspect() |> String.downcase()

    String.contains?(text, "model") and
      Enum.any?(@model_gone_phrases, &String.contains?(text, &1))
  end

  # `:none`: the host has put credentials where the agent reads them itself
  # (codex-acp with an externally managed ChatGPT `auth.json`), and the
  # api-key method would *replace* them — codex-acp's runs
  # `accountLogin({type: "apiKey"})` from an env var, rewriting the file.
  # Measured 2026-09-08. So the host says "do not", and the session opens on
  # what is there.
  defp auth_method(%{auth: %{choice: :none}}), do: nil

  # A named method: only when the agent advertises it; a name the agent does
  # not know would be refused, and a refusal on a headless sandbox is the
  # turn's end.
  defp auth_method(%{auth: %{choice: id, methods: methods}}) when is_binary(id) do
    if Enum.any?(methods, &(Map.get(&1, "id") == id)), do: id, else: nil
  end

  # Prefer a method naming an API key in its `_meta`: that is what an agent
  # offers for "there is a key in the environment, use it", as against an
  # interactive OAuth flow a headless sandbox can never complete.
  defp auth_method(state) do
    case Enum.find(state.auth.methods, &api_key_method?/1) do
      %{"id" => id} when is_binary(id) -> id
      _ -> nil
    end
  end

  # An api-key method only — never "whatever it listed first".
  #
  # Measured 2026-08-10: opencode advertises exactly `["opencode-login"]`, and
  # a first-in-the-list fallback picked it. It happened to return ok, but the
  # name is an interactive login and a headless sandbox cannot complete one; an
  # agent that *blocked* on it would leave a turn in flight forever, which
  # disarms idle reclaim and bills the sandbox to its ceiling. Getting away with
  # it once is not evidence.
  #
  # Nothing needs the fallback. Of the four runtimes, only gemini requires
  # authentication at all, and it advertises an api-key method; claude
  # advertises none, and codex and opencode were both driven through a full
  # turn without ever authenticating.
  defp api_key_method?(method) do
    meta = Map.get(method, "_meta")
    is_map(meta) and Map.has_key?(meta, "api-key")
  end

  defp prompt_on_connection(state, prompt, images, opts) do
    state = %{
      state
      | prompt: prompt,
        images: images,
        model: Keyword.get(opts, :model, state.model),
        config: %{
          state.config
          | requested: Keyword.get(opts, :config, state.config.requested) || %{}
        }
    }

    state = pin_model_then_prompt(state, state.model_selection.result)

    if state.phase == :failed,
      do: {:reply, {:error, {:not_idle, :failed}}, state},
      else: {:reply, :ok, state}
  end

  # ── session setup ─────────────────────────────────────────────────────────

  defp start_session(%State{mode: :run} = state), do: start_new_session(state)
  defp start_session(%State{mode: :continue} = state), do: resume_session(state)

  # No client-proposed `sessionId`. The spec is explicit that the *agent*
  # "MUST respond with a unique Session ID", and we overwrite whatever we sent
  # with what comes back anyway — so proposing one was decoration that a
  # stricter agent could reject on schema grounds.
  defp start_new_session(state) do
    send_request(
      %{forget_config_baseline(state) | phase: :starting_session},
      :new_session,
      "session/new",
      session_params(state, %{cwd: state.cwd, mcpServers: state.session_options.mcp_servers})
    )
  end

  defp resume_session(%State{session_id: nil} = state) do
    # `mode == :continue` with no id is a contradiction the caller should not be
    # able to produce; failing loudly beats silently starting a second session
    # that renders as the same conversation.
    fail(state, :acp_resume_without_session_id)
  end

  defp resume_session(state) do
    state = forget_config_baseline(state)

    # Resumption re-sends the servers rather than assuming the agent kept them.
    # The adapter snapshots `{cwd, mcpServers}` per session and tears the
    # session down when they change, so omitting them here would read as
    # "the client removed every MCP server".
    params =
      session_params(state, %{
        sessionId: state.session_id,
        cwd: state.cwd,
        mcpServers: state.session_options.mcp_servers
      })

    case resume_method(state) do
      "session/resume" ->
        send_request(
          %{state | phase: :starting_session},
          :resume_session,
          "session/resume",
          params
        )

      "session/load" ->
        # The expensive path: everything until the response is history we
        # already have.
        %{state | phase: :starting_session, replay_discard?: true}
        |> send_request(:load_session, "session/load", params)

      _ ->
        fail(state, :acp_agent_cannot_resume)
    end
  end

  # What every session-setup call carries beyond its own fields. The
  # directories are re-sent on resume and load for the same reason the MCP
  # servers are: the adapters fingerprint them per session, so leaving them
  # off would read as "the client removed them".
  defp session_params(state, params) do
    params
    |> put_additional_directories(state)
    |> ExecutionLimits.session_params(state.session_options.execution_limits)
  end

  defp put_additional_directories(params, state) do
    case state.session_options.additional_directories do
      [] ->
        params

      directories ->
        if supports?(state, ["sessionCapabilities", "additionalDirectories"]),
          do: Map.put(params, :additionalDirectories, directories),
          else: params
    end
  end

  # Which resumption the agent's advertised capabilities allow, preferring the
  # one that does not replay. Consulted twice — once to label the handshake
  # measurement, once to make the call — so the number and the behaviour cannot
  # disagree.
  defp resume_method(state) do
    cond do
      supports?(state, ["sessionCapabilities", "resume"]) -> "session/resume"
      Map.get(state.capabilities, "loadSession") == true -> "session/load"
      true -> "none"
    end
  end

  # ACP carries no model in `session/new`. The runtime's own default therefore
  # wins unless the client says otherwise, which would silently ignore
  # `agent.model` — the field the tenant actually configured, and for a
  # multi-provider runtime the entire configuration.
  #
  # The mechanism is `session/set_config_option` with `configId: "model"`, and
  # the session response advertises which options exist. We only send it when
  # the agent said it has one, so a runtime with no model concept is left alone
  # rather than being handed a method it never offered.
  defp pin_model_then_prompt(state, result) do
    state = %{state | model_selection: %{state.model_selection | result: result}}

    cond do
      is_nil(state.model) or state.model == "" ->
        effective = state.model_selection.effective || current_model(result)

        model_settled(%{
          state
          | model_selection: %{
              state.model_selection
              | effective: effective,
                source: state.model_selection.source || "runtime"
            }
        })

      model_configurable?(result) ->
        send_request(%{state | phase: :setting_model}, :set_model, "session/set_config_option", %{
          sessionId: state.session_id,
          configId: "model",
          value: state.model
        })

      Map.has_key?(result, "models") ->
        send_request(%{state | phase: :setting_model}, :set_model, "session/set_model", %{
          sessionId: state.session_id,
          modelId: state.model
        })

      true ->
        fail(
          state,
          {:model_selection_failed, state.model,
           "Runtime does not expose model selection over ACP"}
        )
    end
  end

  # Two shapes in the wild, both measured against live agents on 2026-08-10.
  # Claude's adapter advertises `configOptions` and takes
  # `session/set_config_option` with `configId: "model"`; gemini advertises
  # `models` and implements ACP's own `session/set_model` with a `modelId`.
  # Neither is a superset of the other, so the session response decides.
  defp model_configurable?(result) do
    case Map.get(result, "configOptions") do
      options when is_list(options) -> Enum.any?(options, &(Map.get(&1, "id") == "model"))
      _ -> false
    end
  end

  # Whether the model the runtime confirmed is the one that was asked for.
  #
  # It is not a string comparison, and the reason cost a production outage.
  # A runtime is free to answer in its own canonical designation: claude's
  # adapter accepts `claude-opus-5` and confirms `opus`, and `claude-sonnet-5`
  # and confirms `sonnet`. That is the same model named less precisely, not a
  # substitution, and failing the turn over it took down every claude agent on
  # an instance the day strict equality shipped — while codex, which echoes the
  # id verbatim, looked fine.
  #
  # So: normalise away case and separators, then treat one designation
  # containing the other as agreement. `opus` against `claude-opus-5` agrees;
  # `claude-haiku-4-5` against `claude-opus-5` does not, and that is the case
  # worth failing — the runtime quietly answering as a different model.
  #
  # A runtime that confirms a family without a version (`sonnet`) leaves us
  # unable to tell `claude-sonnet-5` from `claude-sonnet-4-6`. That ambiguity
  # is the runtime's, not something a comparison here can resolve; the answer
  # is recorded as `effective` so a reader sees exactly what was confirmed.
  # An outright refusal is a separate signal and still fails the turn: it
  # arrives as an error response, handled above.
  defp same_model?(effective, requested) do
    a = normalise_model(effective)
    b = normalise_model(requested)

    a != "" and b != "" and (String.contains?(a, b) or String.contains?(b, a))
  end

  # A runtime may also qualify its answer with a variant the request never
  # named: claude confirms `opus[1m]` for the 1M-context build of the model
  # asked for as `claude-opus-5`. Dropping separators fuses that qualifier onto
  # the family name (`opus1m` against `claudeopus5`), which destroys the
  # containment the comparison above depends on — so the fix for the strict
  # equality outage failed the turn anyway, for a model that was working.
  # The qualifier annotates the model; it does not name a different one, so it
  # comes off before the comparison.
  #
  # Removed from both sides, which is symmetric and therefore does not detect a
  # variant *downgrade* — asking for `opus[1m]` and being given plain `opus`
  # reads as agreement. That is the same trade already made for the `sonnet`
  # ambiguity above, and it is answered the same way: `effective` records what
  # the runtime actually confirmed, so a reader can see the variant even though
  # the comparison ignored it.
  defp normalise_model(model) when is_binary(model) do
    model
    |> String.downcase()
    |> String.replace(~r/[\[(][^\])]*[\])]/, "")
    |> String.replace(~r/[^a-z0-9]/, "")
  end

  defp normalise_model(_), do: ""

  defp current_model(result) do
    options = Map.get(result, "configOptions", [])
    option = Enum.find(options, %{}, &(Map.get(&1, "id") == "model"))
    Map.get(option, "currentValue") || get_in(result, ["models", "currentModelId"])
  end

  # The model is pinned (or deliberately left alone). Everything else in the
  # option set is only valid for a given model — claude offers `effort` only on
  # a model that supports it, codex's `reasoning_effort` values are the model's
  # own — so config options come after it, against the set the pin returned.
  #
  # `:model_selected` is still reported from `send_prompt/1`, after the
  # options: hosts read it as "a prompt is about to be written" (Fountain
  # stamps the turn's inference source on it), and a config refusal must not
  # leave a turn that spent nothing looking like one that did.
  defp model_settled(state) do
    apply_next_config(put_in(state.config.queue, config_queue(state.config)))
  end

  # In the order the agent lists its options, which is the order its own UI
  # applies them in; ids it does not list go last, by name, to be skipped.
  #
  # A requested option holds for its turn only (managoat/fountain#2537, ADR
  # 0062): an id this session changed on an earlier turn that this turn does
  # not name is put back to its baseline, through the same queue, so the
  # "already so" check below spares the round trip when nothing moved.
  defp config_queue(config) do
    advertised =
      (config.options || [])
      |> Enum.map(&Map.get(&1, "id"))
      |> Enum.with_index()
      |> Map.new()

    restores =
      for {id, value} <- config.baseline,
          not Map.has_key?(config.requested, id),
          do: {:restore, id, value}

    Enum.sort_by(Enum.to_list(config.requested) ++ restores, fn entry ->
      id = config_entry_id(entry)
      {Map.get(advertised, id, map_size(advertised)), id}
    end)
  end

  defp config_entry_id({:restore, id, _value}), do: id
  defp config_entry_id({id, _value}), do: id

  defp forget_config_baseline(state), do: put_in(state.config.baseline, %{})

  # The first change to an id in this session records what it was before.
  defp remember_config_baseline(state, config_id, option) do
    case Map.get(option, "currentValue") do
      nil -> state
      current -> update_in(state.config.baseline, &Map.put_new(&1, config_id, current))
    end
  end

  # One at a time, each checked against the set as it stands after the last:
  # a setter may add or remove options, and a request for one the agent no
  # longer offers is skipped rather than sent to be refused.
  defp apply_next_config(%State{config: %{queue: []}} = state) do
    if is_list(state.config.options), do: report(state, {:config_options, state.config.options})
    send_prompt(state)
  end

  defp apply_next_config(%State{config: %{queue: [{:restore, config_id, value} | rest]}} = state) do
    state = put_in(state.config.queue, rest)
    option = find_option(state.config.options, config_id)

    cond do
      # The option is gone (another model), or no longer takes the old value:
      # there is nothing to put back. Silent, since nobody asked.
      is_nil(option) or not offers?(option, value) ->
        apply_next_config(state)

      Map.get(option, "currentValue") == value ->
        apply_next_config(state)

      true ->
        send_request(
          %{state | phase: :setting_config},
          {:restore_config, config_id, value},
          "session/set_config_option",
          config_params(state.session_id, config_id, value)
        )
    end
  end

  defp apply_next_config(%State{config: %{queue: [{config_id, value} | rest]}} = state) do
    state = put_in(state.config.queue, rest)

    case find_option(state.config.options, config_id) do
      nil ->
        # Options legitimately vary by model, so a request the current one
        # does not offer is kept by the owner and reported, not failed.
        report(state, {:config_skipped, config_id, value})
        apply_next_config(state)

      option ->
        wire = config_wire_value(option, value)

        if Map.get(option, "currentValue") == wire do
          # Already so: the connection kept it, or the resumed session did.
          # Skipping the round trip is most turns' case, and it is a turn's
          # latency, not a background cost.
          report(state, {:config_selected, config_id, value, wire})
          apply_next_config(state)
        else
          send_request(
            %{remember_config_baseline(state, config_id, option) | phase: :setting_config},
            {:set_config, config_id, value},
            "session/set_config_option",
            config_params(state.session_id, config_id, wire)
          )
        end
    end
  end

  # ACP's boolean config options (the `session.configOptions.boolean` client
  # capability) take `type: "boolean"` beside the value; a select takes the
  # value alone. Both pinned adapters fall back to an `on`/`off` select for a
  # client that has not opted in, so a boolean request is translated to that
  # shape, and an `on`/`off` request to the boolean one, rather than refused
  # over a spelling.
  defp config_wire_value(%{"type" => "boolean"}, value) when is_boolean(value), do: value
  defp config_wire_value(%{"type" => "boolean"}, "on"), do: true
  defp config_wire_value(%{"type" => "boolean"}, "off"), do: false
  defp config_wire_value(_option, true), do: "on"
  defp config_wire_value(_option, false), do: "off"
  defp config_wire_value(_option, value), do: value

  # Whether a baseline is still a value the option takes. A select lists its
  # values, flat or in groups; an option that lists none is taken at its word.
  defp offers?(%{"type" => "boolean"}, value), do: is_boolean(value)

  defp offers?(%{"options" => options}, value) when is_list(options),
    do: value in Enum.flat_map(options, &option_values/1)

  defp offers?(_option, _value), do: true

  defp option_values(%{"options" => grouped}) when is_list(grouped),
    do: Enum.flat_map(grouped, &option_values/1)

  defp option_values(%{"value" => value}), do: [value]
  defp option_values(_), do: []

  defp config_params(session_id, config_id, value) when is_boolean(value),
    do: %{sessionId: session_id, configId: config_id, type: "boolean", value: value}

  defp config_params(session_id, config_id, value),
    do: %{sessionId: session_id, configId: config_id, value: value}

  defp remember_config_options(state, %{"configOptions" => options}) when is_list(options),
    do: put_in(state.config.options, Enum.filter(options, &is_map/1))

  defp remember_config_options(state, _result), do: state

  defp find_option(options, config_id) when is_list(options),
    do: Enum.find(options, &(Map.get(&1, "id") == config_id))

  defp find_option(_options, _config_id), do: nil

  defp send_prompt(state) do
    report(
      state,
      {:model_selected, state.model, state.model_selection.effective,
       state.model_selection.source}
    )

    params = %{
      sessionId: state.session_id,
      prompt: [%{type: "text", text: state.prompt} | image_blocks(state.images)]
    }

    id = state.next_id
    state = send_request(%{state | phase: :prompting}, :prompt, "session/prompt", params)

    # Reported after the write so the owner never persists an id for a prompt
    # that did not go out. Reattach reads it back — see the moduledoc.
    if state.phase == :failed, do: state, else: tap(state, &report(&1, {:prompt_sent, id}))
  end

  # ACP carries images in the prompt itself, so the legacy dance — write the
  # bytes to a temp file in the sandbox, then append the paths to the prompt and
  # hope the model reaches for its Read tool — is not needed. `data` here is raw
  # binary (already decoded by the host), and the protocol wants base64.
  #
  # The adapter advertises `promptCapabilities.image`; we send images
  # unconditionally because the alternative is dropping a user's attachment
  # silently, and an agent that cannot read one will say so.
  defp image_blocks(images) do
    Enum.map(images, fn %{media_type: media_type, data: data} ->
      %{type: "image", mimeType: media_type, data: Base.encode64(data)}
    end)
  end

  # ── plumbing ──────────────────────────────────────────────────────────────

  defp send_request(state, tag, method, params) do
    id = state.next_id

    %{state | next_id: id + 1, pending: Map.put(state.pending, id, tag)}
    |> write(Protocol.request(id, method, params))
  end

  defp pop_pending(state, id) do
    {tag, pending} = Map.pop(state.pending, id)
    {tag, %{state | pending: pending}}
  end

  # The writer is total by contract (`Managoat.ACP.Transport`): a transport
  # that has already gone yields `{:error, reason}` rather than exiting this
  # process — #603, and being mid-turn is exactly the condition that made
  # that an orphaned turn rather than an error. A sandbox writer answers
  # `{:error, :command_exited}` there; the peer reports whatever it gets.
  defp write(%State{phase: :failed} = state, _iodata), do: state

  defp write(state, iodata) do
    case state.writer.(iodata) do
      :ok -> state
      {:error, reason} -> fail(state, {:acp_write_failed, reason})
    end
  end

  # Adapters put the useful sentence in different places: claude's is under
  # `data.details` ("Invalid value for config option model: …"), while the
  # top-level `message` is a generic "Internal error". Prefer the specific one.
  defp error_detail(%{"data" => %{"details" => details}}) when is_binary(details), do: details
  defp error_detail(%{"message" => message}) when is_binary(message), do: message
  defp error_detail(other), do: inspect(other)

  defp persist(state, stream, iodata) do
    report(state, {:lines, stream, IO.iodata_to_binary(iodata)})
    state
  end

  defp fail(%State{phase: :failed} = state, _reason), do: state

  defp fail(state, reason) do
    report(state, {:failed, reason})

    failed_session_setup =
      case {state.phase, reason} do
        {:starting_session, {:acp_error, tag, _error}}
        when tag in [:resume_session, :load_session] ->
          tag

        _ ->
          nil
      end

    %{state | phase: :failed, failed_session_setup: failed_session_setup}
  end

  defp report(state, payload), do: send(state.owner, {:acp, state.ref, payload})

  defp schedule_replay_check(state, after_ms \\ nil) do
    Process.send_after(self(), :replay_check, after_ms || state.replay_window.quiet_ms)
    state
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  # ACP requires absolute paths, and codex-acp refuses the whole session over
  # one bad entry. Refusing at start names the fault; a refused `session/new`
  # would not.
  defp validate_directories(directories) when is_list(directories) do
    if Enum.all?(directories, &(is_binary(&1) and Path.type(&1) == :absolute)),
      do: :ok,
      else: {:error, :invalid_additional_directories}
  end

  defp validate_directories(_), do: {:error, :invalid_additional_directories}

  # Only the shape: string ids and string-or-boolean values. Which ids and
  # values exist is the agent's to say, per session and per model, and its
  # refusal is the check. `"model"` belongs to `:model`, whose pin comes first
  # and is verified; accepting it here too would make two answers to one
  # question.
  defp validate_config(config) when is_map(config) do
    valid? =
      Enum.all?(config, fn {id, value} ->
        is_binary(id) and id not in ["", "model"] and (is_binary(value) or is_boolean(value))
      end)

    if valid?, do: :ok, else: {:error, :invalid_config}
  end

  defp validate_config(_), do: {:error, :invalid_config}

  defp supports?(state, path) do
    case get_in(state.capabilities, path) do
      nil -> false
      false -> false
      _ -> true
    end
  end

  # Prefer an option the agent itself marked as an allow. `optionId` is opaque
  # and adapter-defined, so picking by `kind` is the only portable choice.
  # A held request handed back on reattach (#940). Stored as a string-keyed map
  # by the owner; the peer works in atoms. The JSON-RPC id has to come back
  # as the integer the agent sent, because that is what it is blocked on.
  # The adapter's own JSON-RPC id, back out of the minted `request_id` (see
  # `mint_request_id/1`): everything before the last dot. A response has to
  # echo the id's JSON type, so a numeric id is restored as an integer and
  # anything else as the string it was — an adapter that numbers its requests
  # and one that names them are both answerable after a deploy.
  defp restore_pending(%{"request_id" => request_id, "options" => options} = pending)
       when is_binary(request_id) do
    case acp_id(request_id) do
      nil ->
        nil

      id ->
        %{
          id: id,
          request_id: request_id,
          options: List.wrap(options),
          tool: Map.get(pending, "tool")
        }
    end
  end

  defp restore_pending(_), do: nil

  defp acp_id(request_id) do
    case String.split(request_id, ".") do
      [_only] ->
        # A request_id written before #955 minted them: the whole string is the
        # adapter's id. Restoring it keeps a request raised across that deploy
        # answerable instead of orphaning it.
        parse_acp_id(request_id)

      parts ->
        parts |> Enum.drop(-1) |> Enum.join(".") |> parse_acp_id()
    end
  end

  defp parse_acp_id(""), do: nil

  defp parse_acp_id(raw) do
    case Integer.parse(raw) do
      {id, ""} -> id
      _ -> raw
    end
  end

  defp noreply(state), do: {:noreply, state}
end
