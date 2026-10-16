defmodule Fountain.Broker.SetupTiming do
  @moduledoc """
  Sandbox-side phase clocks echoed by the two scripts inside the
  `broker_ca_install` step: the CA install shell command
  (`Fountain.Conversations.Provisioning.install_broker_ca/2`) and the
  transport relay's `ensure` mode (`Fountain.Broker.TransportRelay`).

  Every duration here is measured **in the sandbox**, so every one is
  exported with a `sandbox_` prefix. The host spans that enclose them are
  `:telemetry.span` monotonic durations on the server; the two share no
  clock (#2908). What the pairing establishes is the difference: a host span
  minus its sandbox total is the provider round trip, measured rather than
  inferred, which is the question #2906 was opened to answer.

  The `ca_*` clocks come from bash (`date +%s%3N`, a wall clock, so an NTP
  step during a provision can distort one); the `relay_*` clocks come from
  node (`process.hrtime.bigint()`, monotonic). Branch and attempt counters
  are not timings and carry no prefix.

  Only fixed numeric fields cross from script output into telemetry. Script
  output, paths, hostnames, command arguments and environment values are
  never exported as attributes.
  """

  @marker "__MANAGOAT_BROKER__"

  @durations ~w(ca_lock_wait ca_verify ca_trust ca_sudoers ca_total
                relay_probe relay_spawn relay_ready relay_total)

  # The names #2906's validation criteria use: which branch of the install
  # ran, and whether the relay was already up.
  @counters ~w(ca_rebuild ca_reused relay_warm relay_restart relay_polls)

  @max_ms 180_000
  @max_count 1_000

  @doc "The marker prefix both scripts print, so tests pin one spelling."
  @spec marker() :: String.t()
  def marker, do: @marker

  @doc """
  The numeric attributes a script's output carries.

  A phase that is missing did not complete or was not needed; it is not a
  measured zero. A value outside its bound, or a marker this module does not
  name, is dropped rather than exported.
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
      [phase, value] -> put(attrs, phase, Integer.parse(value))
      _ -> attrs
    end
  end

  defp record(_line, attrs), do: attrs

  # `put_new`: a phase is reported once per run, so a repeated marker is a
  # script bug or interleaved output, and the first value is the one the
  # script meant.
  defp put(attrs, phase, {value, ""}) when value >= 0 do
    cond do
      phase in @durations and value <= @max_ms ->
        Map.put_new(attrs, "sandbox_" <> phase <> "_ms", value)

      phase in @counters and value <= @max_count ->
        Map.put_new(attrs, phase, value)

      true ->
        attrs
    end
  end

  defp put(attrs, _phase, _parsed), do: attrs
end
