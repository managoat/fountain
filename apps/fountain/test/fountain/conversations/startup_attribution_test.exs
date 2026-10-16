defmodule Fountain.Conversations.StartupAttributionTest do
  @moduledoc """
  The step breakdown of a turn's `runtime_session` phase (#2907), and the
  residual that says how much of the phase it does not explain.
  """
  use ExUnit.Case, async: true

  alias Fountain.Conversations.StartupAttribution, as: Attribution

  describe "accumulating steps" do
    test "a fresh turn's steps each get a millisecond attribute" do
      attrs =
        Attribution.new()
        |> Attribution.put("adapter_check", 264)
        |> Attribution.put("sandbox_spawn", 310)
        |> Attribution.put("initialize", 388)
        |> Attribution.put("session/new", 460)
        |> Attribution.put("model_select", 11)
        |> Attribution.attributes()

      assert attrs == %{
               "acp.startup.adapter_check_ms" => 264,
               "acp.startup.sandbox_spawn_ms" => 310,
               "acp.startup.initialize_ms" => 388,
               "acp.startup.session_new_ms" => 460,
               "acp.startup.model_select_ms" => 11
             }
    end

    test "a step that did not happen mints no attribute" do
      # No `authenticate` round trip happens for claude or codex — they
      # advertise `authMethods: []` — so a zero there would be a measurement
      # that was never taken, not a step that was free.
      attrs = Attribution.new() |> Attribution.put("initialize", 388) |> Attribution.attributes()

      refute Map.has_key?(attrs, "acp.startup.authenticate_ms")
      assert Map.keys(attrs) == ["acp.startup.initialize_ms"]
    end

    test "a repeated step sums and carries a count" do
      # Config options are applied one at a time (`apply_next_config/1`), so
      # three of them is three round trips under one label. The count is what
      # separates "one slow option" from "several quick ones".
      attrs =
        Attribution.new()
        |> Attribution.put("config_option", 12)
        |> Attribution.put("config_option", 9)
        |> Attribution.put("config_option", 14)
        |> Attribution.attributes()

      assert attrs == %{
               "acp.startup.config_option_ms" => 35,
               "acp.startup.config_option_count" => 3
             }
    end

    test "a single occurrence carries no count" do
      attrs =
        Attribution.new() |> Attribution.put("config_option", 12) |> Attribution.attributes()

      refute Map.has_key?(attrs, "acp.startup.config_option_count")
    end

    test "a second session call in one turn accumulates" do
      # `Peer.start_session/1` sends a second `session/new` after a resume the
      # agent refused. The turn paid for both.
      acc =
        Attribution.new()
        |> Attribution.put("session/resume", 120)
        |> Attribution.put("session/new", 460)
        |> Attribution.put("session/new", 455)

      assert Attribution.attributes(acc)["acp.startup.session_new_ms"] == 915
      assert Attribution.attributes(acc)["acp.startup.session_new_count"] == 2
      assert Attribution.attributed_ms(acc) == 1035
    end

    test "an unnamed step is left in the residual rather than minting an attribute" do
      # The vocabulary is closed on purpose (as `InstallTiming`'s is): a new
      # peer report must not silently reshape the breakdown or the residual's
      # meaning.
      acc = Attribution.new() |> Attribution.put("session/prompt", 4_000)

      assert Attribution.attributes(acc) == %{}
      assert Attribution.attributed_ms(acc) == 0
    end

    test "a negative duration is refused" do
      acc = Attribution.new() |> Attribution.put("initialize", -5)

      assert Attribution.attributed_ms(acc) == 0
    end

    test "the step vocabulary is the one the peer and the connection report" do
      assert Attribution.steps() == [
               "adapter_check",
               "sandbox_spawn",
               "initialize",
               "authenticate",
               "session/new",
               "session/resume",
               "session/load",
               "model_select",
               "config_option"
             ]
    end
  end

  describe "closing against the phase" do
    test "the residual is the part of the phase no step explains" do
      # Shaped after the ticket's Claude/Sprites median: a ~2 s phase with
      # ~1.43 s of measured steps in it.
      summary =
        Attribution.new()
        |> Attribution.put("adapter_check", 264)
        |> Attribution.put("sandbox_spawn", 300)
        |> Attribution.put("initialize", 388)
        |> Attribution.put("session/new", 460)
        |> Attribution.put("model_select", 11)
        |> Attribution.summary(2_001)

      assert summary["acp.startup.attributed_ms"] == 1_423
      assert summary["acp.startup.residual_ms"] == 578
      assert summary["acp.startup.initialize_ms"] == 388
    end

    test "a warm turn attributes nothing and is all residual" do
      # A reused idle connection spawns nothing and handshakes not at all: its
      # phase is the prompt write and a mailbox hop. Reporting 0 attributed
      # against a small total is the honest reading, not a missing measurement.
      summary = Attribution.summary(Attribution.new(), 8)

      assert summary["acp.startup.attributed_ms"] == 0
      assert summary["acp.startup.residual_ms"] == 8
    end

    test "a step still in flight when the turn ends falls into the residual" do
      # The peer reports a duration only when a request is answered, so a
      # cancelled or failed `session/new` contributes nothing and its elapsed
      # time shows up as residual rather than as a completed step.
      summary =
        Attribution.new()
        |> Attribution.put("adapter_check", 24)
        |> Attribution.put("sandbox_spawn", 40)
        |> Attribution.put("initialize", 388)
        |> Attribution.summary(1_500)

      assert summary["acp.startup.attributed_ms"] == 452
      assert summary["acp.startup.residual_ms"] == 1_048
      refute Map.has_key?(summary, "acp.startup.session_new_ms")
    end

    test "a negative residual is reported, not clamped" do
      # Double counting or host-clock disagreement is the defect #2908 owns.
      # Clamping at zero would hide exactly the signal that says the
      # attribution is wrong.
      summary =
        Attribution.new() |> Attribution.put("initialize", 500) |> Attribution.summary(400)

      assert summary["acp.startup.residual_ms"] == -100
    end
  end
end
