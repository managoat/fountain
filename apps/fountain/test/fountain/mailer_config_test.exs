defmodule Fountain.MailerConfigTest do
  @moduledoc """
  Mail delivery configuration.

  SMTP is the one adapter: `SMTP_HOST` set means mail is on, unset means it
  is off. Off is a complete mode (ADR 0011): registration auto-verifies, and
  boot says on stderr that password reset cannot be delivered. Before
  2026-10-15 an unconfigured instance refused to boot, `EMAIL_DELIVERY=none`
  chose off, and `RESEND_API_KEY` selected Resend's HTTP API; neither
  variable is read now.
  """

  # Mutates process env, so it must not run alongside anything else.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  @runtime_exs Path.expand("../../../../config/runtime.exs", __DIR__)

  @base %{
    "PHX_SERVER" => "true",
    "SECRET_KEY_BASE" => String.duplicate("a", 64),
    "DATABASE_URL" => "postgres://u:p@localhost/db",
    "PUBLIC_URL" => "https://fountain.example.com",
    "EMAIL_FROM" => "noreply@fountain.example.com"
  }

  @mail_vars ~w(RESEND_API_KEY SMTP_HOST SMTP_PORT SMTP_USERNAME SMTP_PASSWORD SMTP_TLS EMAIL_DELIVERY EMAIL_FROM)

  setup do
    previous = System.get_env()
    key = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    on_exit(fn ->
      System.put_env(previous)

      for k <- @mail_vars ++ ["MASTER_SECRETS_KEY"],
          not Map.has_key?(previous, k),
          do: System.delete_env(k)
    end)

    {:ok, base: Map.put(@base, "MASTER_SECRETS_KEY", key)}
  end

  defp read_prod_full(env) do
    for k <- @mail_vars, do: System.delete_env(k)
    System.put_env(env)
    Config.Reader.read!(@runtime_exs, env: :prod)[:fountain]
  end

  defp read_prod(env), do: read_prod_full(env)[Fountain.Mailer]

  # Reads the config and returns {fountain_config, stderr}.
  defp read_prod_with_stderr(env) do
    parent = self()

    stderr =
      capture_io(:stderr, fn -> send(parent, {:config, read_prod_full(env)}) end)

    assert_received {:config, config}
    {config, stderr}
  end

  describe "with no SMTP_HOST" do
    test "boots with mail off and registration auto-verifying (ADR 0011)", %{base: base} do
      {config, stderr} = read_prod_with_stderr(base)

      assert config[:email_enabled] == false
      # No prod override, so the base Local adapter from config.exs stands.
      assert config[Fountain.Mailer] == nil or
               config[Fountain.Mailer][:adapter] == Swoosh.Adapters.Local

      # The notice says why mail is off and what that costs.
      assert stderr =~ "Mail is off: SMTP_HOST is not set"
      assert stderr =~ "password-reset"
    end

    test "falls back to a neutral From placeholder", %{base: base} do
      # Nothing is ever sent in this mode; the placeholder must not be a real
      # domain someone owns.
      {config, _} = read_prod_with_stderr(Map.delete(base, "EMAIL_FROM"))

      assert config[:email_from] == "noreply@localhost"
    end
  end

  describe "SMTP" do
    test "is used when a host is present", %{base: base} do
      config =
        base
        |> Map.merge(%{
          "SMTP_HOST" => "smtp.example.com",
          "SMTP_USERNAME" => "postmaster",
          "SMTP_PASSWORD" => "hunter2hunter2"
        })
        |> read_prod_full()

      assert config[:email_enabled] == nil
      mailer = config[Fountain.Mailer]
      assert mailer[:adapter] == Swoosh.Adapters.SMTP
      assert mailer[:relay] == "smtp.example.com"
      assert mailer[:username] == "postmaster"
      assert mailer[:auth] == :always
    end

    test "defaults to port 587 with STARTTLS", %{base: base} do
      config = read_prod(Map.put(base, "SMTP_HOST", "smtp.example.com"))

      assert config[:port] == 587
      assert config[:tls] == :always
    end

    test "port and TLS mode are overridable", %{base: base} do
      config =
        base
        |> Map.merge(%{
          "SMTP_HOST" => "relay.internal",
          "SMTP_PORT" => "25",
          "SMTP_TLS" => "never"
        })
        |> read_prod()

      assert config[:port] == 25
      assert config[:tls] == :never
    end

    test "skips auth when no username is given", %{base: base} do
      # An unauthenticated relay on a trusted network is a legitimate setup and
      # must not be sent an empty username.
      config = read_prod(Map.put(base, "SMTP_HOST", "relay.internal"))

      assert config[:auth] == :never
    end
  end

  describe "retired variables" do
    test "RESEND_API_KEY alone leaves mail off and says it is not read", %{base: base} do
      {config, stderr} = read_prod_with_stderr(Map.put(base, "RESEND_API_KEY", "re_live_abc"))

      assert config[:email_enabled] == false
      assert stderr =~ "RESEND_API_KEY is set but no longer read"
    end

    test "EMAIL_DELIVERY=none is ignored; mail is off because SMTP_HOST is unset", %{base: base} do
      {config, stderr} = read_prod_with_stderr(Map.put(base, "EMAIL_DELIVERY", "none"))

      assert config[:email_enabled] == false
      assert stderr =~ "EMAIL_DELIVERY is set but no longer read"
    end

    test "neither changes an SMTP configuration", %{base: base} do
      {config, _stderr} =
        base
        |> Map.merge(%{
          "RESEND_API_KEY" => "re_x",
          "EMAIL_DELIVERY" => "none",
          "SMTP_HOST" => "smtp.example.com"
        })
        |> read_prod_with_stderr()

      assert config[:email_enabled] == nil
      assert config[Fountain.Mailer][:adapter] == Swoosh.Adapters.SMTP
    end
  end

  describe "compose-style empty strings (#396)" do
    # docker-compose.yml passes optional vars as `${VAR:-}`, which interpolates
    # to an empty *string* — the variable is set, not absent — and "" is truthy
    # in Elixir. These tests therefore SET the variables to "" rather than
    # deleting them.
    test "a blank SMTP_HOST means mail is off", %{base: base} do
      {config, stderr} =
        base
        |> Map.merge(%{"SMTP_HOST" => "", "SMTP_USERNAME" => "", "SMTP_PASSWORD" => ""})
        |> read_prod_with_stderr()

      assert config[:email_enabled] == false
      refute stderr =~ "no longer read"
    end

    test "a blank SMTP_USERNAME skips auth", %{base: base} do
      # `${SMTP_USERNAME:-}` against an unauthenticated relay must not force
      # auth: :always with an empty username.
      config =
        base
        |> Map.merge(%{"SMTP_HOST" => "relay.internal", "SMTP_USERNAME" => ""})
        |> read_prod()

      assert config[:auth] == :never
      assert config[:username] == nil
    end
  end

  describe "EMAIL_FROM" do
    # The old default was the hosted instance's sending domain: a self-hoster
    # who configured a provider but not EMAIL_FROM sent mail as someone
    # else's domain — rejected by any provider checking SPF/DKIM, and wrong
    # even where it wasn't.
    test "prod refuses to boot with SMTP configured and no EMAIL_FROM", %{base: base} do
      env = base |> Map.delete("EMAIL_FROM") |> Map.put("SMTP_HOST", "smtp.example.com")

      error = assert_raise RuntimeError, fn -> read_prod_full(env) end

      assert error.message =~ "EMAIL_FROM"
      assert error.message =~ "SPF/DKIM"
    end

    test "a blank EMAIL_FROM counts as unset with SMTP configured", %{base: base} do
      # `${EMAIL_FROM:-}` under compose delivers "", not absence.
      env = Map.merge(base, %{"EMAIL_FROM" => "", "SMTP_HOST" => "smtp.example.com"})

      assert_raise RuntimeError, ~r/EMAIL_FROM/, fn -> read_prod_full(env) end
    end

    test "is used verbatim when set", %{base: base} do
      config = read_prod_full(Map.put(base, "SMTP_HOST", "smtp.example.com"))

      assert config[:email_from] == "noreply@fountain.example.com"
    end
  end
end
