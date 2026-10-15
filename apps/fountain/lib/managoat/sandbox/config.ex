defmodule Managoat.Sandbox.Config do
  @moduledoc """
  Per-adapter settings, read from the `:fountain` application env.

  Each adapter keeps its settings under its module name:

      config :fountain, Managoat.Sandbox.Sprites,
        token: System.get_env("SPRITES_TOKEN"),
        base_url: "https://api.sprites.dev",
        timeout_ms: 30_000,
        policy_timeout_ms: 90_000

      config :fountain, Managoat.Sandbox.E2B, api_key: ..., template: "base"
      config :fountain, Managoat.Sandbox.Retry, base_ms: 250

  `config/runtime.exs` decides where a value comes from (an environment
  variable); the adapters read nothing but these keys. Until 2026-10-15 they
  lived under the `:managoat_sandbox` app of the hex library this code came
  from (decisions/0037).

  A key set to `nil` counts as unset and yields the default, so runtime.exs may
  write every key unconditionally from its environment.
  """

  @doc "The value of `key` in `scope`'s settings, or `default` when unset or nil."
  @spec get(module(), atom(), term()) :: term()
  def get(scope, key, default \\ nil) when is_atom(scope) and is_atom(key) do
    case :fountain |> Application.get_env(scope, []) |> Keyword.get(key) do
      nil -> default
      value -> value
    end
  end
end
