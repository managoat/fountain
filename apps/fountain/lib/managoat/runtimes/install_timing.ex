defmodule Managoat.Runtimes.InstallTiming do
  @moduledoc false

  # Only fixed numeric fields cross from installer output into telemetry. Never
  # export stdout, paths, command arguments or environment values. The
  # install's total and outcome are the span's own; these are its phases.
  # node_wait is a child of finalize, not an additive peer phase.
  @phases ~w(lock_wait image_probe bundle_extract finalize node_wait link)

  # A phase cannot be negative, and cannot outlast the sandbox exec's own
  # 180-second deadline. A value outside that range is kept and flagged, never
  # dropped: it is the only evidence that the clock behind it misbehaved, and
  # an install whose timings vanish looks identical to one that was never
  # measured (#2908). Refuse only magnitudes too large to be a measurement at
  # all, so untrusted sandbox output cannot put an unbounded integer on a span.
  @plausible 0..180_000
  @recordable -86_400_000..86_400_000

  # The installer reports each phase against both a wall and a monotonic clock.
  # /proc/uptime resolves 10 ms and a phase reads it twice, so the two may
  # legitimately disagree by two granules plus the gap between the reads within
  # a mark. Past that, the wall clock moved while the phase was being measured.
  @skew_tolerance_ms 50

  def attributes(output) when is_binary(output) do
    output
    |> String.split("\n")
    |> Enum.reduce(%{}, &record/2)
  end

  def attributes(_), do: %{}

  defp record("__MANAGOAT_INSTALL__ " <> record, attrs) do
    # The third field is the phase's monotonic elapsed. An installer from
    # before #2908, or a sandbox without /proc/uptime, omits it; the phase is
    # then recorded with no cross-check rather than discarded.
    case String.split(record) do
      ["cache_hit", value] -> flag("cache_hit", value, attrs)
      [phase, value] when phase in @phases -> phase(phase, value, nil, attrs)
      [phase, value, monotonic] when phase in @phases -> phase(phase, value, monotonic, attrs)
      _ -> attrs
    end
  end

  defp record(_, attrs), do: attrs

  defp flag(flag, value, attrs) do
    case Integer.parse(value) do
      {hit, ""} when hit in 0..1 -> Map.put(attrs, "install_" <> flag, hit)
      _ -> attrs
    end
  end

  defp phase(phase, value, monotonic, attrs) do
    case Integer.parse(value) do
      {ms, ""} when ms in @recordable ->
        attrs
        |> Map.put("install_" <> phase <> "_ms", ms)
        |> suspect(ms not in @plausible)
        |> cross_check(ms, monotonic)

      _ ->
        attrs |> suspect(true) |> checked(false)
    end
  end

  defp cross_check(attrs, _ms, monotonic) when monotonic in [nil, "-"], do: checked(attrs, false)

  defp cross_check(attrs, ms, monotonic) do
    case Integer.parse(monotonic) do
      {elapsed, ""} when elapsed in 0..86_400_000 ->
        skew = abs(ms - elapsed)

        attrs
        |> checked(true)
        |> Map.update("install_clock_skew_max_ms", skew, &max(&1, skew))
        |> suspect(skew > @skew_tolerance_ms)

      _ ->
        attrs |> suspect(true) |> checked(false)
    end
  end

  # Zero is sticky: a later checked phase cannot hide an earlier missing or
  # invalid cross-check. This describes reported phases, not trace completeness.
  defp checked(attrs, checked?) do
    value = if checked?, do: 1, else: 0
    Map.update(attrs, "install_clock_checked", value, &min(&1, value))
  end

  # Recorded for every reported phase. Zero means no anomaly was detected,
  # not that a monotonic cross-check was available; install_clock_checked
  # records that separately.
  defp suspect(attrs, flagged?) do
    value = if flagged?, do: 1, else: 0

    Map.update(attrs, "install_timing_suspect", value, &max(&1, value))
  end
end
