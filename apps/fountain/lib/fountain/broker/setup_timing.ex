defmodule Fountain.Broker.SetupTiming do
  @moduledoc """
  Sandbox-side phase clocks echoed by the two scripts inside the
  `broker_ca_install` step: the CA install shell command
  (`Fountain.Conversations.Provisioning.install_broker_ca/2`) and the
  transport relay's `ensure` mode (`Fountain.Broker.TransportRelay`).

  Every duration here is measured **in the sandbox**, so every one is
  exported with a `sandbox_` prefix. The host spans that enclose them are
  `:telemetry.span` monotonic durations on the server; the two share no
  clock (#2908). A host span minus its sandbox total is a *residual*, not a
  provider round trip: it holds the round trip, but also whatever the
  sandbox ran outside the script's own clocks — shell or node start-up, the
  relay's outer `flock`, and the exit and output transfer after the last
  mark. `scripts/load-test/README.md` sets out the boundaries.

  The `ca_*` phases are bash's microsecond wall clock, cross-checked against
  `/proc/uptime`'s monotonic one (the installer's clocks, #2911; never
  `date +%s%3N`, which uutils misreports). Each is reported as
  `<phase> <wall_ms> <monotonic_ms>`, with `-` for a clock the sandbox could
  not read. The `relay_*` phases come from node's `process.hrtime.bigint()`,
  which is monotonic itself, as `<phase> <ms>`. Branch and attempt counters
  are not timings and carry no prefix.

  A measurement is kept, flagged, rather than dropped when it is implausible:
  it is the evidence about the clock behind it, and a corrupted sample that
  vanished would look the same as one never taken (#2908).

    * `sandbox_ca_timing_suspect` / `sandbox_relay_timing_suspect` — 1 when
      any reported phase of that script fell outside 0–180,000 ms, could not
      be read, was reported twice, or (CA) disagreed with its monotonic
      cross-check by more than 50 ms; 0 when no anomaly was detected. Also 1
      for a known counter whose value is malformed or out of range.
    * `sandbox_ca_clock_checked` — 1 only when every reported CA phase
      carried a valid monotonic cross-check; 0 if any did not. Zero is sticky.
    * `sandbox_ca_clock_skew_max_ms` — the largest wall/monotonic
      disagreement across the checked CA phases.

  Select cross-checked CA timings with `sandbox_ca_clock_checked = 1` and
  `sandbox_ca_timing_suspect = 0`. Neither establishes agreement with the
  host clock. All of a script's signals are absent when it timed no phase,
  such as an install that exited on a contended lock.

  Only fixed numeric fields cross from script output into telemetry. Script
  output, paths, hostnames, command arguments and environment values are
  never exported as attributes, and a line naming no known phase or counter
  is ignored without a flag.
  """

  @marker "__MANAGOAT_BROKER__"

  @ca_durations ~w(ca_lock_wait ca_verify ca_trust ca_sudoers ca_total)
  @relay_durations ~w(relay_boot relay_probe relay_spawn relay_ready relay_total)

  # The names #2906's validation criteria use: which branch of the install
  # ran, and whether the relay was already up.
  @flags ~w(ca_rebuild ca_reused relay_warm relay_restart)
  @counts ~w(relay_polls)

  # A phase cannot be negative and cannot outlast the 150 s exec deadline by
  # much; past that it is kept and flagged. Only magnitudes too large to be a
  # measurement at all are refused, so untrusted sandbox output cannot put an
  # unbounded integer on a span. As `Managoat.Runtimes.InstallTiming`.
  @plausible 0..180_000
  @recordable -86_400_000..86_400_000
  @max_count 1_000

  # /proc/uptime resolves 10 ms and a phase reads it twice, so wall and
  # monotonic may legitimately disagree by two granules plus the gap between
  # the reads within one mark. Past that, the wall clock moved.
  @skew_tolerance_ms 50

  @doc "The marker prefix both scripts print, so tests pin one spelling."
  @spec marker() :: String.t()
  def marker, do: @marker

  @doc """
  The numeric attributes a script's output carries.

  A phase that is missing did not complete or was not needed; it is not a
  measured zero. A value that is implausible but bounded is kept and flags
  its script's `sandbox_*_timing_suspect`; one that cannot be read is not
  exported and flags it too.
  """
  @spec attributes(term()) :: map()
  def attributes(output) when is_binary(output) do
    output
    |> String.split("\n")
    |> Enum.reduce(%{}, &record/2)
  end

  def attributes(_), do: %{}

  @doc """
  The same output with its marker lines removed.

  A failed install quotes a slice of its output as the reason. Phase clocks
  are printed as the script goes, so without this the markers would push the
  reason out of that slice — the instrumentation must not cost the diagnosis
  it exists to support.
  """
  @spec strip(term()) :: String.t()
  def strip(output) when is_binary(output) do
    output
    |> String.split("\n")
    |> Enum.reject(&String.starts_with?(&1, @marker <> " "))
    |> Enum.join("\n")
  end

  def strip(output), do: to_string(output)

  defp record(@marker <> " " <> record, attrs) do
    case String.split(record) do
      # A two-field CA phase is a script without the monotonic mark: kept,
      # with no cross-check.
      [phase, wall] when phase in @ca_durations -> ca_phase(attrs, phase, wall, nil)
      [phase, wall, mono] when phase in @ca_durations -> ca_phase(attrs, phase, wall, mono)
      [phase, value] when phase in @relay_durations -> relay_phase(attrs, phase, value)
      [name, value] when name in @flags -> counter(attrs, name, value, 1)
      [name, value] when name in @counts -> counter(attrs, name, value, @max_count)
      [name | _] when name in @ca_durations or name in @relay_durations -> suspect(attrs, name)
      [name | _] when name in @flags or name in @counts -> suspect(attrs, name)
      _ -> attrs
    end
  end

  defp record(_line, attrs), do: attrs

  defp ca_phase(attrs, phase, wall, mono) do
    case Integer.parse(wall) do
      {ms, ""} when ms in @recordable ->
        if Map.has_key?(attrs, key(phase)) do
          suspect(attrs, phase)
        else
          attrs
          |> Map.put(key(phase), ms)
          |> flag(phase, ms not in @plausible)
          |> cross_check(ms, mono)
        end

      # `-` (no wall clock could be read) or garbage: there is no value to
      # keep, but the phase ran and its record says so.
      _ ->
        attrs |> suspect(phase) |> checked(false)
    end
  end

  defp cross_check(attrs, _ms, mono) when mono in [nil, "-"], do: checked(attrs, false)

  defp cross_check(attrs, ms, mono) do
    case Integer.parse(mono) do
      {elapsed, ""} when elapsed in 0..86_400_000 ->
        skew = abs(ms - elapsed)

        attrs
        |> checked(true)
        |> Map.update("sandbox_ca_clock_skew_max_ms", skew, &max(&1, skew))
        |> flag("ca", skew > @skew_tolerance_ms)

      _ ->
        attrs |> suspect("ca") |> checked(false)
    end
  end

  defp relay_phase(attrs, phase, value) do
    case Integer.parse(value) do
      {ms, ""} when ms in @recordable ->
        if Map.has_key?(attrs, key(phase)) do
          suspect(attrs, phase)
        else
          attrs |> Map.put(key(phase), ms) |> flag(phase, ms not in @plausible)
        end

      _ ->
        suspect(attrs, phase)
    end
  end

  # `put_new`: a counter is reported once per run, so a repeated marker is a
  # script bug or interleaved output, and the first value is the one the
  # script meant — flagged, so the repeat is not invisible.
  defp counter(attrs, name, value, max) do
    case Integer.parse(value) do
      {n, ""} when n >= 0 and n <= max ->
        if Map.has_key?(attrs, name), do: suspect(attrs, name), else: Map.put(attrs, name, n)

      _ ->
        suspect(attrs, name)
    end
  end

  defp key(phase), do: "sandbox_" <> phase <> "_ms"

  defp suspect(attrs, name), do: flag(attrs, name, true)

  # Recorded for every reported phase, so 0 means a phase was timed and no
  # anomaly was detected. Sticky: a later clean phase cannot hide an earlier
  # flagged one.
  defp flag(attrs, name, flagged?) do
    value = if flagged?, do: 1, else: 0
    Map.update(attrs, "sandbox_#{family(name)}_timing_suspect", value, &max(&1, value))
  end

  # Zero is sticky: a later checked phase cannot hide an earlier missing or
  # invalid cross-check. Only the CA's wall clock has one.
  defp checked(attrs, checked?) do
    value = if checked?, do: 1, else: 0
    Map.update(attrs, "sandbox_ca_clock_checked", value, &min(&1, value))
  end

  defp family("ca" <> _), do: "ca"
  defp family("relay" <> _), do: "relay"
end
