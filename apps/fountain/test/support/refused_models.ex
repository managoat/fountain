defmodule Fountain.RefusedModels do
  @moduledoc """
  The model ids the pinned ACP adapters refuse at `session/set_model`, with the
  date each was observed.

  A refusal happens before a prompt is written, so since #1640 it fails the
  turn outright — naming one of these is an outage, not a stale hint. Every
  entry was served happily by its provider at the time it was refused, which is
  exactly why the provider check alone did not catch it: see the two-gates note
  in `Fountain.Agents.ModelCatalog`.

  ## This is a registry, not a catalog test detail

  It lived inside `Fountain.Agents.ModelCatalogTest` until #1669, where its only
  assertion read `ModelCatalog.suggestions/1` and nothing else. That is how
  `claude-sonnet-4-6` stayed the new-agent form's prefilled default and
  `gpt-5.3-codex` its codex placeholder through the 2026-09-06 clean-up that
  removed both from the catalog: the guard covered the weakest surface.

  A suggestion has to be chosen. A **default** is what a user gets by doing
  nothing, and a **placeholder** is what they get by typing the hint. Both are
  stronger claims than a suggestion, so every surface that names a model reads
  this one map. Adding a surface means adding a test that consumes it here, not
  a second copy of the list.

  Surfaces guarded today: the catalog suggestions, the new-agent form's default
  and per-runtime placeholders, and `Fountain.Agents.Starter` — the model of the
  one agent every verified account owns (ADR 0038 decision 4), and so the
  highest-stakes of the three.

  Shipped skill manifests and `/help` pages are scanned together by
  `Fountain.InstructionModelsTest`. `FountainWeb.ApiSpecTest` scans the published
  OpenAPI document, including descriptions that feed generated SDK types.

  ## Membership in the catalog is the stronger check

  Absence from this map is not sufficient on its own. A model id leaves the
  catalog two ways, and only one of them lands here: an adapter **refusal**,
  and a provider **retirement**. `gpt-5-codex` was retired on 2026-08-22 while
  it was both the codex suggestion and the codex placeholder, which
  `ModelCatalog` records as the worse of the two defects — and a retired id
  never becomes a refusal, so it would never appear in this map.

  Where a surface can assert it, prefer `ModelCatalog.known?/1`: it catches
  both paths. This map is what names the refused ones for a message a reader
  can act on, and what stops a refused id being *re-added* to the catalog it
  was removed from.

  ## Removing an entry

  Legitimate **after** an adapter pin moves and the id is confirmed accepted on
  a real turn. Not legitimate because the model answers a `curl` to the
  provider — that is gate one, and the adapter is the gate that decides a turn.

  The refusal-rate check that finds new entries (`log_events`, `stage='model'`
  and `state='failed'`, against turns for the same model) cannot *clear* an id
  that is never suggested: it accrues no turns, so its rate is zero of zero
  forever. Clear those by driving one real turn.
  """

  # The four anthropic entries were re-checked on the claude-agent-acp 0.81.2
  # pin on 2026-09-25 and are still refused. `claude-opus-5` is refused by
  # that pin too unless the adapter is spawned with its `opus` alias pointed
  # at it, which Fountain does (`TurnMachine.model_env/3`), so it is served
  # rather than listed here.
  @refused %{
    # claude-agent-acp 0.66.0 — "Invalid value for config option model".
    # 289 refusals for claude-sonnet-4-6 alone, 2026-08-16..2026-09-06.
    "anthropic/claude-sonnet-4-6" => "2026-09-06",
    # Observed refused on a real turn at 11:45:46 UTC on 2026-09-06, "Invalid
    # value for config option model" (#1669); never suggested, reached a turn
    # only because one agent is pinned to it by hand. Still refused by
    # claude-agent-acp 0.75.1 with the model cache warm (2026-09-07): the
    # org's additional-models list carries Fable 5.1 only, so this id has no
    # row to resolve onto. A live published Anthropic id, so this row bars a
    # current model rather than a retired one — deliberate while the adapter
    # refuses it.
    #
    # `claude-fable-5-1` sat beside it from 2026-09-06 to 2026-09-07. Its
    # refusal was the cold model cache (see `ModelCatalog`), not the version;
    # cleared by the "drive one real turn" clause above on the 0.75.1 pin.
    "anthropic/claude-fable-5" => "2026-09-06",
    "anthropic/claude-opus-4-7" => "2026-08-27",
    "anthropic/claude-opus-4-8" => "2026-08-23",
    # codex-acp 1.10.0 — "Invalid params". Refused after the #1640 bump that
    # added gpt-6-astra; it was accepted by 1.9.x.
    "openai/gpt-5.3-codex" => "2026-09-06",
    # Google retired it for new keys; opencode's adapter refused it too.
    "google/gemini-2.5-pro" => "2026-08-20"
  }

  @doc "The refused ids, mapped to the date each was observed refused."
  @spec all() :: %{String.t() => String.t()}
  def all, do: @refused

  @doc "Just the ids."
  @spec ids() :: [String.t()]
  def ids, do: Map.keys(@refused)
end
