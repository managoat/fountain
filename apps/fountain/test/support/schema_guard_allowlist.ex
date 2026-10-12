defmodule FountainWeb.SchemaGuardAllowlist do
  @moduledoc """
  What the schema guard is allowed to find today, and why.

  The ratchet this repository already uses for the omissions list in
  `sdk/contract`: write down what is wrong now, forbid anything new, and let
  the list only shrink. Every entry is one `{operation, status}` pair — never a
  pattern — so a second operation with the same defect fails until somebody
  decides about it too. That is the whole point: the families below are
  systemic, and a wildcard would let the next instance in unnoticed.

  Cleaning one up means deleting its line. `FountainWeb.SchemaGuardrailTest`
  fails if the list grows past `@ceiling`, so growing it is a deliberate edit a
  reviewer sees.

  ## The families

  `:test_fixture_vocabulary` — not a defect in the API. The fixture inserts a
  value on purpose that the domain no longer accepts (a conversation whose
  runtime is `retired-runtime`, exercising the retired-runtime path), so the
  rendered enum is out of vocabulary because the test asked for that.
  """

  @reasons %{
    test_fixture_vocabulary: "the fixture inserts an out-of-vocabulary value on purpose"
  }

  # The list may shrink, never grow, without a deliberate edit here and in the
  # guardrail's own ceiling.
  @entries %{
    # ── test_fixture_vocabulary (1) ─────────────────────────────
    {"GET /api/conversations/{id}", 200} => :test_fixture_vocabulary
  }

  @doc "Is this `{operation, status}` a known, recorded disagreement?"
  @spec allowed?(String.t(), integer()) :: boolean()
  def allowed?(operation, status), do: Map.has_key?(@entries, {operation, status})

  @doc "The reason family for one entry, or nil."
  @spec reason(String.t(), integer()) :: String.t() | nil
  def reason(operation, status) do
    case Map.get(@entries, {operation, status}) do
      nil -> nil
      family -> Map.fetch!(@reasons, family)
    end
  end

  @doc "Every entry, for the guardrail's hygiene checks."
  @spec entries() :: %{{String.t(), integer()} => atom()}
  def entries, do: @entries

  @doc "The families and their prose."
  @spec reasons() :: %{atom() => String.t()}
  def reasons, do: @reasons
end
