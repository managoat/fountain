defmodule Fountain.SentryConfigTest do
  @moduledoc """
  Boot-time Sentry wiring (#211).

  The contract worth pinning is inertness: with no SENTRY_DSN, the SDK gets a
  nil DSN and sends nothing anywhere — a self-hoster is never conscripted into
  a vendor by default.
  """

  use ExUnit.Case, async: false

  @runtime_exs Path.expand("../../../../config/runtime.exs", __DIR__)

  @base %{
    "PHX_SERVER" => "true",
    "SECRET_KEY_BASE" => String.duplicate("a", 64),
    "DATABASE_URL" => "postgres://u:p@localhost/db",
    "PUBLIC_URL" => "https://fountain.example.com"
  }

  @vars ~w(SENTRY_DSN SENTRY_ENVIRONMENT MANAGOAT_BUILD_SHA)

  setup do
    previous = System.get_env()

    on_exit(fn ->
      System.put_env(previous)

      for k <- @vars ++ ["MASTER_SECRETS_KEY"],
          not Map.has_key?(previous, k),
          do: System.delete_env(k)
    end)

    key = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    {:ok, base: Map.put(@base, "MASTER_SECRETS_KEY", key)}
  end

  defp read_prod(env) do
    for k <- @vars, do: System.delete_env(k)
    System.put_env(env)
    Config.Reader.read!(@runtime_exs, env: :prod)[:sentry]
  end

  test "no SENTRY_DSN means a nil dsn — the SDK is inert", %{base: base} do
    config = read_prod(base)

    assert config[:dsn] == nil
    assert config[:send_default_pii] == false
  end

  test "a DSN, environment and release flow through", %{base: base} do
    config =
      read_prod(
        Map.merge(base, %{
          "SENTRY_DSN" => "https://public@sentry.example.com/1",
          "SENTRY_ENVIRONMENT" => "staging",
          "MANAGOAT_BUILD_SHA" => "abc1234"
        })
      )

    assert config[:dsn] == "https://public@sentry.example.com/1"
    assert config[:environment_name] == "staging"
    assert config[:release] == "abc1234"
  end

  test "environment defaults to the config env, release to nil", %{base: base} do
    config = read_prod(Map.put(base, "SENTRY_DSN", "https://public@sentry.example.com/1"))

    assert config[:environment_name] == "prod"
    assert config[:release] == nil
  end
end
