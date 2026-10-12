defmodule Fountain.SandboxProviders do
  @moduledoc """
  Which sandbox providers this deployment can name, and which it can use.

  `Managoat.Sandbox` (the library, decisions/0037) answers only "which module
  serves this provider atom", through its adapter map. Everything here is
  deployment policy layered on that, and it reads Fountain's configuration,
  which is why it lives in Fountain rather than in the library:

    * `known_providers/0` — the closed vocabulary the schemas validate
      against (`Agents.Agent`, `Conversations.Sandbox`). Knowing a provider
      is not the same as having it configured.
    * `default_provider/0` — `SANDBOX_PROVIDER`, validated at boot in
      `config/runtime.exs`.
    * `enabled?/1` / `enabled_providers/0` — whether a provider is usable on
      this instance: its adapter is registered **and** its credential is
      configured (for `:runner`, which has none, that it has not been
      switched off). Enabledness is runtime state — the schema validates
      against `known_providers/0`, selection validates against this.
  """

  alias Managoat.Sandbox

  @known ~w(sprites e2b runner)

  @doc "The closed vocabulary of providers Fountain knows how to name."
  @spec known_providers() :: [String.t()]
  def known_providers, do: @known

  @doc "The instance-default provider (`SANDBOX_PROVIDER`; validated at boot)."
  @spec default_provider() :: Sandbox.provider()
  def default_provider do
    Application.get_env(:fountain, :sandbox_default_provider, :sprites)
  end

  @doc "Whether a provider is usable on this instance."
  @spec enabled?(Sandbox.provider()) :: boolean()
  def enabled?(provider) when is_atom(provider) do
    Map.has_key?(Sandbox.adapters(), provider) and credential_present?(provider)
  end

  @doc "Every provider currently usable on this instance."
  @spec enabled_providers() :: [Sandbox.provider()]
  def enabled_providers do
    known_providers()
    |> Enum.map(&String.to_existing_atom/1)
    |> Enum.filter(&enabled?/1)
  end

  # The platform credentials live in the library's own config, where
  # config/runtime.exs writes them from SPRITES_TOKEN / E2B_API_KEY.
  # "Is it set" is read back from there rather than kept in
  # a second :fountain key that could drift from what the adapter uses.
  defp credential_present?(:sprites), do: Sandbox.Config.get(Sandbox.Sprites, :token) != nil
  defp credential_present?(:e2b), do: Sandbox.Config.get(Sandbox.E2B, :api_key) != nil
  # Self-hosted runners (ADR 0022) need no platform credential — every daemon
  # authenticates with the user's own API key — so the switch is an operator
  # opt-out rather than a key: `SANDBOX_RUNNERS_ENABLED=false` hides the
  # provider from selection and refuses daemon connections.
  defp credential_present?(:runner), do: Application.get_env(:fountain, :runners_enabled, true)
  # Non-production adapters (the in-memory Fake) carry no credentials; being
  # registered in the adapter map is what enables them.
  defp credential_present?(_other), do: true
end
