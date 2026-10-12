defmodule Fountain.FeatureFlags do
  @moduledoc """
  Deployment-wide feature flags, decided by configuration alone.

  `enabled?(flag, user)` answers a yes/no. The sources, in order:

  1. **Overrides** — `config :fountain, :feature_flag_overrides,
     %{"connections" => true}`, which `config/runtime.exs` builds from
     `FEATURE_FLAGS_ON=connections,...`. An override of `false` (tests use
     one) turns a default-on flag off.
  2. **The flag's default** — `@on_by_default` names the flags that gate a
     shipped feature, which read on unless something turns them off. Every
     other flag gates an unfinished one and reads off until a deployment
     lists it in `FEATURE_FLAGS_ON`.

  The answer is the same for every user. The `user` argument stays so call
  sites read as the per-user question they ask, and so a per-user rollout can
  come back without touching them; nothing here reads it today.

  Flags are plain strings. Keep the known ones in `@flags` so a typo is a
  `KeyError`, not a flag that is silently always off.
  """

  @flags %{
    # Provider registration and credential bindings.
    connections: "connections",
    # Linking a new ChatGPT subscription (ADR 0060 stage 4). Off until a
    # deployment lists it in FEATURE_FLAGS_ON.
    chatgpt_subscriptions: "chatgpt_subscriptions"
  }

  # Flags that gate a **shipped** feature: on unless an override says
  # otherwise. A flag that gates a shipped feature and read off by default
  # would make the feature disappear on the upgrade that introduced the flag
  # (#1620, #1693).
  @on_by_default MapSet.new(["connections"])

  @doc "The configuration key for a known flag atom."
  def key!(flag) when is_atom(flag), do: Map.fetch!(@flags, flag)

  @doc """
  Whether `flag` is on. `user` — a `%Fountain.Accounts.User{}`, a user id or
  `nil` — is accepted and not consulted: flags are deployment-wide.
  """
  @spec enabled?(atom | String.t(), term) :: boolean
  def enabled?(flag, user) when is_atom(flag), do: enabled?(key!(flag), user)

  def enabled?(flag, _user) when is_binary(flag) do
    case Map.fetch(overrides(), flag) do
      {:ok, value} -> value == true
      :error -> MapSet.member?(@on_by_default, flag)
    end
  end

  defp overrides, do: Application.get_env(:fountain, :feature_flag_overrides, %{})
end
