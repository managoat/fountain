defmodule Fountain.Legal do
  @moduledoc """
  The instance operator's legal identity for `/terms` and `/privacy` (#517).

  The pages' copy reads "an agreement between you and {entity}" — so the
  identity must be the *operator's*, not the upstream project's. It comes from
  the `LEGAL_ENTITY` / `LEGAL_CONTACT_EMAIL` / `LEGAL_JURISDICTION` /
  `LEGAL_EFFECTIVE_DATE` env vars (config/runtime.exs), never from source.

  Unconfigured, the pages are unpublished: links are hidden and the routes
  render a neutral 404. A self-hosted instance must never serve someone
  else's terms.
  """

  @doc """
  The operator-configured legal identity, or `nil` when unset.
  """
  def configured, do: Application.get_env(:fountain, :legal)

  @doc "Whether `/terms` and `/privacy` should be linked and served."
  def published?, do: configured() != nil

  @doc """
  The map the legal templates render: the configured identity, or `nil`
  (pages unpublished).
  """
  def content, do: configured()
end
