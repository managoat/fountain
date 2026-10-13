defmodule Fountain.TransportSecurityConfigTest do
  @moduledoc """
  Transport hardening that is derived from PUBLIC_URL rather than set by hand.

  The reason it is derived: a release is one artifact, and the same artifact
  runs the hosted instance behind TLS and a self-hoster's compose stack on plain
  http. Anything switched on unconditionally — a secure cookie, an https
  redirect — turns the second into a silent login failure.
  """

  use ExUnit.Case, async: false

  @runtime_exs Path.expand("../../../../config/runtime.exs", __DIR__)

  @base %{
    "PHX_SERVER" => "true",
    "SECRET_KEY_BASE" => String.duplicate("a", 64),
    "DATABASE_URL" => "postgres://u:p@localhost/db",
    "EMAIL_DELIVERY" => "none"
  }

  @vars ~w(PUBLIC_URL CHECK_ORIGIN_EXTRA SPRITES_BASE_URL FORCE_SSL_EXCLUDE_HOSTS)

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

  defp read_prod(env), do: read_all(env)[:fountain]

  # The Sprites adapter reads its settings from the sandbox library's otp_app
  # (Managoat.Sandbox.Config), not from :fountain.
  defp read_sprites(env), do: read_all(env)[:managoat_sandbox][Managoat.Sandbox.Sprites]

  defp read_all(env) do
    for k <- @vars, do: System.delete_env(k)
    System.put_env(env)
    Config.Reader.read!(@runtime_exs, env: :prod)
  end

  describe "over https" do
    setup %{base: base} do
      {:ok, config: read_prod(Map.put(base, "PUBLIC_URL", "https://fountain.example.com"))}
    end

    test "the session cookie is marked secure", %{config: config} do
      assert config[:secure_cookie] == true
    end

    test "force_ssl is on with HSTS", %{config: config} do
      force_ssl = config[:force_ssl]

      assert force_ssl[:hsts] == true
      assert force_ssl[:expires] == 31_536_000
      assert force_ssl[:subdomains] == true
    end

    test "force_ssl excludes localhost by default", %{config: config} do
      assert config[:force_ssl][:exclude] == ["localhost"]
    end

    test "FORCE_SSL_EXCLUDE_HOSTS adds in-network hosts to the exclusion", %{base: base} do
      config =
        read_prod(
          base
          |> Map.put("PUBLIC_URL", "https://fountain.example.com")
          |> Map.put("FORCE_SSL_EXCLUDE_HOSTS", " fountain.fountain.svc.cluster.local, ,localhost")
        )

      assert config[:force_ssl][:exclude] == ["localhost", "fountain.fountain.svc.cluster.local"]
    end

    test "force_ssl rewrites on forwarded headers", %{config: config} do
      # Without this every request looks like http behind a terminating proxy
      # and the redirect loops.
      assert :x_forwarded_proto in config[:force_ssl][:rewrite_on]
    end

    test "HSTS is not preloaded", %{config: config} do
      # Deliberate: the preload list is a one-way door measured in months.
      refute config[:force_ssl][:preload]
    end

    test "force_ssl is not set under the Endpoint key", %{config: config} do
      # This is the bug that reached production. Phoenix reads
      # FountainWeb.Endpoint's :force_ssl with Application.compile_env, so
      # setting it from runtime.exs fails the release's validate_compile_env
      # check and the node aborts during boot:
      #
      #   ERROR! the application :fountain has a different value set for path
      #   [:force_ssl] inside key FountainWeb.Endpoint during runtime compared
      #   to compile time.
      #
      # Config.Reader validates values, not whether they may be set at runtime,
      # so the original tests passed while every pod CrashLoopBackOff'd. The
      # endpoint applies Plug.SSL from :fountain, :force_ssl instead.
      refute config[FountainWeb.Endpoint][:force_ssl]
    end
  end

  describe "over plain http" do
    setup %{base: base} do
      {:ok, config: read_prod(Map.put(base, "PUBLIC_URL", "http://localhost:4000"))}
    end

    test "the session cookie is not marked secure", %{config: config} do
      # It would never be sent back, which reads as login silently failing.
      assert config[:secure_cookie] == false
    end

    test "force_ssl is off", %{config: config} do
      # Otherwise the compose quick-start redirects to a port serving nothing.
      refute config[:force_ssl]
      refute config[FountainWeb.Endpoint][:force_ssl]
    end
  end

  describe "check_origin" do
    test "is just the deployment's own host by default", %{base: base} do
      config = read_prod(Map.put(base, "PUBLIC_URL", "https://fountain.example.com"))

      # `//*.replit.dev` used to be here unconditionally, which let a LiveView
      # websocket be opened from any Replit subdomain.
      assert config[FountainWeb.Endpoint][:check_origin] == ["//fountain.example.com"]
    end

    test "extra origins are opt-in", %{base: base} do
      config =
        base
        |> Map.merge(%{
          "PUBLIC_URL" => "https://fountain.example.com",
          "CHECK_ORIGIN_EXTRA" => "//*.preview.example.com, //staging.example.com"
        })
        |> read_prod()

      assert config[FountainWeb.Endpoint][:check_origin] == [
               "//fountain.example.com",
               "//*.preview.example.com",
               "//staging.example.com"
             ]
    end
  end

  describe "SPRITES_BASE_URL" do
    test "defaults to the hosted endpoint", %{base: base} do
      config = read_sprites(Map.put(base, "PUBLIC_URL", "https://f.example.com"))
      assert config[:base_url] == "https://api.sprites.dev"
    end

    test "can be repointed", %{base: base} do
      config =
        base
        |> Map.merge(%{
          "PUBLIC_URL" => "https://f.example.com",
          "SPRITES_BASE_URL" => "http://sprites.internal:8080"
        })
        |> read_sprites()

      assert config[:base_url] == "http://sprites.internal:8080"
    end
  end
end
