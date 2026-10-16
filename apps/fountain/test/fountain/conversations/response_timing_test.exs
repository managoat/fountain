defmodule Fountain.Conversations.ResponseTimingTest do
  use ExUnit.Case, async: true
  alias Fountain.Conversations.ResponseTiming

  test "nested bootstrap replaces provider time, gaps remain explicit, and phases sum to total" do
    timing = %{
      started_mono: -1000,
      intervals: [
        %{phase: "bootstrap", start: -950, stop: -200, depth: 0},
        %{phase: "sandbox", start: -900, stop: -250, depth: 1},
        %{phase: "bootstrap", start: -700, stop: -300, depth: 2}
      ]
    }

    segments = ResponseTiming.segments(timing, -100, -50, 100)

    totals =
      Enum.reduce(segments, %{}, fn {phase, a, b}, acc ->
        Map.update(acc, phase, b - a, &(&1 + b - a))
      end)

    assert totals == %{
             "admission_queue" => 150,
             "bootstrap" => 500,
             "sandbox" => 250,
             "runtime_session" => 50,
             "prompt_text" => 150
           }

    assert Enum.sum(Map.values(totals)) == 1100
  end

  test "warm requests clip stale setup and late prompts clip a setup already in progress" do
    timing = %{
      started_mono: 100,
      intervals: [%{phase: "bootstrap", start: 0, stop: 110, depth: 0}]
    }

    assert ResponseTiming.segments(timing, 120, 130, 150) == [
             {"bootstrap", 100, 110},
             {"admission_queue", 110, 120},
             {"runtime_session", 120, 130},
             {"prompt_text", 130, 150}
           ]

    assert ResponseTiming.segments(%{timing | started_mono: 115}, 120, 130, 150) == [
             {"admission_queue", 115, 120},
             {"runtime_session", 120, 130},
             {"prompt_text", 130, 150}
           ]
  end

  test "scoped collectors restore after exceptions and carry completed wake intervals" do
    {meta, intervals} =
      ResponseTiming.collect(fn ->
        ResponseTiming.measure("sandbox", fn -> :ok end)
        assert_raise RuntimeError, fn -> ResponseTiming.collect(fn -> raise "stop" end) end
        ResponseTiming.carry(response_timing: %{started_mono: 0, path: "wake"})
      end)

    assert [%{phase: "sandbox", depth: 0}] = intervals
    assert meta[:response_timing].intervals == intervals

    assert ResponseTiming.carry(response_timing: %{started_mono: 0, path: "warm"})[
             :response_timing
           ].intervals == []
  end

  test "retries retain the first successful prompt write timestamp" do
    assert ResponseTiming.prompt_sent(nil, 10) == nil

    assert %{} |> ResponseTiming.prompt_sent(10) |> ResponseTiming.prompt_sent(20) == %{
             prompt_sent_mono: 10
           }
  end
end
