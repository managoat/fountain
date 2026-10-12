defmodule Fountain.ComposePassthroughConfigTest do
  @moduledoc """
  Evaluates `config/runtime.exs` the way the release config provider does,
  pinning the blank-string behaviour of the variables the compose
  `environment:` block passes through as `${VAR:-}` (#497, and the #513
  fresh-machine walkthrough, which caught the sandbox bounds crash-looping
  boot and SPRITES_BASE_URL going blank).

  Compose interpolates an unset `${VAR:-}` to an empty *string* — the
  variable arrives set, not absent — so every default here must survive `""`.
  These tests SET the variables to `""` rather than deleting them; deleting
  is how the #396 predecessors of these bugs went unnoticed.
  """

  # Mutates process env, so it must not run alongside anything else.
  use ExUnit.Case, async: false

  @runtime_exs Path.expand("../../../../config/runtime.exs", __DIR__)

  @vars ~w(TRUSTED_PROXIES SENTRY_DSN DATABASE_SSL_VERIFY DATABASE_SSL_CA_FILE
           SANDBOX_IDLE_TIMEOUT_MINUTES SANDBOX_MAX_LIFETIME_HOURS SPRITES_BASE_URL
           SANDBOX_PROVIDER E2B_API_KEY E2B_BASE_URL)

  # Not under test here, but they change what the prod boot requires (a
  # configured mail provider demands EMAIL_FROM). Cleared before every read
  # so a leak from an earlier env-mutating module can't fail these cases.
  @mail_vars ~w(RESEND_API_KEY SMTP_HOST EMAIL_FROM)

  @base %{
    "PHX_SERVER" => "true",
    "SECRET_KEY_BASE" => String.duplicate("a", 64),
    "DATABASE_URL" => "postgres://u:p@localhost/db",
    "EMAIL_DELIVERY" => "none",
    "PUBLIC_URL" => "https://fountain.example.com"
  }

  setup do
    previous = System.get_env()
    key = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    on_exit(fn ->
      System.put_env(previous)

      for k <- @vars ++ @mail_vars ++ ["MASTER_SECRETS_KEY"],
          not Map.has_key?(previous, k),
          do: System.delete_env(k)
    end)

    {:ok, base: Map.put(@base, "MASTER_SECRETS_KEY", key)}
  end

  defp read_prod(env) do
    for k <- @vars ++ @mail_vars, do: System.delete_env(k)
    System.put_env(env)
    Config.Reader.read!(@runtime_exs, env: :prod)
  end

  describe "TRUSTED_PROXIES" do
    test "blank leaves the built-in default in place", %{base: base} do
      # An empty list here would override the endpoint's default CIDRs — a
      # blank value must mean "not configured", not "trust nothing".
      cfg = read_prod(Map.put(base, "TRUSTED_PROXIES", ""))

      refute Keyword.has_key?(cfg[:fountain], :trusted_proxies)
    end

    test "a real list is split and trimmed", %{base: base} do
      cfg = read_prod(Map.put(base, "TRUSTED_PROXIES", "10.0.0.0/8, 172.16.0.0/12"))

      assert cfg[:fountain][:trusted_proxies] == ["10.0.0.0/8", "172.16.0.0/12"]
    end
  end

  describe "SENTRY_DSN" do
    test "blank stays nil rather than handing the SDK an empty DSN", %{base: base} do
      cfg = read_prod(Map.put(base, "SENTRY_DSN", ""))

      assert cfg[:sentry][:dsn] == nil

      # The config value alone is not the contract: the SDK re-reads the env
      # var itself (Sentry.Config.put_config/2 validates a partial keyword
      # and fill_in_from_env put_news the raw value in), so a blank variable
      # must be deleted, not merely mapped to a nil config (#513).
      assert System.get_env("SENTRY_DSN") == nil
    end

    test "a real DSN is stored verbatim", %{base: base} do
      cfg = read_prod(Map.put(base, "SENTRY_DSN", "https://k@o0.ingest.sentry.io/1"))

      assert cfg[:sentry][:dsn] == "https://k@o0.ingest.sentry.io/1"
    end
  end

  describe "DATABASE_SSL_VERIFY / DATABASE_SSL_CA_FILE" do
    test "verify with a blank CA file falls back to the OS trust store", %{base: base} do
      # verify_peer with `cacertfile: ''` would reject every certificate.
      cfg =
        base
        |> Map.merge(%{"DATABASE_SSL_VERIFY" => "true", "DATABASE_SSL_CA_FILE" => ""})
        |> read_prod()

      opts = cfg[:fountain][Fountain.Repo][:ssl_opts]
      assert opts[:verify] == :verify_peer
      assert is_list(opts[:cacerts])
      refute Keyword.has_key?(opts, :cacertfile)
    end

    test "verify with an explicit CA file uses it", %{base: base} do
      cfg =
        base
        |> Map.merge(%{
          "DATABASE_SSL_VERIFY" => "true",
          "DATABASE_SSL_CA_FILE" => "/etc/ssl/certs/rds.pem"
        })
        |> read_prod()

      opts = cfg[:fountain][Fountain.Repo][:ssl_opts]
      assert opts[:verify] == :verify_peer
      assert opts[:cacertfile] == ~c"/etc/ssl/certs/rds.pem"
    end

    test "a blank DATABASE_SSL_VERIFY keeps the historical verify_none", %{base: base} do
      cfg =
        base
        |> Map.merge(%{"DATABASE_SSL_VERIFY" => "", "DATABASE_SSL_CA_FILE" => ""})
        |> read_prod()

      assert cfg[:fountain][Fountain.Repo][:ssl_opts] == [verify: :verify_none]
    end
  end

  describe "sandbox lifetime bounds" do
    test "blank falls back to the defaults instead of refusing to boot", %{base: base} do
      # This was the first thing `docker compose up` hit on a fresh machine
      # (#513): both bounds arrive as "", Integer.parse("") fails, and the
      # raise meant for typos crash-looped the quick start.
      cfg =
        base
        |> Map.merge(%{"SANDBOX_IDLE_TIMEOUT_MINUTES" => "", "SANDBOX_MAX_LIFETIME_HOURS" => ""})
        |> read_prod()

      assert cfg[:fountain][:sandbox_idle_timeout_minutes] == 60
      assert cfg[:fountain][:sandbox_max_lifetime_hours] == 0
    end

    test "a real value is parsed", %{base: base} do
      cfg =
        base
        |> Map.merge(%{
          "SANDBOX_IDLE_TIMEOUT_MINUTES" => "0",
          "SANDBOX_MAX_LIFETIME_HOURS" => "72"
        })
        |> read_prod()

      assert cfg[:fountain][:sandbox_idle_timeout_minutes] == 0
      assert cfg[:fountain][:sandbox_max_lifetime_hours] == 72
    end

    test "a non-blank garbage value still refuses to boot", %{base: base} do
      # The refusal exists so a typo cannot silently disable the bound — only
      # blank means "not configured".
      assert_raise RuntimeError, ~r/SANDBOX_IDLE_TIMEOUT_MINUTES/, fn ->
        read_prod(Map.put(base, "SANDBOX_IDLE_TIMEOUT_MINUTES", "6O"))
      end
    end
  end

  describe "SPRITES_BASE_URL" do
    test "blank keeps the hosted default rather than an empty base URL", %{base: base} do
      cfg = read_prod(Map.put(base, "SPRITES_BASE_URL", ""))

      assert cfg[:managoat_sandbox][Managoat.Sandbox.Sprites][:base_url] ==
               "https://api.sprites.dev"
    end

    test "a real endpoint is stored verbatim", %{base: base} do
      cfg = read_prod(Map.put(base, "SPRITES_BASE_URL", "https://sprites.internal.example.com"))

      assert cfg[:managoat_sandbox][Managoat.Sandbox.Sprites][:base_url] ==
               "https://sprites.internal.example.com"
    end
  end

  describe "sandbox provider selection" do
    test "blank SANDBOX_PROVIDER defaults to sprites; blank credentials stay unset", %{base: base} do
      cfg =
        read_prod(
          Map.merge(base, %{
            "SANDBOX_PROVIDER" => "",
            "E2B_API_KEY" => "",
            "E2B_BASE_URL" => ""
          })
        )

      assert cfg[:fountain][:sandbox_default_provider] == :sprites
      assert cfg[:managoat_sandbox][Managoat.Sandbox.E2B][:api_key] == nil
      assert cfg[:managoat_sandbox][Managoat.Sandbox.E2B][:base_url] == "https://api.e2b.app"
    end

    test "an explicit default with its credential present is stored as an atom", %{base: base} do
      cfg = read_prod(Map.merge(base, %{"SANDBOX_PROVIDER" => "e2b", "E2B_API_KEY" => "e2b_x"}))
      assert cfg[:fountain][:sandbox_default_provider] == :e2b
      assert cfg[:managoat_sandbox][Managoat.Sandbox.E2B][:api_key] == "e2b_x"
    end

    test "an explicit default without its credential refuses to boot", %{base: base} do
      assert_raise RuntimeError, ~r/E2B_API_KEY is not set/, fn ->
        read_prod(Map.merge(base, %{"SANDBOX_PROVIDER" => "e2b", "E2B_API_KEY" => ""}))
      end
    end

    test "an unknown provider refuses to boot", %{base: base} do
      assert_raise RuntimeError, ~r/must be one of sprites\|e2b\|runner/, fn ->
        read_prod(Map.put(base, "SANDBOX_PROVIDER", "modal"))
      end
    end

    test "daytona, removed in 2026-10, refuses to boot as a default", %{base: base} do
      assert_raise RuntimeError, ~r/must be one of sprites\|e2b\|runner/, fn ->
        read_prod(Map.put(base, "SANDBOX_PROVIDER", "daytona"))
      end
    end
  end
end
