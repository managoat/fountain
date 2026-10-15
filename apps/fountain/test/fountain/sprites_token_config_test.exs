defmodule Fountain.SpritesTokenConfigTest do
  @moduledoc """
  Evaluates `config/runtime.exs` the way the release config provider does,
  pinning #396: a blank SPRITES_TOKEN must be stored as nil, not "".

  docker-compose.yml passes `${SPRITES_TOKEN:-}` and .env.compose.example
  ships the key blank, so the compose quick-start delivers a present-but-empty
  variable. Stored verbatim, `""` is truthy and defeats the
  `token || raise` guard in `Managoat.Sandbox.Sprites.Client.get!/0` (the
  adapter reads its settings from the sandbox library's otp_app, which this
  file populates) — the operator's first conversation then
  fails with an opaque 401 from sprites.dev instead of the message written
  for exactly that case.
  """

  # Mutates process env, so it must not run alongside anything else.
  use ExUnit.Case, async: false

  @runtime_exs Path.expand("../../../../config/runtime.exs", __DIR__)

  @base %{
    "PHX_SERVER" => "true",
    "SECRET_KEY_BASE" => String.duplicate("a", 64),
    "DATABASE_URL" => "postgres://u:p@localhost/db",
    "RESEND_API_KEY" => "re_test_key",
    "EMAIL_FROM" => "noreply@fountain.example.com",
    "PUBLIC_URL" => "https://fountain.example.com"
  }

  setup do
    previous = System.get_env()
    key = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    on_exit(fn ->
      System.put_env(previous)

      for k <- ["SPRITES_TOKEN", "MASTER_SECRETS_KEY"],
          not Map.has_key?(previous, k),
          do: System.delete_env(k)
    end)

    {:ok, base: Map.put(@base, "MASTER_SECRETS_KEY", key)}
  end

  defp read_prod(env) do
    System.delete_env("SPRITES_TOKEN")
    System.put_env(env)

    Config.Reader.read!(@runtime_exs, env: :prod)[:managoat_sandbox][Managoat.Sandbox.Sprites][
      :token
    ]
  end

  test "a blank SPRITES_TOKEN is stored as nil, so the Sprites client guard fires", %{base: base} do
    # SET to "" rather than deleted — the compose `${SPRITES_TOKEN:-}` case.
    assert read_prod(Map.put(base, "SPRITES_TOKEN", "")) == nil
  end

  test "an unset SPRITES_TOKEN is stored as nil", %{base: base} do
    assert read_prod(base) == nil
  end

  test "a real token is stored verbatim", %{base: base} do
    assert read_prod(Map.put(base, "SPRITES_TOKEN", "sk-sprites-abc")) == "sk-sprites-abc"
  end
end
