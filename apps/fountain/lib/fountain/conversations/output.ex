defmodule Fountain.Conversations.Output do
  @moduledoc """
  What the sandbox says, on its way to the transcript (#1377).

  The durable log budget (#331), its truncation marker, and the stage events
  that mark the same stream live here. `Redaction` is the guard on the
  single writer (`Conversations.log!/1`) and stays where it is; this module
  decides what is written at all, and when, not what a written row may say.
  The when is `RedactionCarry` (#2359): output whose end could be the start of
  a registered value waits for the chunk that follows it, so the writer sees
  the value whole. What is held is flushed by `flush/1`, which the server calls
  before a turn ends.

  `from_state/1` reads the three server fields into an `%Output{}` and
  `into_state/2` writes them back; the server's state does not change shape.
  Every function takes what it reads — the conversation, the turn the output
  belongs to and the owner whose sidebar moves, gathered by `ctx/1` — and
  returns the next value. Nothing here holds a process or a timer.
  """

  require Logger

  alias Fountain.Conversations
  alias Fountain.Conversations.RedactionCarry

  @type t :: %__MODULE__{
          bytes: non_neg_integer() | nil,
          capped: boolean(),
          carry: nil | %{ctx: ctx(), held: RedactionCarry.t()}
        }

  @type ctx :: %{
          conversation_id: String.t(),
          turn_id: String.t() | nil,
          user_id: String.t() | nil
        }

  defstruct bytes: nil, capped: false, carry: nil

  # ── the server boundary ───────────────────────────────────────────────────

  @doc "What the server holds, as one value."
  @spec from_state(map()) :: t()
  def from_state(state) do
    %__MODULE__{
      bytes: state.output_bytes,
      capped: state.output_capped,
      carry: state.output_carry
    }
  end

  @doc "The value written back into the server's fields."
  @spec into_state(map(), t()) :: map()
  def into_state(state, %__MODULE__{} = output) do
    %{
      state
      | output_bytes: output.bytes,
        output_capped: output.capped,
        output_carry: output.carry
    }
  end

  @doc """
  `flush/1` on the server's own fields: what it calls before a turn ends.
  Nothing held, which is nearly always, leaves the state untouched.
  """
  @spec flush_state(map()) :: map()
  def flush_state(state) do
    if Map.get(state, :output_carry),
      do: into_state(state, flush(from_state(state))),
      else: state
  end

  @doc """
  What a row needs beside the bytes: the conversation, the turn the output
  belongs to, and the owner whose sidebar the broadcast moves.
  """
  @spec ctx(map()) :: ctx()
  def ctx(state) do
    %{
      conversation_id: state.conversation_id,
      turn_id: state.current_turn && state.current_turn.id,
      user_id: state.user_id
    }
  end

  # ── the durable budget (#331) ─────────────────────────────────────────────

  @doc """
  Persist + broadcast one chunk of sandbox output, subject to the
  per-conversation byte budget (#331).

  `log_events` is unbounded per row count and lives on the same Postgres
  volume the app depends on, so a `while true; do base64 /dev/urandom; done`
  sandbox was an availability risk, not just a storage bill — retention
  (#217) bounds age, not rate. Once the budget is exceeded, one truncation
  marker is persisted and every later chunk is dropped. Dropped rather than
  broadcast-only: consumers key ordering off the DB-assigned event id, and an
  unbounded broadcast stream would still let a hostile sandbox saturate
  PubSub.

  The chunk passes `RedactionCarry` first, so it may be written now, later,
  or joined to its neighbours. Held output belongs to the turn it arrived in:
  output for another turn flushes it first.
  """
  @spec log(t(), ctx(), String.t(), binary()) :: t()
  def log(%__MODULE__{capped: true} = output, _ctx, _stream, _data), do: output

  def log(%__MODULE__{} = output, ctx, stream, data) do
    output =
      if output.carry && output.carry.ctx.turn_id != ctx.turn_id, do: flush(output), else: output

    held = if output.carry, do: output.carry.held, else: RedactionCarry.new()
    {rows, held} = RedactionCarry.feed(held, ctx.conversation_id, stream, data)
    carry = if RedactionCarry.empty?(held), do: nil, else: %{ctx: ctx, held: held}

    Enum.reduce(rows, %{output | carry: carry}, fn {stream, data}, output ->
      write(output, ctx, stream, data)
    end)
  end

  @doc """
  Write everything `log/4` is holding, under the turn it arrived in. A value
  that never finished arriving is not a value, so what was held is written as
  it is.
  """
  @spec flush(t()) :: t()
  def flush(%__MODULE__{carry: nil} = output), do: output

  def flush(%__MODULE__{carry: %{ctx: ctx, held: held}} = output) do
    held
    |> RedactionCarry.flush(ctx.conversation_id)
    |> Enum.reduce(%{output | carry: nil}, fn {stream, data}, output ->
      write(output, ctx, stream, data)
    end)
  end

  defp write(output, ctx, stream, data) do
    output = ensure_bytes(output, ctx.conversation_id)
    budget = byte_budget()

    cond do
      output.capped ->
        %{output | carry: nil}

      budget > 0 and output.bytes + byte_size(data) > budget ->
        Logger.warning(
          "conv #{ctx.conversation_id}: durable output budget " <>
            "(#{budget} bytes) reached; dropping further sandbox output"
        )

        :telemetry.execute([:fountain, :log_output, :capped], %{count: 1}, %{
          conversation_id: ctx.conversation_id
        })

        persist(ctx, "stderr", cap_marker(budget))
        %{output | capped: true, carry: nil}

      true ->
        persist(ctx, stream, data)
        %{output | bytes: output.bytes + byte_size(data)}
    end
  end

  @doc "The one row that says the budget is spent."
  @spec cap_marker(non_neg_integer()) :: String.t()
  def cap_marker(budget) do
    "\n[fountain] This conversation reached its durable log budget of " <>
      "#{div(budget, 1_000_000)} MB. Further sandbox output is discarded — " <>
      "the turn keeps running, and stage events still appear.\n"
  end

  @doc """
  Load the conversation's byte total on the first output of a server's
  lifetime, so the budget is cumulative across wakes rather than per BEAM
  lifetime.
  """
  @spec ensure_bytes(t(), String.t()) :: t()
  def ensure_bytes(%__MODULE__{bytes: nil} = output, conversation_id) do
    # ownership: a server's own conversation, established at init.
    %{output | bytes: Conversations._unsafe_output_byte_total(conversation_id)}
  end

  def ensure_bytes(%__MODULE__{} = output, _conversation_id), do: output

  @doc "The budget in bytes. 0 disables the cap."
  @spec byte_budget() :: non_neg_integer()
  def byte_budget do
    Application.get_env(:fountain, :log_output_byte_budget, 50_000_000)
  end

  @doc """
  Write one chunk to the transcript and broadcast it, with no budget
  arithmetic: what `log/4` does once it has decided the chunk is affordable.
  """
  @spec persist(ctx(), String.t(), binary()) :: :ok
  def persist(ctx, stream, data) do
    # Tag this output with the stage that's active right now. The
    # runtime CLI is always spawned inside a `turn` so all stdout /
    # stderr from it gets `stage: "turn"`. Any operator on the
    # presentation side (LiveView grouping, SSE consumers) can group
    # output by stage without inferring it from event interleaving.
    event =
      Conversations.log!(%{
        conversation_id: ctx.conversation_id,
        turn_id: ctx.turn_id,
        kind: "output",
        stream: stream,
        stage: "turn",
        data: data
      })

    if event do
      Phoenix.PubSub.broadcast(
        Fountain.PubSub,
        "conv:#{ctx.conversation_id}",
        {:log_event, event}
      )

      if ctx.user_id do
        Phoenix.PubSub.broadcast(
          Fountain.PubSub,
          "sidebar:#{ctx.user_id}",
          {:sidebar_update, ctx.user_id}
        )
      end
    end

    :ok
  end

  # ── stage events ──────────────────────────────────────────────────────────

  @doc """
  The transcript's other half: a lifecycle marker on the same stream the
  chunks go to. Unbudgeted — a stage event is one row per transition, and
  losing them is how a client stops being able to tell a stuck agent from a
  finished one.
  """
  @spec publish_stage(String.t(), String.t(), String.t(), map()) ::
          Conversations.LogEvent.t() | nil
  def publish_stage(conv_id, stage, status, meta \\ %{}) do
    Conversations.publish_stage(conv_id, stage, status, meta)
  end
end
