defmodule Fountain.Conversations.Pending do
  @moduledoc """
  What a turn waits on a human for (#1375): the permission request the peer
  asked (#940), or the form it was asked to fill (an `elicitation/create`,
  #2492).

  Both live in the one slot, the turn's `pending_permission`, with `"kind"`
  saying which (a row without one is a permission request). They share the
  timeout, the turn-end rule and the `request` stage event; they differ in
  what an answer is (an option id, or an action and the form's content) and
  in what the end of an unanswered one records: a permission request
  refused without a human is audited as `conversation.permission_denied`,
  while a form declined without one is not, because no policy refused
  anything.

  A value and the functions that add, answer, deny and expire it.
  The value is the permission timeout; the request itself lives on the turn
  row, which is why a request raised before a deploy is still answerable
  after one. `from_state/1` reads the server field into a `%Pending{}` and
  `into_state/2` writes it back; the server's state does not change shape.

  This module also held the retired tool bridge's parked calls (#1202) —
  hence "a human *or a client*" in its original name. Those left with the
  dialects that fed them (ADR 0057, #2252); the permission half below is
  unchanged by that removal.

  Every function takes what it reads (the conversation id, the turn row,
  the peer) and returns what changed: the reply to hand back, the turn row
  and the next value. Timers are armed in the calling process, which is the
  server; the answers reach the peer (`Managoat.ACP.Peer`) from here, and the
  stage events say what happened on the stream.

  A request lives exactly as long as the turn that raised it. The turn's end
  denies whatever is still held (`resolve_held/2`), and so does the ask
  timeout. Requests that outlived their turn (#1635) were removed in #2676.
  """

  alias Fountain.Conversations
  alias Fountain.Conversations.Lifecycle

  @type t :: %__MODULE__{permission_timer: reference() | nil}

  defstruct permission_timer: nil

  # ── the server boundary ───────────────────────────────────────────────────

  @doc "What the server holds, as one value."
  @spec from_state(map()) :: t()
  def from_state(state), do: %__MODULE__{permission_timer: state.permission_timer}

  @doc "The value written back into the server's fields."
  @spec into_state(map(), t()) :: map()
  def into_state(state, %__MODULE__{} = pending),
    do: %{state | permission_timer: pending.permission_timer}

  @doc """
  The server's whole pending family, over the server's state (#1369).

  Each of these is `from_state/1`, the operation, then `into_state/2` and the
  turn row written back. They lived in the `ConversationServer` as a private
  adapter apiece, which is one round trip of boilerplate per call site in a
  file that only shrinks. Each takes what it needs from state.
  """
  @spec ask(map(), term(), String.t(), list()) :: map()
  def ask(state, request_id, tool, options) do
    over(state, fn pending, turn ->
      ask(pending, state.conversation_id, turn, request_id, tool, options)
    end)
  end

  @doc "`ask/4` for a form (#2492): `message` and `schema` as the agent sent them."
  @spec ask_elicitation(map(), term(), String.t(), map()) :: map()
  def ask_elicitation(state, request_id, message, schema) do
    over(state, fn pending, turn ->
      hold(pending, state.conversation_id, turn, request_id, %{
        "kind" => "elicitation",
        "message" => message,
        "schema" => schema
      })
    end)
  end

  @doc "One request's end, whichever way."
  @spec resolve(map(), term(), String.t(), String.t() | nil) :: map()
  def resolve(state, request_id, outcome, option_id) do
    over(state, fn pending, turn ->
      resolve_permission(
        pending,
        state.conversation_id,
        turn,
        state.acp_peer,
        request_id,
        outcome,
        option_id
      )
    end)
  end

  @doc """
  `resolve/4`, but only while the current turn is still holding the request.

  The permission timer is the one caller that can arrive too late.
  `resolve/4` cancels it, and `Process.cancel_timer/1` does not recall a
  message that is already in the mailbox, so a timer that fired just before an
  answer lands against a request that is already resolved. Resolving it again
  would publish a second `done` stage and record a
  `conversation.permission_denied` row for something that did not happen,
  which ADR 0013 forbids.
  """
  @spec resolve_if_held(map(), term(), String.t(), String.t() | nil) :: map()
  def resolve_if_held(state, request_id, outcome, option_id) do
    if holds?(state.current_turn, request_id) do
      resolve(state, request_id, outcome, option_id)
    else
      state
    end
  end

  @doc "Whatever is held, if anything, as the turn ends."
  @spec resolve_held(map(), String.t()) :: map()
  def resolve_held(state, outcome) do
    over(state, fn pending, turn ->
      resolve_pending_permission(pending, state.conversation_id, turn, state.acp_peer, outcome)
    end)
  end

  @doc "A human's answer, with the reply to hand back to them."
  @spec answer(map(), term(), String.t()) :: {:ok | {:error, term()}, map()}
  def answer(state, request_id, option_id) do
    {reply, turn, pending} =
      answer_permission(
        from_state(state),
        state.conversation_id,
        state.current_turn,
        state.acp_peer,
        request_id,
        option_id
      )

    {reply, %{into_state(state, pending) | current_turn: turn}}
  end

  @doc "A human's answer to a held form, with the reply to hand back to them."
  @spec answer_elicitation(map(), term(), String.t(), map() | nil) ::
          {:ok | {:error, term()}, map()}
  def answer_elicitation(state, request_id, action, content) do
    pending = from_state(state)
    turn = state.current_turn

    {reply, turn, pending} =
      case state.acp_peer do
        nil ->
          {{:error, :no_pending_permission}, turn, pending}

        peer ->
          case Managoat.ACP.Peer.answer_elicitation(peer, request_id, action, content) do
            :ok ->
              {turn, pending} =
                resolve_permission(
                  pending,
                  state.conversation_id,
                  turn,
                  peer,
                  request_id,
                  "answered",
                  nil,
                  %{action: action}
                )

              {:ok, turn, pending}

            {:error, _} = error ->
              {error, turn, pending}
          end
      end

    {reply, %{into_state(state, pending) | current_turn: turn}}
  end

  defp over(state, fun) do
    {turn, pending} = fun.(from_state(state), state.current_turn)
    %{into_state(state, pending) | current_turn: turn}
  end

  # ── permission requests (#940) ────────────────────────────────────────────

  @doc """
  Re-arm a persisted request using its original ask time after transport
  recovery.
  """
  def restore_permission_timer(%__MODULE__{} = pending, turn) do
    if pending.permission_timer, do: Process.cancel_timer(pending.permission_timer)

    timer =
      case turn do
        %{pending_permission: %{"request_id" => id} = request} ->
          remaining =
            case DateTime.from_iso8601(request["asked_at"] || "") do
              {:ok, asked_at, _} ->
                elapsed = max(DateTime.diff(DateTime.utc_now(), asked_at, :millisecond), 0)
                max(Lifecycle.ask_timeout_ms() - elapsed, 0)

              _ ->
                0
            end

          Process.send_after(self(), {:permission_timeout, id}, remaining)

        _ ->
          nil
      end

    %{pending | permission_timer: timer}
  end

  @doc """
  `ask`: the agent is blocked and a human has to answer (#940).

  Three things happen, and the order matters. The pending request is persisted
  on the turn first, so a deploy landing a millisecond later can still be
  answered; then the stage event goes out; then the timeout is armed.

  The timeout is not optional and it is not a tidiness measure.
  `Lifecycle.check/4` suppresses only the *idle* verdict while a turn is in
  flight, so an unanswered request would sail past the idle bound and be
  resolved by the max-lifetime ceiling — and per 0017 the idle bound suspends
  while the ceiling destroys. Left alone, a prompt nobody answers does not
  hang forever; it burns the whole lifetime and then takes the agent's memory
  with it (#649). When it fires, the request is denied with the rejection the
  agent itself offered, exactly as an `auto_deny` verdict would be, and
  audited as `conversation.permission_denied` with the verdict `timeout`.

  Returns the turn row with the request on it (unchanged when there is no
  turn) and the value with the timer armed.
  """
  @spec ask(t(), String.t(), Conversations.Turn.t() | nil, term(), String.t(), list()) ::
          {Conversations.Turn.t() | nil, t()}
  def ask(%__MODULE__{} = pending, conversation_id, turn, request_id, tool, options) do
    hold(pending, conversation_id, turn, request_id, %{
      "kind" => "permission",
      "tool" => tool,
      # The agent's own list, verbatim. A client must never offer an option
      # that is not on it.
      "options" => options
    })
  end

  # Row, then stage, then timer — see `ask/6`. `fields` is what the kind
  # adds to the row; the stage event carries the same, less nothing a client
  # needs to render a card it has not seen the block for.
  defp hold(pending, conversation_id, turn, request_id, fields) do
    request =
      Map.merge(fields, %{
        "request_id" => request_id,
        "asked_at" => DateTime.utc_now() |> DateTime.to_iso8601()
      })

    turn =
      case turn do
        nil ->
          nil

        turn ->
          {:ok, turn} = Conversations._unsafe_update_turn(turn, %{pending_permission: request})
          turn
      end

    publish_stage(
      conversation_id,
      "request",
      "started",
      fields
      |> Map.delete("asked_at")
      |> Map.merge(%{"request_id" => request_id, "timeout_ms" => Lifecycle.ask_timeout_ms()})
    )

    timer =
      Process.send_after(
        self(),
        {:permission_timeout, request_id},
        Lifecycle.ask_timeout_ms()
      )

    {turn, %{pending | permission_timer: timer}}
  end

  @doc """
  A human answered. First answer wins: the web apps and an editor (#708) are
  peer clients of this door, not fallbacks for one another, so a second
  answer to the same request is "too late" rather than an error in the
  caller. The peer takes the option; the request is then resolved as
  `answered`.
  """
  @spec answer_permission(
          t(),
          String.t(),
          Conversations.Turn.t() | nil,
          pid() | nil,
          term(),
          String.t()
        ) ::
          {:ok | {:error, term()}, Conversations.Turn.t() | nil, t()}
  def answer_permission(
        %__MODULE__{} = pending,
        conversation_id,
        turn,
        peer,
        request_id,
        option_id
      ) do
    case peer do
      nil ->
        {{:error, :no_pending_permission}, turn, pending}

      peer ->
        case Managoat.ACP.Peer.answer_permission(peer, request_id, option_id) do
          :ok ->
            {turn, pending} =
              resolve_permission(
                pending,
                conversation_id,
                turn,
                peer,
                request_id,
                "answered",
                option_id
              )

            {:ok, turn, pending}

          {:error, reason} ->
            {{:error, reason}, turn, pending}
        end
    end
  end

  # `state: "done"` for every outcome, including a deny and a timeout. The stage
  # and its status are the Prometheus counter's only tags and there is an alert
  # on them — a timeout emitting `failed` would page someone for a policy doing
  # exactly what it was told.
  @spec resolve_permission(
          t(),
          String.t(),
          Conversations.Turn.t() | nil,
          pid() | nil,
          term(),
          String.t(),
          String.t() | nil
        ) :: {Conversations.Turn.t() | nil, t()}
  @spec resolve_permission(
          t(),
          String.t(),
          Conversations.Turn.t() | nil,
          pid() | nil,
          term(),
          String.t(),
          String.t() | nil,
          map()
        ) :: {Conversations.Turn.t() | nil, t()}
  def resolve_permission(
        %__MODULE__{} = pending,
        conversation_id,
        turn,
        peer,
        request_id,
        outcome,
        option_id,
        extra_meta \\ %{}
      ) do
    if pending.permission_timer, do: Process.cancel_timer(pending.permission_timer)

    # Read before the clear below wipes it.
    tool = pending_tool(turn)
    kind = pending_kind(turn)

    if outcome != "answered" and peer do
      Managoat.ACP.Peer.deny_permission(peer, request_id)
    end

    turn =
      case turn do
        nil ->
          nil

        turn ->
          {:ok, turn} = Conversations._unsafe_update_turn(turn, %{pending_permission: nil})
          turn
      end

    publish_stage(
      conversation_id,
      "request",
      "done",
      Map.merge(
        %{request_id: request_id, kind: kind, outcome: outcome, option_id: option_id},
        extra_meta
      )
    )

    # A form declined without a human is not a refusal by policy: the agent
    # reads it as "skipped", and there is nothing to audit.
    if outcome != "answered" and kind == "permission" do
      Conversations.record_permission_denied(conversation_id, tool, outcome)
    end

    {turn, %{pending | permission_timer: nil}}
  end

  @doc """
  Whether this turn is holding `request_id` open inside itself.
  """
  @spec holds?(Conversations.Turn.t() | nil, term()) :: boolean()
  def holds?(%{pending_permission: %{"request_id" => id}}, request_id), do: id == request_id
  def holds?(_turn, _request_id), do: false

  @doc ~s(What the turn holds: `"permission"`, `"elicitation"`, or nil.)
  @spec pending_kind(Conversations.Turn.t() | nil) :: String.t() | nil
  def pending_kind(%{pending_permission: %{"kind" => kind}}) when is_binary(kind), do: kind
  def pending_kind(%{pending_permission: %{"request_id" => _}}), do: "permission"
  def pending_kind(_turn), do: nil

  @doc "The tool the turn is blocked on, or nil."
  @spec pending_tool(Conversations.Turn.t() | nil) :: String.t() | nil
  def pending_tool(%{pending_permission: %{"tool" => tool}}), do: tool
  def pending_tool(_turn), do: nil

  # Resolve whatever is held, if anything. The turn row is the source of truth
  # rather than the timer, so this is also correct for a request raised by a
  # previous BEAM lifetime and reattached to.
  @spec resolve_pending_permission(
          t(),
          String.t(),
          Conversations.Turn.t() | nil,
          pid() | nil,
          String.t()
        ) ::
          {Conversations.Turn.t() | nil, t()}
  def resolve_pending_permission(%__MODULE__{} = pending, conversation_id, turn, peer, outcome) do
    case turn do
      %{pending_permission: %{"request_id" => request_id}} ->
        resolve_permission(pending, conversation_id, turn, peer, request_id, outcome, nil)

      _ ->
        {turn, pending}
    end
  end

  defp publish_stage(conv_id, stage, status, meta) do
    Conversations.publish_stage(conv_id, stage, status, meta)
  end
end
