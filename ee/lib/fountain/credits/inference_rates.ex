defmodule Fountain.Credits.InferenceRates do
  @moduledoc """
  What a turn that ran on a **platform inference key** costs, priced from the
  tokens the runtime reported (#1388, amending ADR 0008).

  ## Pass-through, on purpose

  Every rate below is the provider's list price, unchanged: a **1.0x margin,
  no markup**. Fountain's margin is sandbox time (`CREDIT_TURN_HOUR_CENTS`,
  ADR 0031), not inference. The platform key exists so a verified account can
  see a first reply without opening an account with a model provider first
  (ADR 0038), and a markup would make the opening credit buy less of the one
  thing it was granted for. **This is a decision, not an oversight** — do not
  "fix" it into a margin without a decision record that says so.

  ## The unit

  Rates are integers in **cents per billion tokens** — a published price in
  cents per million tokens, times a thousand. A published price can be
  fractions of a cent per million tokens (OpenAI's cached input for
  `gpt-5.3-codex` is $0.175/MTok), and a float in a money table is how a
  ledger stops reconciling. The turn's cost is rounded to whole cents exactly
  once, at the end, in `cost_cents/1`.

  ## Four token kinds

  `Managoat.ACP.Usage` normalises a turn's end-of-turn figure into `"input"`,
  `"output"` and, when the runtime reports them, `"cache_read"` and
  `"cache_write"`. Cached tokens are billed separately by every provider here
  and they are the *majority* of an agentic turn's input, so pricing only
  `input` and `output` would under-report a claude turn by roughly an order of
  magnitude. Where a provider publishes no cached-token price, cached tokens
  are priced at that provider's base input rate, which over-states rather than
  invents.

  ## Staying current

  Every number carries its source and the date it was read. A rate the
  provider has moved is a stale number, not a bug that announces itself, so
  the comment is the mechanism: read the date, re-read the page. Any entry can
  be overridden per deployment with `PLATFORM_INFERENCE_RATES` (see
  `config/runtime.exs` and `docs/configuration.md`), so a price change does
  not need a deploy of this file.
  """

  alias Managoat.Runtimes.Model

  # ---------------------------------------------------------------------------
  # The card
  # ---------------------------------------------------------------------------
  #
  # Cents per billion tokens. Multiply a published $/MTok figure by 100_000.
  #
  # `"<provider>/*"` is the provider's fallback for a model id not listed
  # here — Fountain's model field is not an allowlist (`Agents.ModelCatalog`),
  # so a model released after this deploy has to be priceable the day it ships.
  # Each fallback is the provider's **flagship** rate, deliberately: an
  # unlisted model priced too low is Fountain paying a bill it never charged
  # for, and the platform key is a courtesy with a ceiling on it, so the
  # failure to prefer is over-charging a grant.
  #
  # Anthropic: platform.claude.com/docs/en/about-claude/pricing, read
  # 2026-09-02, and again 2026-09-25 for Opus 5.5 and Fable 5.1. Cache reads
  # are 0.1x base input except where noted, and 5-minute cache writes 1.25x,
  # which is the multiplier claude's adapter actually uses.
  @anthropic_opus %{input: 500_000, output: 2_500_000, cache_read: 50_000, cache_write: 625_000}

  @card %{
    # ── anthropic ──────────────────────────────────────────────────────────
    # $10.00 / $50.00, cache read $0.25 (0.025x), 5m cache write $12.50.
    # Above the `anthropic/*` fallback, so it has to be listed: unlisted, a
    # Fable turn was priced at the Opus rate, half its cost.
    "anthropic/claude-fable-5-1" => %{
      input: 1_000_000,
      output: 5_000_000,
      cache_read: 25_000,
      cache_write: 1_250_000
    },
    # $4.00 / $20.00, cache read $0.20 (0.05x), 5m cache write $5.00.
    "anthropic/claude-opus-5-5" => %{
      input: 400_000,
      output: 2_000_000,
      cache_read: 20_000,
      cache_write: 500_000
    },
    # $5.00 / $25.00, cache read $0.50, 5m cache write $6.25.
    "anthropic/claude-opus-5" => @anthropic_opus,
    "anthropic/claude-opus-4-8" => @anthropic_opus,
    "anthropic/claude-opus-4-7" => @anthropic_opus,
    "anthropic/*" => @anthropic_opus,
    # $2.00 / $10.00, cache read $0.20, 5m cache write $2.50. The $2/$10
    # introductory price became the standard price on 2026-09-01; the
    # scheduled rise to $3/$15 was cancelled.
    "anthropic/claude-sonnet-5" => %{
      input: 200_000,
      output: 1_000_000,
      cache_read: 20_000,
      cache_write: 250_000
    },
    # $3.00 / $15.00, cache read $0.30, 5m cache write $3.75.
    "anthropic/claude-sonnet-4-6" => %{
      input: 300_000,
      output: 1_500_000,
      cache_read: 30_000,
      cache_write: 375_000
    },
    # $1.00 / $5.00, cache read $0.10, 5m cache write $1.25.
    "anthropic/claude-haiku-4-5" => %{
      input: 100_000,
      output: 500_000,
      cache_read: 10_000,
      cache_write: 125_000
    },

    # ── openai ─────────────────────────────────────────────────────────────
    # developers.openai.com/api/docs/pricing, read 2026-09-02. OpenAI bills a
    # cache *write* as an ordinary input token, so `cache_write` is the base
    # input rate rather than a multiple of it.
    #
    # $5.00 / $30.00, cached input $0.50. The <=272K context tier; a longer
    # request costs more and is priced here at the short-context rate.
    "openai/gpt-5.5" => %{
      input: 500_000,
      output: 3_000_000,
      cache_read: 50_000,
      cache_write: 500_000
    },
    "openai/*" => %{
      input: 500_000,
      output: 3_000_000,
      cache_read: 50_000,
      cache_write: 500_000
    },
    # $1.75 / $14.00, cached input $0.175 — the fraction of a cent per million
    # tokens this module's unit exists for.
    "openai/gpt-5.3-codex" => %{
      input: 175_000,
      output: 1_400_000,
      cache_read: 17_500,
      cache_write: 175_000
    },
    # $1.25 / $10.00, cached input $0.125.
    "openai/gpt-5" => %{
      input: 125_000,
      output: 1_000_000,
      cache_read: 12_500,
      cache_write: 125_000
    },

    # ── google ─────────────────────────────────────────────────────────────
    # ai.google.dev/gemini-api/docs/pricing, read 2026-09-02. Google's cached
    # pricing depends on a cache the ACP adapter does not manage, so cached
    # tokens take the base input rate here.
    #
    # $2.00 / $12.00 for prompts <=200K ($4.00 / $18.00 above that; a turn
    # over 200K is priced low here, which is the direction that costs
    # Fountain and is bounded by the daily ceiling).
    "google/gemini-3.1-pro-preview" => %{
      input: 200_000,
      output: 1_200_000,
      cache_read: 200_000,
      cache_write: 200_000
    },
    "google/*" => %{
      input: 200_000,
      output: 1_200_000,
      cache_read: 200_000,
      cache_write: 200_000
    },
    # $0.75 / $3.75 through 2026-12-31, then $1.50 / $7.50 — the one entry
    # here with a known expiry date on it.
    "google/gemini-3.7-flash" => %{
      input: 75_000,
      output: 375_000,
      cache_read: 75_000,
      cache_write: 75_000
    },
    "google/gemini-3.6-flash" => %{
      input: 75_000,
      output: 375_000,
      cache_read: 75_000,
      cache_write: 75_000
    },
    # $1.50 / $9.00.
    "google/gemini-3.5-flash" => %{
      input: 150_000,
      output: 900_000,
      cache_read: 150_000,
      cache_write: 150_000
    }
  }

  @zero %{input: 0, output: 0, cache_read: 0, cache_write: 0}

  @doc """
  The compiled card, before any deployment override. Every value is cents per
  billion tokens.
  """
  @spec card() :: %{String.t() => map()}
  def card, do: @card

  @doc """
  The rate card in force: `card/0` with `PLATFORM_INFERENCE_RATES` merged over
  it, entry by entry.
  """
  @spec rates() :: %{String.t() => map()}
  def rates do
    case Application.get_env(:fountain, :inference_rates) do
      overrides when is_map(overrides) -> Map.merge(@card, overrides)
      _ -> @card
    end
  end

  @doc """
  The rate for a canonical `provider/model_id`: the model's own entry, else
  the provider's fallback, else zero.

  Zero is the right answer for a provider Fountain holds no platform key for
  (a local model, a gateway): no platform turn can run on it, so there is
  nothing to price, and inventing a number would put a debit on a tenant's
  own credential.
  """
  @spec rate_for(String.t() | nil) :: %{
          input: non_neg_integer(),
          output: non_neg_integer(),
          cache_read: non_neg_integer(),
          cache_write: non_neg_integer()
        }
  def rate_for(model) do
    table = rates()

    case Model.split(model) do
      {nil, nil} ->
        @zero

      {provider, id} ->
        Map.get(table, "#{provider}/#{id}") || Map.get(table, "#{provider}/*") || @zero
    end
  end

  @doc """
  What a turn's `usage` map costs, in whole cents.

  `usage` is the map on `turns.usage` — `Managoat.ACP.Usage`'s normalised
  figure plus the `"model"` and `"inference"` keys the ConversationServer
  stamps on a platform turn. A turn with no usage, no model, or no tokens
  costs nothing.

  Rounded to the nearest cent, once. A turn that rounds to zero writes no
  ledger row at all, exactly as a sub-cent turn hour does.
  """
  @spec cost_cents(map() | nil) :: non_neg_integer()
  def cost_cents(usage) when is_map(usage) do
    rate = rate_for(Map.get(usage, "model"))

    per_billion =
      tokens(usage, "input") * rate.input +
        tokens(usage, "output") * rate.output +
        tokens(usage, "cache_read") * rate.cache_read +
        tokens(usage, "cache_write") * rate.cache_write

    div(per_billion + 500_000_000, 1_000_000_000)
  end

  def cost_cents(_usage), do: 0

  # The same tolerance `Conversations._unsafe_record_turn_usage/2` applies to
  # the counters: whatever the runtime reported that is not a non-negative
  # integer counts as nothing, which is what an unreported figure counts as.
  defp tokens(usage, key) do
    case Map.get(usage, key) do
      n when is_integer(n) and n >= 0 -> n
      _ -> 0
    end
  end
end
