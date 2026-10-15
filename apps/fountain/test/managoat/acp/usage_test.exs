defmodule Managoat.ACP.UsageTest do
  use ExUnit.Case, async: true

  alias Managoat.ACP.Usage

  test "the `usage` object, with the cache fields when present" do
    assert Usage.from_prompt_result(%{
             "stopReason" => "end_turn",
             "usage" => %{
               "inputTokens" => 10,
               "outputTokens" => 4,
               "cachedReadTokens" => 8,
               "cachedWriteTokens" => nil,
               "totalTokens" => 22
             }
           }) == %{"input" => 10, "output" => 4, "cache_read" => 8}
  end

  test "falls back to _meta.inputTokens / outputTokens" do
    assert Usage.from_prompt_result(%{"_meta" => %{"inputTokens" => 3, "outputTokens" => "7"}}) ==
             %{"input" => 3, "output" => 7}
  end

  test "nil when nothing is reported, or nothing usable" do
    assert Usage.from_prompt_result(%{"stopReason" => "end_turn"}) == nil
    assert Usage.from_prompt_result(%{"_meta" => %{"other" => 1}}) == nil
    assert Usage.from_prompt_result(%{"usage" => %{"inputTokens" => -1}}) == nil
    assert Usage.from_prompt_result(%{"usage" => %{"inputTokens" => true}}) == nil
    assert Usage.from_prompt_result(nil) == nil
  end

  test "one side missing counts as zero for that side" do
    assert Usage.from_prompt_result(%{"usage" => %{"outputTokens" => 5.0}}) ==
             %{"input" => 0, "output" => 5}
  end

  describe "accounting metadata" do
    @accounting %{
      "version" => 1,
      "source" => "codex/thread-token-usage-delta",
      "scope" => "root_thread_prompt",
      "completeness" => "reported"
    }

    test "preserves the adapter's accounting claim with its observed counts" do
      assert Usage.from_prompt_result(%{
               "usage" => %{"inputTokens" => 10, "outputTokens" => 4, "cachedReadTokens" => 8},
               "_meta" => %{"usageAccounting" => @accounting}
             }) == %{"input" => 10, "output" => 4, "cache_read" => 8, "accounting" => @accounting}
    end

    test "retains partial metadata without inventing absent token counts" do
      partial = %{@accounting | "completeness" => "partial"}

      assert Usage.from_prompt_result(%{
               "usage" => nil,
               "stopReason" => "cancelled",
               "_meta" => %{"usageAccounting" => partial}
             }) == %{"accounting" => partial}
    end

    test "keeps known partial counts and excludes unrelated metadata" do
      partial = %{@accounting | "completeness" => "partial"}

      assert Usage.from_prompt_result(%{
               "usage" => %{"inputTokens" => 10, "outputTokens" => 4},
               "_meta" => %{
                 "secret" => "never copy this",
                 "usageAccounting" => Map.put(partial, "debug", "never copy this either")
               }
             }) == %{"input" => 10, "output" => 4, "accounting" => partial}
    end

    test "invalid or unsupported claims do not qualify otherwise valid counts" do
      invalid = [
        nil,
        [],
        %{},
        %{@accounting | "version" => 0},
        %{@accounting | "version" => true},
        %{@accounting | "version" => 1.0},
        %{@accounting | "source" => ""},
        %{@accounting | "source" => String.duplicate("x", 257)},
        %{@accounting | "scope" => []},
        %{@accounting | "completeness" => "complete"}
      ]

      for claim <- invalid do
        assert Usage.from_prompt_result(%{
                 "usage" => %{"inputTokens" => 1, "outputTokens" => 2},
                 "_meta" => %{"usageAccounting" => claim}
               }) == %{"input" => 1, "output" => 2}
      end
    end

    test "an unfamiliar version is preserved, not certified as a known contract" do
      claim = %{@accounting | "version" => 2, "source" => "future-adapter", "scope" => "session"}

      assert Usage.from_prompt_result(%{"_meta" => %{"usageAccounting" => claim}}) ==
               %{"accounting" => claim}
    end
  end

  describe "gemini's _meta.quota (quirk :gemini_usage_in_meta_quota)" do
    # Verbatim from gemini-cli's `packages/cli/src/acp/acpSession.ts`, which
    # returns this on every `session/prompt` outcome but `cancelled`.
    defp gemini_result(quota) do
      %{"stopReason" => "end_turn", "_meta" => %{"quota" => quota}}
    end

    test "reads the turn's totals" do
      assert Usage.from_prompt_result(
               gemini_result(%{
                 "token_count" => %{"input_tokens" => 1234, "output_tokens" => 567},
                 "model_usage" => [
                   %{
                     "model" => "gemini-3.1-pro-preview",
                     "token_count" => %{"input_tokens" => 1234, "output_tokens" => 567}
                   }
                 ]
               })
             ) == %{"input" => 1234, "output" => 567}
    end

    test "a turn that answered from a slash command reports zero, not nothing" do
      assert Usage.from_prompt_result(
               gemini_result(%{
                 "token_count" => %{"input_tokens" => 0, "output_tokens" => 0},
                 "model_usage" => []
               })
             ) == %{"input" => 0, "output" => 0}
    end

    test "no cache split: gemini reports none, so none is recorded" do
      usage =
        Usage.from_prompt_result(
          gemini_result(%{"token_count" => %{"input_tokens" => 9, "output_tokens" => 1}})
        )

      refute Map.has_key?(usage, "cache_read")
      refute Map.has_key?(usage, "cache_write")
    end

    test "the protocol's own field still wins over the vendor extension" do
      assert Usage.from_prompt_result(%{
               "usage" => %{"inputTokens" => 1, "outputTokens" => 2},
               "_meta" => %{"quota" => %{"token_count" => %{"input_tokens" => 999}}}
             }) == %{"input" => 1, "output" => 2}
    end

    test "an unusable quota falls through to the flat _meta shape" do
      assert Usage.from_prompt_result(%{
               "_meta" => %{
                 "quota" => %{"token_count" => %{"input_tokens" => "not a number"}},
                 "inputTokens" => 4,
                 "outputTokens" => 5
               }
             }) == %{"input" => 4, "output" => 5}
    end

    test "nil when the quota is absent or carries no counts" do
      assert Usage.from_meta_quota(%{"quota" => %{"model_usage" => []}}) == nil
      assert Usage.from_meta_quota(%{"quota" => %{"token_count" => %{}}}) == nil
      assert Usage.from_meta_quota(%{"inputTokens" => 1}) == nil
      assert Usage.from_prompt_result(gemini_result(%{"token_count" => %{}})) == nil
    end
  end

  describe "codex-acp 2.2.2's prompt results (#1731)" do
    # Verbatim `session/prompt` results from codex-acp 2.2.2 (bundled Codex
    # 0.160.1), run on 2026-10-15 against a mock Responses endpoint whose
    # requests each reported 500 cached input tokens and whose request k
    # reported 1000 + 100k input and 10 + k output tokens.
    defp codex_result(stop_reason, counts) do
      token_count =
        counts &&
          %{
            "totalTokens" => counts.total,
            "inputTokens" => counts.input,
            "cachedInputTokens" => counts.cached,
            "cacheWriteInputTokens" => 0,
            "outputTokens" => counts.output,
            "reasoningOutputTokens" => 0
          }

      %{
        "stopReason" => stop_reason,
        "usage" =>
          counts &&
            %{
              "totalTokens" => counts.total,
              "inputTokens" => counts.input,
              "cachedReadTokens" => counts.cached,
              "cachedWriteTokens" => 0,
              "outputTokens" => counts.output,
              "thoughtTokens" => 0
            },
        "_meta" => %{
          "quota" => %{
            "token_count" => token_count,
            "model_usage" =>
              if(token_count,
                do: [%{"model" => "gpt-6.1-sol", "token_count" => token_count}],
                else: []
              )
          }
        }
      }
    end

    test "a prompt of three model requests records all three, not the last" do
      # Requests 1-3: input 1100 + 1200 + 1300 (1500 of it cached), output
      # 11 + 12 + 13. codex-acp 1.10.0 answered the same prompt with request
      # 3 alone.
      result = codex_result("end_turn", %{total: 3636, input: 2100, cached: 1500, output: 36})

      assert Usage.from_prompt_result(result) ==
               %{"input" => 2100, "output" => 36, "cache_read" => 1500, "cache_write" => 0}
    end

    test "cached input is counted once: fresh input and cache reads add up to the prompt" do
      %{"input" => fresh, "cache_read" => cached} =
        Usage.from_prompt_result(
          codex_result("end_turn", %{total: 3636, input: 2100, cached: 1500, output: 36})
        )

      assert fresh + cached == 1100 + 1200 + 1300
    end

    test "a resumed thread reports this prompt's requests, not the thread's history" do
      # A fresh adapter process, `session/resume` on a thread with three
      # earlier requests, then three more: input 1400 + 1500 + 1600, output
      # 14 + 15 + 16. The figure is the three new requests alone; the thread
      # total the resume restored is not in it.
      result = codex_result("end_turn", %{total: 4545, input: 3000, cached: 1500, output: 45})

      assert Usage.from_prompt_result(result) ==
               %{"input" => 3000, "output" => 45, "cache_read" => 1500, "cache_write" => 0}
    end

    test "a cancelled prompt records the requests that completed before the cancel" do
      result = codex_result("cancelled", %{total: 1111, input: 600, cached: 500, output: 11})

      assert Usage.from_prompt_result(result) ==
               %{"input" => 600, "output" => 11, "cache_read" => 500, "cache_write" => 0}
    end

    test "a prompt whose model call failed records the requests that completed" do
      # Request 1 completed; the next one's stream dropped five times and the
      # thread went to systemError. The prompt is still answered `end_turn`.
      result = codex_result("end_turn", %{total: 1313, input: 800, cached: 500, output: 13})

      assert Usage.from_prompt_result(result) ==
               %{"input" => 800, "output" => 13, "cache_read" => 500, "cache_write" => 0}
    end

    test "a prompt cancelled before any request completed is unknown, not zero" do
      assert Usage.from_prompt_result(codex_result("cancelled", nil)) == nil
    end

    test "codex-acp 2.2.2 makes no accounting claim, so none is recorded" do
      usage =
        Usage.from_prompt_result(
          codex_result("end_turn", %{total: 3636, input: 2100, cached: 1500, output: 36})
        )

      refute Map.has_key?(usage, "accounting")
    end
  end
end
