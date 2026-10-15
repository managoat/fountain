defmodule Fountain.SandboxBoundsConfigTest do
  @moduledoc """
  Boot-time parsing of the sandbox lifetime bounds.

  A typo in one of these would otherwise disable the bound silently, and an
  operator who set a limit should learn it did not take effect from a boot
  failure rather than from a bill.
  """

  use ExUnit.Case, async: false

  @runtime_exs Path.expand("../../../../config/runtime.exs", __DIR__)

  @base %{
    "PHX_SERVER" => "true",
    "SECRET_KEY_BASE" => String.duplicate("a", 64),
    "DATABASE_URL" => "postgres://u:p@localhost/db",
    "BROKER_LISTEN_PORT" => "14322",
    "BROKER_PROXY_URL" => "http://broker.example:14322",
    "PUBLIC_URL" => "https://fountain.example.com"
  }

  @vars ~w(SANDBOX_IDLE_TIMEOUT_MINUTES SANDBOX_MAX_LIFETIME_HOURS)

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
    Config.Reader.read!(@runtime_exs, env: :prod)[:fountain]
  end

  test "defaults are an hour idle and no ceiling (#936)", %{base: base} do
    config = read_prod(base)

    assert config[:sandbox_idle_timeout_minutes] == 60
    assert config[:sandbox_max_lifetime_hours] == 0
  end

  test "values are read from the environment", %{base: base} do
    config =
      base
      |> Map.merge(%{"SANDBOX_IDLE_TIMEOUT_MINUTES" => "15", "SANDBOX_MAX_LIFETIME_HOURS" => "6"})
      |> read_prod()

    assert config[:sandbox_idle_timeout_minutes] == 15
    assert config[:sandbox_max_lifetime_hours] == 6
  end

  test "0 is accepted as the opt-out", %{base: base} do
    config =
      base
      |> Map.merge(%{"SANDBOX_IDLE_TIMEOUT_MINUTES" => "0", "SANDBOX_MAX_LIFETIME_HOURS" => "0"})
      |> read_prod()

    assert config[:sandbox_idle_timeout_minutes] == 0
    assert config[:sandbox_max_lifetime_hours] == 0
  end

  test "a malformed value refuses to boot", %{base: base} do
    error =
      assert_raise RuntimeError, fn ->
        base |> Map.put("SANDBOX_IDLE_TIMEOUT_MINUTES", "60m") |> read_prod()
      end

    assert error.message =~ "SANDBOX_IDLE_TIMEOUT_MINUTES"
    assert error.message =~ "non-negative integer"
    assert error.message =~ "Set it to 0 to disable"
  end

  test "a negative value refuses to boot", %{base: base} do
    assert_raise RuntimeError, ~r/SANDBOX_MAX_LIFETIME_HOURS/, fn ->
      base |> Map.put("SANDBOX_MAX_LIFETIME_HOURS", "-1") |> read_prod()
    end
  end
end
