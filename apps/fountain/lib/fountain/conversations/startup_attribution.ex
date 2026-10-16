defmodule Fountain.Conversations.StartupAttribution do
  @moduledoc """
  What a turn's `runtime_session` phase was spent on, step by step (#2907).

  `Fountain.Conversations.ResponseTiming` measures the phase as one wall-clock
  interval, `[turn_start, prompt_sent]`. That is the number a user waits
  through, and on a fresh Claude/Sprites turn it was a ~2 s block with nothing
  inside it. This module holds the inside: the adapter pin check, the sandbox
  spawn, and each ACP request the peer makes before it writes `session/prompt`.

  ## Why a sum is legitimate here, and where it is not

  The pre-prompt path is **strictly sequential**: the peer holds one
  outstanding request at a time (`initialize` → `authenticate` →
  `session/new | session/resume | session/load` → the model pin → each config
  option, one at a time, `apply_next_config/1`), and the adapter cannot be
  spawned before its pin is checked. So these steps do not overlap and adding
  them is meaningful — unlike the bootstrap phase, whose parallel steps
  `ResponseTiming` deliberately collapses into one interval.

  Two numbers on the same span must *not* be added to these:

  * `acp.handshake_ms` is peer start → `initialize` response. It **contains**
    `acp.startup.initialize_ms` and part of the residual. Its meaning is
    unchanged by this module and it is not an attributed step.
  * `response_phase_prompt_text_ms` is the answer to `session/prompt`. The
    prompt's own request is deliberately not attributed: it lands after the
    phase this module explains ends.

  ## The residual is a reported number, not a rounding error

  `acp.startup.residual_ms` is `runtime_session_ms - acp.startup.attributed_ms`.
  It is stamped rather than hidden because it is the thing worth watching: it
  covers host-side work no step brackets — the peer process starting, transport
  and writer setup, `CodexTransport.spawn_opts/3`, JSON encode/decode, actor
  mailbox hops, and the `session/prompt` write itself — plus the tail of any
  request that never got an answer.

  A **negative** residual is a defect signal, so it is reported signed rather
  than clamped at zero: it means a step was double-counted, or that the host
  clocks disagree with the enclosing span (the consistency check #2908 owns).

  A step that is still in flight when the turn fails or is cancelled
  contributes nothing — the peer reports a duration only when a request is
  answered — so its elapsed time falls into the residual. That keeps a failed
  turn's attribution honest instead of crediting a step that never finished.

  The vocabulary is closed, like `Managoat.Runtimes.InstallTiming`'s: a step
  this module does not name mints no attribute and is left in the residual,
  so a new peer report cannot silently reshape the breakdown.
  """

  # Ordered as a turn pays them, which is the order the attributes read in.
  @labels [
    {"adapter_check", "adapter_check"},
    {"sandbox_spawn", "sandbox_spawn"},
    {"initialize", "initialize"},
    {"authenticate", "authenticate"},
    {"session/new", "session_new"},
    {"session/resume", "session_resume"},
    {"session/load", "session_load"},
    {"model_select", "model_select"},
    {"config_option", "config_option"}
  ]

  @label_map Map.new(@labels)
  @order Enum.map(@labels, &elem(&1, 1))

  @prefix "acp.startup."

  @typedoc "Attributed step totals, keyed by this module's own label."
  @type t :: %{optional(String.t()) => %{ms: non_neg_integer(), count: pos_integer()}}

  @doc "The steps this module attributes, as the peer reports them."
  @spec steps() :: [String.t()]
  def steps, do: Enum.map(@labels, &elem(&1, 0))

  @doc "An empty accumulator."
  @spec new() :: t()
  def new, do: %{}

  @doc """
  Add one measured step.

  Repeats accumulate and carry a count: several config options are applied one
  at a time under the same label, and a session restarted after a failed
  resume (`Managoat.ACP.Peer.start_session/1`) sends a second `session/new`
  inside the same turn. A step this module does not name, or a negative
  duration, is ignored rather than guessed at.
  """
  @spec put(t(), String.t(), integer()) :: t()
  def put(acc, step, ms) when is_map(acc) and is_integer(ms) and ms >= 0 do
    case Map.fetch(@label_map, step) do
      {:ok, label} ->
        Map.update(acc, label, %{ms: ms, count: 1}, &%{ms: &1.ms + ms, count: &1.count + 1})

      :error ->
        acc
    end
  end

  def put(acc, _step, _ms) when is_map(acc), do: acc

  @doc """
  Span attributes for what has been attributed so far.

  Safe to stamp repeatedly: OTel attributes are last-write-wins, so a step
  arriving mid-turn republishes the running totals. A `_count` is emitted only
  where a step ran more than once, so the common turn stays one key per step.
  """
  @spec attributes(t()) :: %{optional(String.t()) => integer()}
  def attributes(acc) when is_map(acc) do
    Enum.reduce(@order, %{}, fn label, attrs ->
      case Map.fetch(acc, label) do
        {:ok, %{ms: ms, count: count}} ->
          attrs = Map.put(attrs, @prefix <> label <> "_ms", ms)
          if count > 1, do: Map.put(attrs, @prefix <> label <> "_count", count), else: attrs

        :error ->
          attrs
      end
    end)
  end

  @doc "What every attributed step adds up to."
  @spec attributed_ms(t()) :: non_neg_integer()
  def attributed_ms(acc) when is_map(acc),
    do: Enum.reduce(acc, 0, fn {_label, %{ms: ms}}, total -> total + ms end)

  @doc """
  The breakdown closed against the phase it explains.

  `phase_ms` is this same turn's `response_phase_runtime_session_ms`, so the
  share is readable off one span rather than joined across two. Returns the
  per-step attributes plus the attributed total and the signed residual.
  """
  @spec summary(t(), integer()) :: %{optional(String.t()) => integer()}
  def summary(acc, phase_ms) when is_map(acc) and is_integer(phase_ms) do
    attributed = attributed_ms(acc)

    acc
    |> attributes()
    |> Map.put(@prefix <> "attributed_ms", attributed)
    |> Map.put(@prefix <> "residual_ms", phase_ms - attributed)
  end
end
