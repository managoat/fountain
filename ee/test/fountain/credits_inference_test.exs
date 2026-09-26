defmodule Fountain.Credits.InferenceTest do
  @moduledoc """
  Pricing a platform-inference turn (#1388): the rate card, the pricer's
  fourth pass, and what the finance panel makes of it.

  `async: false` — the rate override and the platform keys are application
  environment, and a module that writes it races every module that reads it
  (#1214).
  """

  use Fountain.DataCase, async: false

  alias Fountain.Billing
  alias Fountain.Billing.Finance
  alias Fountain.Credits
  alias Fountain.Credits.InferenceRates
  alias Fountain.Workers.CreditPricer

  @since ~U[2026-08-01 00:00:00Z]
  @now ~U[2026-08-03 12:00:00Z]

  setup do
    original = Application.get_env(:fountain, :inference_rates)

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:fountain, :inference_rates)
        value -> Application.put_env(:fountain, :inference_rates, value)
      end
    end)

    :ok
  end

  defp platform_turn(conv, usage, opts \\ []) do
    started = Keyword.get(opts, :started_at, ~U[2026-08-02 10:00:00Z])

    insert_turn(conv, %{
      status: "completed",
      started_at: started,
      ended_at: DateTime.add(started, Keyword.get(opts, :seconds, 60), :second),
      usage: usage
    })
  end

  # Turns carrying the #1685 turn-start stamp and nothing else, in bulk: the
  # page-boundary test needs more of them than the pricer's page holds.
  defp stamp_only_turns(conv, count) do
    at = ~U[2026-08-02 10:00:00Z]
    stamp = %{"inference" => "platform", "model" => "anthropic/claude-opus-5"}

    rows =
      for n <- 1..count do
        %{
          id: Ecto.UUID.generate(),
          conversation_id: conv.id,
          turn_number: n,
          prompt: "stamped",
          status: "failed",
          started_at: at,
          ended_at: at,
          usage: stamp,
          inserted_at: at
        }
      end

    Repo.insert_all(Fountain.Conversations.Turn, rows)
  end

  defp conv_for(user, provider \\ "sprites") do
    sandbox = insert_sandbox(user_id: user.id, provider: provider, status: "ready")
    insert_conversation(user_id: user.id, sandbox: sandbox)
  end

  describe "InferenceRates" do
    test "a million input tokens on opus 5 is $5 and a million output is $25" do
      assert InferenceRates.cost_cents(%{
               "model" => "anthropic/claude-opus-5",
               "input" => 1_000_000,
               "output" => 0
             }) == 500

      assert InferenceRates.cost_cents(%{
               "model" => "anthropic/claude-opus-5",
               "input" => 0,
               "output" => 1_000_000
             }) == 2_500
    end

    test "cached tokens are priced at their own published rate, not as input" do
      # Opus 5: cache reads are 0.1x base input, 5-minute writes 1.25x.
      assert InferenceRates.cost_cents(%{
               "model" => "anthropic/claude-opus-5",
               "input" => 0,
               "output" => 0,
               "cache_read" => 1_000_000,
               "cache_write" => 1_000_000
             }) == 50 + 625
    end

    test "opus 5.5 is priced at its own rate, cache reads at 0.05x" do
      # $4 / $20, cache read $0.20, 5m cache write $5.00: cheaper than the
      # `anthropic/*` fallback it would otherwise take.
      assert InferenceRates.cost_cents(%{
               "model" => "anthropic/claude-opus-5-5",
               "input" => 1_000_000,
               "output" => 1_000_000,
               "cache_read" => 1_000_000,
               "cache_write" => 1_000_000
             }) == 400 + 2_000 + 20 + 500
    end

    test "fable 5.1 is priced at its own rate, above the fallback" do
      # $10 / $50, cache read $0.25, 5m cache write $12.50. Unlisted, it took
      # the Opus fallback at half its cost.
      assert InferenceRates.cost_cents(%{
               "model" => "anthropic/claude-fable-5-1",
               "input" => 1_000_000,
               "output" => 1_000_000,
               "cache_read" => 1_000_000,
               "cache_write" => 1_000_000
             }) == 1_000 + 5_000 + 25 + 1_250
    end

    test "a fraction of a cent per million tokens survives the unit" do
      # OpenAI's cached input for gpt-5.3-codex is $0.175/MTok.
      assert InferenceRates.cost_cents(%{
               "model" => "openai/gpt-5.3-codex",
               "cache_read" => 4_000_000
             }) == 70
    end

    test "an unlisted model falls back to the provider's flagship rate" do
      assert InferenceRates.rate_for("anthropic/claude-opus-9") ==
               InferenceRates.rate_for("anthropic/claude-opus-5")
    end

    test "a provider Fountain holds no key for prices nothing" do
      assert InferenceRates.cost_cents(%{"model" => "ollama/llama3", "input" => 9_999_999}) == 0
      assert InferenceRates.cost_cents(%{"input" => 9_999_999}) == 0
      assert InferenceRates.cost_cents(nil) == 0
    end

    test "a token count that is not a non-negative integer counts as nothing" do
      assert InferenceRates.cost_cents(%{
               "model" => "anthropic/claude-opus-5",
               "input" => "lots",
               "output" => -5
             }) == 0
    end

    test "a config override replaces one entry and leaves the rest compiled" do
      Application.put_env(:fountain, :inference_rates, %{
        "anthropic/claude-opus-5" => %{
          input: 1_000_000,
          output: 0,
          cache_read: 0,
          cache_write: 0
        }
      })

      assert InferenceRates.cost_cents(%{
               "model" => "anthropic/claude-opus-5",
               "input" => 1_000_000
             }) == 1_000

      assert InferenceRates.cost_cents(%{
               "model" => "anthropic/claude-sonnet-5",
               "input" => 1_000_000
             }) == 200
    end

    test "rounding is to the nearest cent, once" do
      # At $5/MTok a cent is 2,000 tokens, so 400 of them is 0.2 cents.
      assert InferenceRates.cost_cents(%{
               "model" => "anthropic/claude-opus-5",
               "input" => 400
             }) == 0

      # 1,200 is 0.6 cents, and rounds the other way.
      assert InferenceRates.cost_cents(%{
               "model" => "anthropic/claude-opus-5",
               "input" => 1_200
             }) == 1

      # Rounded once from the total, not per token kind: two 0.6-cent halves
      # are 1.2 cents and one row, not two rows of one cent.
      assert InferenceRates.cost_cents(%{
               "model" => "anthropic/claude-opus-5",
               "input" => 1_200,
               "cache_write" => 960
             }) == 1
    end
  end

  describe "the pricer's inference pass" do
    test "a platform turn burns its tokens, once, beside the turn-time burn" do
      user = insert_empty_user()
      conv = conv_for(user)

      turn =
        platform_turn(
          conv,
          %{
            "inference" => "platform",
            "model" => "anthropic/claude-sonnet-5",
            "input" => 1_000_000,
            "output" => 500_000
          },
          seconds: 3_600
        )

      assert %{turns: 1, inference: 1} = CreditPricer.run(since: @since, now: @now)

      # $2 of input plus $5 of output is 700 cents of inference, and the hour
      # of turn time is 25 more. Two rows, two reasons: Fountain's margin is
      # the second one.
      assert Credits.balance(user.id) == -725

      [entry] = Credits.list_entries(user.id) |> Enum.filter(&(&1.reason == "burn_inference"))
      assert entry.resource_type == "turn"
      assert entry.resource_id == turn.id
      assert entry.idempotency_key == "burn_inference:#{turn.id}"
      assert entry.metadata["model"] == "anthropic/claude-sonnet-5"
      assert entry.metadata["input"] == 1_000_000
      assert entry.metadata["conversation_id"] == conv.id

      assert %{inference: 0} = CreditPricer.run(since: @since, now: @now)
      assert Credits.balance(user.id) == -725
    end

    test "a turn on the tenant's own key burns nothing for inference" do
      user = insert_empty_user()
      conv = conv_for(user)

      platform_turn(conv, %{
        "inference" => "own",
        "input" => 1_000_000,
        "output" => 1_000_000
      })

      assert %{inference: 0} = CreditPricer.run(since: @since, now: @now)
      assert Credits.list_entries(user.id) == []
    end

    test "an unmarked turn — the shape every turn had before #1388 — burns nothing" do
      user = insert_empty_user()
      conv = conv_for(user)

      platform_turn(conv, %{"input" => 1_000_000, "output" => 1_000_000})

      assert %{inference: 0} = CreditPricer.run(since: @since, now: @now)
    end

    test "a runner turn costs no sandbox time and still burns its platform tokens" do
      user = insert_empty_user()
      conv = conv_for(user, "runner")

      platform_turn(
        conv,
        %{
          "inference" => "platform",
          "model" => "anthropic/claude-opus-5",
          "input" => 1_000_000
        },
        seconds: 3_600
      )

      # The turn pass skips it (ADR 0022: Fountain pays for no runner hour);
      # the inference pass does not, because the tokens were still on
      # Fountain's key.
      assert %{turns: 0, inference: 1} = CreditPricer.run(since: @since, now: @now)
      assert Credits.balance(user.id) == -500
    end

    test "a turn that rounds to nothing writes no row" do
      user = insert_empty_user()
      conv = conv_for(user)

      platform_turn(conv, %{
        "inference" => "platform",
        "model" => "anthropic/claude-opus-5",
        "input" => 100
      })

      assert %{inference: 0} = CreditPricer.run(since: @since, now: @now)
      assert Credits.list_entries(user.id) == []
    end

    test "a turn carrying only the turn-start stamp burns nothing" do
      user = insert_empty_user()
      conv = conv_for(user)

      # #1685: the stamp says whose key ran the turn, and no token figure was
      # ever reported for it. What a turn with unknown tokens should cost is
      # an open decision, so for now it costs nothing.
      platform_turn(conv, %{"inference" => "platform", "model" => "anthropic/claude-opus-5"})

      assert %{inference: 0} = CreditPricer.run(since: @since, now: @now)
      assert Credits.list_entries(user.id) == []
    end

    test "a full page of stamp-only turns does not starve the priceable turn behind them" do
      user = insert_empty_user()
      conv = conv_for(user)

      # One more than the pricer's page, every one of them older than the
      # turn that can be priced. The pass stops on a page that wrote nothing,
      # so a selector that admitted these would never reach the last turn —
      # and in production they outnumber the answered turns ten to one.
      stamp_only_turns(conv, 501)

      turn =
        platform_turn(
          conv,
          %{
            "inference" => "platform",
            "model" => "anthropic/claude-opus-5",
            "input" => 10_000_000
          },
          started_at: ~U[2026-08-02 18:00:00Z]
        )

      assert %{inference: 1} = CreditPricer.run(since: @since, now: @now)

      assert [entry] =
               user.id |> Credits.list_entries() |> Enum.filter(&(&1.reason == "burn_inference"))

      assert entry.resource_id == turn.id
    end

    test "an open turn is not priced until it closes" do
      user = insert_empty_user()
      conv = conv_for(user)

      insert_turn(conv, %{
        status: "running",
        started_at: ~U[2026-08-02 10:00:00Z],
        usage: %{
          "inference" => "platform",
          "model" => "anthropic/claude-opus-5",
          "input" => 10_000_000
        }
      })

      assert %{inference: 0} = CreditPricer.run(since: @since, now: @now)
    end
  end

  describe "the ceiling and the finance panel" do
    test "spend today is the day's burn_inference rows, across every tenant" do
      one = insert_empty_user()
      two = insert_empty_user()

      {:ok, _} =
        Credits.debit(one.id, 120, "burn_inference",
          idempotency_key: "burn_inference:a",
          actor: "system:test"
        )

      {:ok, _} =
        Credits.debit(two.id, 80, "burn_inference",
          idempotency_key: "burn_inference:b",
          actor: "system:test"
        )

      # A turn-time burn is not inference spend.
      {:ok, _} =
        Credits.debit(one.id, 500, "burn_turn",
          idempotency_key: "burn_turn:x",
          actor: "system:test"
        )

      assert Billing.platform_inference_spend_today() == 200
    end

    test "the finance panel counts inference as both earned and paid, netting to zero" do
      user = insert_empty_user()
      now = DateTime.utc_now()
      {start, _} = Billing.current_month_range()

      {:ok, _} =
        Credits.debit(user.id, 300, "burn_inference",
          idempotency_key: "burn_inference:finance",
          actor: "system:test"
        )

      summary = Finance.summary(period: {start, DateTime.add(now, 1, :day)}, now: now)
      row = Enum.find(summary.tenants, &(&1.user_id == user.id))

      assert row.inference_cost_cents == 300
      assert row.revenue_cents == 300
      assert row.credit_burned_cents == 300
      assert summary.cost.inference_cents == 300
      # Pass-through: the tenant paid exactly what the tokens cost.
      assert row.margin_cents == 0
    end
  end

  describe "every runtime reports something we can bill (#1459)" do
    # The whole chain from a runtime's wire response to a ledger row starts at
    # `Managoat.ACP.Usage`, and a runtime that reports nothing falls out of it
    # silently: no usage map, so `TurnMachine.with_inference/2` has nowhere to
    # stamp `"inference" => "platform"`, so the pricer's fourth pass never
    # sees the turn, so no `burn_inference` row exists — and
    # `PlatformInference`'s daily ceiling is measured from those rows, so the
    # spend is outside the circuit breaker as well as unbilled.
    #
    # That is what gemini did (#1459): it puts its tokens under a vendor
    # `_meta.quota` extension instead of the protocol's `usage`. Nothing here
    # failed, because "unbilled" and "free" look identical from every angle
    # but the provider's invoice. `turns.usage` had been NULL for gemini since
    # the runtime went onto the ACP path; the platform keys (#1388) are only
    # what turned a missing figure into a missing bill.
    #
    # So the shapes are recorded, one per runtime, and asserted to price above
    # zero. This is a claim about the wire, not about the library: it fails if
    # an adapter changes what it sends, if `Managoat.ACP.Usage` stops reading
    # a shape, or if a new runtime is added without checking that it reports
    # anything at all.
    #
    # The counts are from live turns on production's platform keys,
    # 2026-09-03 — except gemini's, which cannot be, because the bug is that
    # nothing was recorded. Its *shape* is gemini-cli's own
    # (`packages/cli/src/acp/acpSession.ts`, identical at 0.53.0, 0.56.0 and
    # 0.59) and its counts are the neighbouring opencode-on-google turn's,
    # which is the closest real figure there is.
    @wire_shapes %{
      # claude-agent-acp, the protocol's own `usage` object.
      "claude" =>
        {"anthropic/claude-sonnet-5",
         %{
           "stopReason" => "end_turn",
           "usage" => %{
             "inputTokens" => 2,
             "outputTokens" => 41,
             "cachedReadTokens" => 24_101,
             "cachedWriteTokens" => 9_122
           }
         }},
      # codex-acp, the same object, no cache write reported.
      "codex" =>
        {"openai/gpt-5.3-codex",
         %{
           "stopReason" => "end_turn",
           "usage" => %{"inputTokens" => 12_975, "outputTokens" => 10, "cachedReadTokens" => 0}
         }},
      # gemini-cli's vendor extension — the shape #1459 was about.
      "gemini" =>
        {"google/gemini-3.1-pro-preview",
         %{
           "stopReason" => "end_turn",
           "_meta" => %{
             "quota" => %{
               "token_count" => %{"input_tokens" => 8_716, "output_tokens" => 21},
               "model_usage" => []
             }
           }
         }},
      # opencode speaks the protocol's object whichever provider it drives.
      "opencode" =>
        {"google/gemini-3.1-pro-preview",
         %{
           "stopReason" => "end_turn",
           "usage" => %{"inputTokens" => 8_716, "outputTokens" => 21}
         }}
    }

    for {runtime, {model, result}} <- @wire_shapes do
      test "#{runtime} reports tokens that price above zero" do
        usage = Managoat.ACP.Usage.from_prompt_result(unquote(Macro.escape(result)))

        refute is_nil(usage),
               """
               #{unquote(runtime)} reported no usage. A platform turn on this \
               runtime would be unbilled and invisible to the daily ceiling. \
               Either the adapter changed what it sends, or Managoat.ACP.Usage \
               no longer reads it — see #1459.\
               """

        stamped = Map.merge(usage, %{"inference" => "platform", "model" => unquote(model)})
        assert InferenceRates.cost_cents(stamped) > 0
      end
    end

    test "the gemini shape reaches the ledger, not just the rate card" do
      user = insert_empty_user()
      conv = conv_for(user)

      {model, result} = @wire_shapes["gemini"]

      usage =
        result
        |> Managoat.ACP.Usage.from_prompt_result()
        |> Map.merge(%{"inference" => "platform", "model" => model})

      # gemini reports no cache split at all: its input count already includes
      # cached tokens. The card prices google's cached tokens at the base
      # input rate, so the total is right either way — but a reader who
      # assumes the four keys are always present should see they are not.
      refute Map.has_key?(usage, "cache_read")

      turn = platform_turn(conv, usage, seconds: 8)

      assert %{inference: 1} = CreditPricer.run(since: @since, now: @now)

      [entry] = Credits.list_entries(user.id) |> Enum.filter(&(&1.reason == "burn_inference"))
      assert entry.idempotency_key == "burn_inference:#{turn.id}"
      assert entry.metadata["model"] == "google/gemini-3.1-pro-preview"

      # 8,716 input at $2/MTok is 1.743 cents and 21 output at $12/MTok is
      # 0.025 more, so the turn rounds to 2 — negative because a debit is.
      # Before #1459 there was no row here to read at all.
      assert entry.amount_cents == -2
      assert Billing.platform_inference_spend_today() == 2
    end
  end
end
