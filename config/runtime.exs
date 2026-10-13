import Config

# Load .env in dev/test
env_path = Path.join(File.cwd!(), ".env")

if config_env() != :prod and File.exists?(env_path) do
  env_path
  |> File.stream!()
  |> Enum.each(fn line ->
    line = String.trim(line)

    cond do
      line == "" ->
        :ok

      String.starts_with?(line, "#") ->
        :ok

      true ->
        case String.split(line, "=", parts: 2) do
          [k, v] ->
            v = v |> String.trim() |> String.trim_leading("\"") |> String.trim_trailing("\"")
            if System.get_env(k) in [nil, ""], do: System.put_env(k, v)

          _ ->
            :ok
        end
    end
  end)
end

server? = System.get_env("PHX_SERVER") in ~w(1 true yes)

if server? do
  config :fountain, FountainWeb.Endpoint, server: true
end

config :fountain, FountainWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

env = config_env()

# The dev fallback below is derived from a constant committed to this repo, so it
# must never be reachable in :prod. The guard is deliberately on config_env()
# alone — gating it on `server?` too would hand that public key to every prod
# process started without PHX_SERVER=true (release eval tasks, migrations, seeds,
# a remote console), and any of those can create a tenant DEK.
# "" counts as missing (#392): docker-compose.yml passes `${VAR:-}` defaults,
# which deliver a present-but-empty variable, and .env.example ships the key
# present but blank. Both must hit the raise, not the decode branch.
master_secrets_key =
  case {System.get_env("MASTER_SECRETS_KEY"), env} do
    {blank, :prod} when blank in [nil, ""] ->
      raise "environment variable MASTER_SECRETS_KEY is missing (32 bytes, url-safe base64, no padding). " <>
              "Generate: openssl rand 32 | base64 | tr '+/' '-_' | tr -d '='"

    {blank, _} when blank in [nil, ""] ->
      :crypto.hash(:sha256, "fountain:dev:master_secrets_key")

    {encoded, _} ->
      case Base.url_decode64(encoded, padding: false) do
        {:ok, <<_::binary-32>> = key} ->
          key

        _ ->
          raise "MASTER_SECRETS_KEY must be 32 bytes encoded as url-safe base64 (no padding)."
      end
  end

config :fountain, :master_secrets_key, master_secrets_key

# "" counts as unset (#396): docker-compose.yml passes `${SPRITES_TOKEN:-}`,
# which delivers a present-but-empty variable, and .env.compose.example ships
# the key blank. Stored verbatim, "" is truthy, so SpritesClient.get!/0's
# `|| raise "SPRITES_TOKEN is not set"` never fired and the operator got an
# opaque 401 from sprites.dev instead of the message written for this case.
sprites_token =
  case System.get_env("SPRITES_TOKEN") do
    blank when blank in [nil, ""] -> nil
    token -> token
  end

# SpritesClient has read :sprites_base_url from application env since it was
# written, but nothing ever set it — so the default was the only value, and
# pointing an instance at a different sandbox backend meant editing config and
# rebuilding. Wiring it does not make Sprites self-hostable (see #189), it just
# stops the endpoint being baked into the release.
#
# "" counts as unset (#513): the compose file passes `${SPRITES_BASE_URL:-}`,
# and `System.get_env/2` only applies its default when the variable is absent
# — a present-but-empty value would become the API base URL and every Sprites
# call would fail.
sprites_base_url =
  case System.get_env("SPRITES_BASE_URL") do
    blank when blank in [nil, ""] -> "https://api.sprites.dev"
    url -> url
  end

# Bounds every HTTP call to the Sprites API. Long-running commands
# (package installs, clones) pass their own per-call :timeout and are not
# affected by this.
sprites_timeout_ms =
  case Integer.parse(System.get_env("SPRITES_TIMEOUT_MS", "30000")) do
    {ms, ""} when ms > 0 ->
      ms

    _ ->
      raise "SPRITES_TIMEOUT_MS must be a positive integer (milliseconds), got: " <>
              inspect(System.get_env("SPRITES_TIMEOUT_MS"))
  end

# The adapters read their settings from the sandbox library's own otp_app
# (Managoat.Sandbox.Config, decisions/0037); the environment variables are
# unchanged, only the key they land on.
config :managoat_sandbox, Managoat.Sandbox.Sprites,
  token: sprites_token,
  base_url: sprites_base_url,
  timeout_ms: sprites_timeout_ms

# ── sandbox providers ────────────────────────────────────────────────────────
#
# Fountain can run sandboxes on more than one backend. Each provider is
# *enabled* by the presence of its credential; `SANDBOX_PROVIDER` picks the
# instance default for newly-created sandboxes (existing rows keep the
# provider stamped on them). Blank counts as unset throughout, matching the
# compose `${VAR:-}` pattern (#396/#513).

e2b_api_key =
  case System.get_env("E2B_API_KEY") do
    blank when blank in [nil, ""] -> nil
    key -> key
  end

e2b_base_url =
  case System.get_env("E2B_BASE_URL") do
    blank when blank in [nil, ""] -> "https://api.e2b.app"
    url -> url
  end

e2b_template =
  case System.get_env("E2B_TEMPLATE") do
    blank when blank in [nil, ""] -> "base"
    template -> template
  end

e2b_user =
  case System.get_env("E2B_USER") do
    blank when blank in [nil, ""] -> "sprite"
    user -> user
  end

config :managoat_sandbox, Managoat.Sandbox.E2B,
  api_key: e2b_api_key,
  base_url: e2b_base_url,
  template: e2b_template,
  user: e2b_user

# Egress credential brokerage (ADR 0019). Blank means off: no broker call is
# made, nothing listens, and every conversation provisions exactly as it did
# before the feature existed. The same "" counts-as-unset rule as
# SPRITES_TOKEN. BROKER_LISTEN_PORT is the switch: the proxy runs inside this
# application, on that port, on every replica. It needs BROKER_PROXY_URL too,
# the address a sandbox dials, which is not the same thing when the sandboxes
# are on another network. BROKER_URL and BROKER_TOKEN selected a vendor proxy
# until production moved off it (#1487); nothing reads them now.
blank_to_nil = fn
  blank when blank in [nil, ""] -> nil
  value -> value
end

broker_proxy_url = blank_to_nil.(System.get_env("BROKER_PROXY_URL"))

broker_listen_port =
  case System.get_env("BROKER_LISTEN_PORT") do
    blank when blank in [nil, ""] ->
      nil

    raw ->
      case Integer.parse(raw) do
        {n, ""} when n in 1..65_535 -> n
        _ -> raise "BROKER_LISTEN_PORT must be a port number between 1 and 65535"
      end
  end

if broker_listen_port && is_nil(broker_proxy_url) do
  raise "BROKER_LISTEN_PORT is set, so BROKER_PROXY_URL must be set too"
end

# The operator ratchet of ADR 0019 §9 is retired. It existed to widen the
# hosted deployment one tenant at a time; it reached `*` on 2026-09-04, and a
# deployment that runs a broker now brokers every tenant. `BROKER_LISTEN_PORT`
# is the only switch, and no tenant is an input to it any more.
#
# `BROKER_TENANTS` is still read, for two reasons.
#
# A list meant "these tenants and no others", and that answer no longer
# exists. Booting on it would silently widen brokerage to tenants an operator
# deliberately left out, so boot refuses and names the removal, the way the
# retired `BROKER_URL` above does.
#
# `*` already meant what brokerage now always does, so it stays accepted — and
# it keeps the one job of #1686. That guard fails the boot in the dangerous
# direction: a deployment that means to broker and loses its listener (the
# `envFrom` drift of #1495) does not half-broker anyone. Brokerage turns
# itself off for everyone, each sandbox gets plaintext GitHub and inference
# credentials instead, and the console keeps working, so nothing downstream can tell it from a deployment that meant to
# broker nobody. Removing the ratchet removes the tenant list that used to
# carry that intent, which makes `*` the last place an operator can state it.
# Until brokerage is unconditional, keep the assertion available.
case (System.get_env("BROKER_TENANTS") || "")
     |> String.split(",")
     |> Enum.map(&String.trim/1)
     |> Enum.reject(&(&1 == "")) do
  [] ->
    :ok

  ["*"] ->
    if is_nil(broker_listen_port) do
      raise "BROKER_TENANTS=* says this deployment brokers egress, so BROKER_LISTEN_PORT " <>
              "must be set too. With no listener, brokerage is off for every tenant and " <>
              "their sandboxes hold plaintext credentials; see docs/configuration.md."
    end

  _ids ->
    raise "BROKER_TENANTS names a list of tenants, and the per-tenant ratchet it " <>
            "belonged to is retired: a deployment with BROKER_LISTEN_PORT set brokers " <>
            "every tenant. Remove BROKER_TENANTS, or set it to `*`, once you accept " <>
            "that the tenants it excluded will be brokered too."
end

config :fountain, :broker_listen_port, broker_listen_port
config :fountain, :broker_proxy_url, broker_proxy_url
config :fountain, :broker_allow_unenforced, System.get_env("BROKER_ALLOW_UNENFORCED") == "true"

broker_log_retention =
  case System.get_env("BROKER_LOG_RETENTION_HOURS") do
    blank when blank in [nil, ""] ->
      168

    raw ->
      case Integer.parse(raw) do
        {n, ""} when n >= 1 -> n
        _ -> raise "BROKER_LOG_RETENTION_HOURS must be a positive integer"
      end
  end

config :fountain, :broker_log_retention_hours, broker_log_retention

# Self-hosted runners (ADR 0022) need no platform credential; the switch is an
# operator opt-out. Blank counts as unset (enabled).
runners_enabled =
  case System.get_env("SANDBOX_RUNNERS_ENABLED") do
    blank when blank in [nil, ""] -> true
    value when value in ["false", "0", "no", "off"] -> false
    value when value in ["true", "1", "yes", "on"] -> true
    other -> raise "SANDBOX_RUNNERS_ENABLED must be true or false, got: #{inspect(other)}"
  end

# Not applied in :test — config/test.exs pins it off there so the suite's
# provider assumptions hold, and the shell must not be able to flip that.
if config_env() != :test, do: config(:fountain, :runners_enabled, runners_enabled)

sandbox_provider_env = System.get_env("SANDBOX_PROVIDER")

sandbox_default_provider =
  case sandbox_provider_env do
    blank when blank in [nil, ""] ->
      :sprites

    value when value in ["sprites", "e2b", "runner"] ->
      # An *explicitly chosen* default must be usable: failing at boot with
      # the missing variable named beats every conversation failing at
      # provision time. An unset SANDBOX_PROVIDER keeps the old behavior —
      # default sprites, credential checked lazily at first use — so
      # migration-only boots and credential-less dev/test still start.
      credential =
        case value do
          "sprites" -> {sprites_token, "SPRITES_TOKEN"}
          "e2b" -> {e2b_api_key, "E2B_API_KEY"}
          # No credential to check; the opt-out is the only way to lose it.
          "runner" -> {if(runners_enabled, do: :enabled), "SANDBOX_RUNNERS_ENABLED"}
        end

      case credential do
        {nil, var} ->
          raise "SANDBOX_PROVIDER=#{value} but #{var} is not set — the default " <>
                  "sandbox provider must have credentials"

        _ ->
          String.to_atom(value)
      end

    other ->
      raise "SANDBOX_PROVIDER must be one of sprites|e2b|runner, got: #{inspect(other)}"
  end

config :fountain, :sandbox_default_provider, sandbox_default_provider

# Two different shapes are needed and they are not interchangeable:
#
#   :public_url — absolute, scheme-ful. Used to build links that leave the app
#                 (verification/reset emails, llms.txt) and as FOUNTAIN_BASE_URL
#                 inside every sprite.
#   :phx_host   — bare host. Used for the endpoint url and check_origin.
#
default_scheme = if env == :prod, do: "https", else: "http"

# FLY_APP_NAME is the one entry nobody sets by hand, and the only candidate
# that is derived rather than read: Fly injects the app's name, and
# `<app>.fly.dev` is the hostname its proxy answers on. fly.toml therefore
# ships with no PUBLIC_URL. It carries an app name that `fly launch` is about
# to replace, and a base URL still naming the old one is silently wrong rather
# than broken — it builds the links in verification emails and every sandbox
# reads it as FOUNTAIN_BASE_URL. An operator's own PUBLIC_URL still wins,
# which is what a custom domain sets.
#
# Each candidate is trimmed and tested on its own rather than chained with
# `||`: "" is truthy in Elixir, so a present-but-empty PUBLIC_URL — the shape
# every `${VAR:-}` and every dashboard field left blank delivers — would win
# the chain and take the fallback out of reach.
#
# PUBLIC_URL is spelled as a quoted literal because `config_reference_test`
# extracts the variables this file reads by scanning for exactly that shape.
# Folded into a `~w` sigil it becomes invisible to it, and PUBLIC_URL reads as
# documentation for a variable nothing consumes.
fly_public_url =
  case System.get_env("FLY_APP_NAME") do
    blank when blank in [nil, ""] -> nil
    app -> "https://#{app}.fly.dev"
  end

public_url_env =
  [
    System.get_env("PUBLIC_URL"),
    fly_public_url
  ]
  |> Enum.map(&String.trim(&1 || ""))
  |> Enum.find(&(&1 != ""))

# In prod the fallback would be http://localhost:4000 — and unlike a missing
# secret, nothing crashes: the instance runs, and every verification/reset
# link and every sprite's FOUNTAIN_BASE_URL silently points at localhost.
# Same treatment mail got: refuse to boot and say what to set. Dev and test
# keep the localhost default. Compose always passes PUBLIC_URL
# (`${PUBLIC_URL:-http://localhost:4000}`), so the quick start is unaffected.
if env == :prod and is_nil(public_url_env) do
  raise """
  PUBLIC_URL is not set.

  It is the absolute base URL users reach this instance at. Without it,
  every link that leaves the app — verification and password-reset emails,
  llms.txt — and every sprite's FOUNTAIN_BASE_URL would silently point at
  http://localhost:4000. Set it, scheme included:

    PUBLIC_URL=https://fountain.example.com
  """
end

public_url = Fountain.PublicUrl.absolute(public_url_env, default_scheme)

phx_host =
  case System.get_env("PHX_HOST") do
    blank when blank in [nil, ""] -> Fountain.PublicUrl.host(public_url)
    host -> host
  end

config :fountain, :public_url, public_url
config :fountain, :phx_host, phx_host

# Prometheus scrape endpoint, served on its own port by FountainWeb.MetricsPlug
# rather than through the public endpoint. Defaults to on in prod and off
# elsewhere, so dev and test never bind a stray listener.
metrics_port =
  case System.get_env("METRICS_PORT") do
    nil -> if env == :prod, do: 9568, else: nil
    "" -> nil
    "0" -> nil
    port -> String.to_integer(port)
  end

config :fountain, :metrics_port, metrics_port

# Error tracking (#211). Inert unless SENTRY_DSN is set: no account, no
# events, nothing leaves the instance — a self-hoster is never conscripted
# into a vendor. The SDK would read SENTRY_DSN on its own; it is spelled out
# here so the contract is visible in one place.
#
# Hosted on sentry.io rather than self-hosted GlitchTip, deliberately: an
# error tracker running on the same cluster as the app is down exactly when
# it is needed. The sentry package is API-compatible with GlitchTip, so
# pointing SENTRY_DSN at one later is the whole migration.
#
# "" counts as unset (#497): the compose file passes `${SENTRY_DSN:-}`, and a
# blank string is not a DSN the SDK should be asked to parse.
#
# Guarding the config value alone is NOT enough (#513 re-run): the SDK reads
# the SENTRY_DSN env var itself. `Sentry.Config.put_config/2` re-validates a
# partial keyword that has no :dsn entry, `fill_in_from_env` then
# `Keyword.put_new`s the raw env value into it — and Sentry.Application.start
# calls put_config at boot, so a blank SENTRY_DSN crashes the :sentry app no
# matter what `config :sentry, dsn:` says. Config providers run in the
# release VM before any application starts, so deleting the blank variable
# here is what actually keeps it away from the SDK.
sentry_dsn =
  case System.get_env("SENTRY_DSN") do
    blank when blank in [nil, ""] ->
      System.delete_env("SENTRY_DSN")
      nil

    dsn ->
      dsn
  end

config :sentry,
  dsn: sentry_dsn,
  environment_name: System.get_env("SENTRY_ENVIRONMENT", to_string(env)),
  # Correlates events with deploys: "this started with sha-…". Set by the
  # image build; nil locally, which the SDK accepts.
  release: System.get_env("FOUNTAIN_BUILD_SHA"),
  in_app_otp_apps: [:fountain],
  # This app holds tenant secrets; nothing the SDK can gather on its own
  # (cookies, user IPs, request bodies) should ride along by default.
  send_default_pii: false

# What the chrome calls this deployment (Fountain.Brand): the sidebar header,
# the <title>, the sign-in and consent pages and every email subject. The
# engine stays Fountain everywhere it is named as the engine — the CLI, the
# API, the manual.
case System.get_env("PRODUCT_NAME") do
  nil -> :ok
  value -> config :fountain, :product_name, String.trim(value)
end

# Where the brand's icon, favicons and Open Graph card are served from
# (Fountain.Brand.assets/0 names the six files). Unset, the release serves the
# engine's own files from priv/static; set, the chrome links this directory
# instead and the CSP's img-src admits its origin. Pixels do not belong in an
# env var, and rebuilding the engine to change the chrome's icon is the wrong
# size of change, so the bundle lives on any static host and this points at it.
case System.get_env("BRAND_ASSETS_URL") do
  nil ->
    :ok

  value ->
    trimmed = value |> String.trim() |> String.trim_trailing("/")

    if trimmed != "" and not String.starts_with?(trimmed, ["http://", "https://"]) do
      raise "BRAND_ASSETS_URL must be an absolute http(s) URL, got: #{inspect(value)}"
    end

    config :fountain, :brand_assets_url, trimmed
end

# Registration was open to the world with no way to close it. An operator
# exposing an instance had no control over who signed up, and every signup
# can start sandboxes on the instance's provider credentials.
config :fountain, :registration_enabled, System.get_env("REGISTRATION_ENABLED", "true") != "false"

allowed_signup_domains =
  case System.get_env("REGISTRATION_ALLOWED_EMAIL_DOMAINS") do
    blank when blank in [nil, ""] ->
      []

    list ->
      list
      |> String.split(",", trim: true)
      |> Enum.map(&(&1 |> String.trim() |> String.downcase()))
  end

config :fountain, :registration_allowed_email_domains, allowed_signup_domains

# A shared code every signup must present, on the form, the JSON endpoint and
# a first GitHub sign-in alike. Unset or blank leaves signup open.
config :fountain,
       :registration_access_code,
       (case System.get_env("REGISTRATION_ACCESS_CODE") do
          nil -> nil
          code -> if String.trim(code) == "", do: nil, else: String.trim(code)
        end)

# Self-host first-admin bootstrap (ADR 0011): the first account to become
# verified on an instance with no admin is promoted to admin, so standing up
# an instance needs no release-task shenanigans. Opt-in: on a multi-tenant
# deployment this would hand the instance to whoever registers first.
# Skipped in :test — config/test.exs pins it off and tests toggle it through
# the application env, independent of the developer's shell.
if config_env() != :test do
  config :fountain, :first_user_admin, System.get_env("FIRST_USER_ADMIN", "false") == "true"
end

# Sandbox lifetime bounds. Either set to 0 disables that bound; an operator who
# wants sandboxes to live until explicitly terminated sets both to 0 and gets
# the pre-#167 behaviour back. Reclaiming a sandbox does not end its
# conversation — see Fountain.Conversations.Lifecycle.
#
# Refused at boot rather than ignored: a typo here would otherwise silently
# disable the bound, and an operator who set a limit deserves to find out that
# it did not take effect now rather than from a bill.
# "" counts as unset (#513): the compose file passes `${VAR:-}`, which
# delivers a present-but-empty variable — that is "not configured", not a
# typo, so it gets the default instead of the refusal below. The refusal
# still applies to anything non-blank that fails to parse.
parse_bound = fn var, default ->
  value =
    case System.get_env(var) do
      blank when blank in [nil, ""] -> default
      set -> set
    end

  case Integer.parse(value) do
    {n, ""} when n >= 0 ->
      n

    _ ->
      raise """
      #{var} must be a non-negative integer (got: #{inspect(System.get_env(var))}).

      Set it to 0 to disable this bound entirely.
      """
  end
end

config :fountain,
  sandbox_idle_timeout_minutes: parse_bound.("SANDBOX_IDLE_TIMEOUT_MINUTES", "60"),
  sandbox_max_lifetime_hours: parse_bound.("SANDBOX_MAX_LIFETIME_HOURS", "0")

# Checkpoints (#1073). Off by default: a Sprites checkpoint is scoped to the
# sprite that made it (#654), so what it buys is rolling a persistent home
# back to its last park — and every park adds one, with no retention yet.
checkpoint_creation_enabled = System.get_env("CHECKPOINT_CREATION_ENABLED", "false") == "true"

config :fountain, :checkpoint_creation_enabled, checkpoint_creation_enabled

# The Sprites adapter advertises the :checkpoint capability only while this
# is on (a Sprites checkpoint is scoped to the sprite that made it, #654).
config :managoat_sandbox, Managoat.Sandbox.Sprites,
  checkpoint_creation_enabled: checkpoint_creation_enabled

# The files snapshot a park takes (ADR 0063). On by default; `false` stops
# parks taking one without a deploy, and a parked sandbox's files then read
# as not ready, as before. Skipped in :test, where config/test.exs pins it.
if config_env() != :test do
  config :fountain, Fountain.SandboxFiles.Snapshots,
    enabled: System.get_env("SANDBOX_SNAPSHOTS_ENABLED", "true") != "false"
end

# CIDRs treated as proxies when resolving the client IP from X-Forwarded-For.
# Only widen this to cover addresses that are genuinely proxies — anything
# trusted here is stepped over, so an over-broad list lets a client spoof its
# way past rate limiting.
# "" counts as unset (#497): the compose file passes `${TRUSTED_PROXIES:-}`,
# and a blank value must leave the built-in default in place rather than
# replacing it with an empty list.
case System.get_env("TRUSTED_PROXIES") do
  blank when blank in [nil, ""] ->
    :ok

  proxies ->
    config :fountain,
           :trusted_proxies,
           proxies |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
end

# Inference credentials are per-user (BYO, ADR 0008) and live in the
# inference_credentials table — no platform-level env vars for them.

# Erlang clustering (docs/architecture.md#clustering): poll one DNS name and
# connect to `<RELEASE_NAME>@<address>` for every address it returns. In
# Kubernetes the manifest sets the query to a headless service. On Fly,
# rel/env.sh.eex sets it to `<app>.internal` when RELEASE_COOKIE is set, and
# names the node after the machine's 6PN address; that name answers with AAAA
# records only, and DNSPoll's default resolver asks for A and AAAA both. Unset
# or "", there is no topology, and the rehydrator sweeps without waiting for
# peers.
cluster_topologies =
  case System.get_env("CLUSTER_DNS_QUERY") do
    nil ->
      []

    "" ->
      []

    query ->
      [
        fountain: [
          strategy: Cluster.Strategy.DNSPoll,
          config: [
            polling_interval: 5_000,
            query: query,
            node_basename: System.get_env("RELEASE_NAME", "fountain")
          ]
        ]
      ]
  end

config :libcluster, topologies: cluster_topologies

# GitHub OAuth (§2.4)
# base_path must match the router prefix in router.ex (/auth/oauth/:provider).
config :ueberauth, Ueberauth,
  base_path: "/auth/oauth",
  providers: [
    github: {Ueberauth.Strategy.Github, [default_scope: "user:email"]}
  ]

# Only when the env var is present: an unconditional write here clobbers
# whatever config/test.exs set with nil, so in CI (no env vars, no .env)
# github_configured?/0 was false and the button tests failed — while local
# runs passed because .env supplied the var. Absent stays absent.
if github_client_id = System.get_env("GITHUB_OAUTH_CLIENT_ID") do
  config :ueberauth, Ueberauth.Strategy.Github.OAuth,
    client_id: github_client_id,
    client_secret: System.get_env("GITHUB_OAUTH_CLIENT_SECRET")
end

# Concurrency (ADR 0042): the fleet ceiling — the most live sandboxes the
# deployment will run in total, which is the provider plan's number (Sprites' $20 plan allows about 20).
whole_number = fn var, default ->
  case System.get_env(var) do
    value when value in [nil, ""] ->
      default

    value ->
      case Integer.parse(String.trim(value)) do
        {n, ""} when n >= 0 -> n
        _ -> raise "#{var} must be a whole number, 0 or more, got #{inspect(value)}"
      end
  end
end

#
# Skipped in :test, so a developer's own SANDBOX_FLEET_CEILING cannot change
# what the suite's capacity tests meet.
if config_env() != :test do
  config :fountain, :sandboxes, fleet_ceiling: whole_number.("SANDBOX_FLEET_CEILING", 20)
end

# Platform inference keys (#1388, ADR 0038 decision 3, amending ADR 0008).
#
# Fountain runs a tenant's agent on one of these when the tenant has no
# credential of their own for the model's provider. The tenant's own
# credential always wins. Nothing caps or meters what these keys spend: every
# account's usage on them is billed to this deployment's provider account.
#
# **Blank means off, per provider.** A deployment that sets none of these
# behaves exactly as it did before the feature existed: bring-your-own only.
# That is what makes it opt-in for a self-hoster, who would otherwise be
# paying a model provider for their users without having said so.
#
# Anthropic first: the default agent every verified account gets (#1389) runs
# on the claude runtime, so this is the one key that makes the four-step path
# — verify, copy, run, reply — work with nothing else configured.
config :fountain,
  platform_anthropic_api_key: System.get_env("PLATFORM_ANTHROPIC_API_KEY"),
  platform_openai_api_key: System.get_env("PLATFORM_OPENAI_API_KEY"),
  platform_gemini_api_key: System.get_env("PLATFORM_GEMINI_API_KEY")

# Mail delivery.
#
# With no adapter configured this used to silently fall back to
# Swoosh.Adapters.Local — an in-memory mailbox with no preview route in prod. So
# the verification email went nowhere, and since login is refused while
# email_verified_at is nil, the very first signup on a fresh instance
# dead-ended with nothing pointing at the cause. Silence is the worst possible
# behaviour here, so an unconfigured production instance now refuses to boot and
# says what to do about it.
#
# Resend is the hosted option. SMTP is the one that matters for self-hosting —
# it was named in the launch checklist and the engineering plan and never
# actually implemented, so operators were told to set SMTP_* variables that did
# nothing.
if config_env() == :prod do
  # No default: the old fallback was the hosted instance's sending domain, so
  # a self-hoster who configured a provider but not EMAIL_FROM sent mail as
  # someone else's domain — rejected by any provider checking SPF/DKIM, and
  # wrong even where it wasn't. Required when a real adapter is selected
  # (enforced after the adapter choice below); with mail off it is only a
  # placeholder in headers that are never sent.
  email_from =
    case System.get_env("EMAIL_FROM") do
      blank when blank in [nil, ""] -> nil
      from -> from
    end

  # Optional (#450): where "contact support" in account emails points. Unset,
  # the copy stays vague — EMAIL_FROM is usually a noreply@ address, so
  # "reply to this email" would point somewhere replies go to die.
  config :fountain, :support_email, System.get_env("SUPPORT_EMAIL")

  # "" counts as unset for the adapter choice (#396): docker-compose.yml passes
  # `${RESEND_API_KEY:-}` / `${SMTP_HOST:-}` / `${SMTP_USERNAME:-}`, which
  # deliver present-but-empty variables — and "" is truthy, so a blank
  # RESEND_API_KEY selected the Resend adapter, made the EMAIL_DELIVERY=none
  # and SMTP branches unreachable under compose, and POSTed every verification
  # email (recipient address + signed URL) to api.resend.com to be 401'd.
  # A blank SMTP_USERNAME likewise forced `auth: :always` with an empty
  # username against unauthenticated relays.
  resend_api_key =
    case System.get_env("RESEND_API_KEY") do
      blank when blank in [nil, ""] -> nil
      key -> key
    end

  smtp_host =
    case System.get_env("SMTP_HOST") do
      blank when blank in [nil, ""] -> nil
      host -> host
    end

  smtp_username =
    case System.get_env("SMTP_USERNAME") do
      blank when blank in [nil, ""] -> nil
      username -> username
    end

  cond do
    resend_api_key ->
      config :fountain, Fountain.Mailer, adapter: Swoosh.Adapters.Resend, api_key: resend_api_key

    smtp_host ->
      config :fountain, Fountain.Mailer,
        adapter: Swoosh.Adapters.SMTP,
        relay: smtp_host,
        port: String.to_integer(System.get_env("SMTP_PORT", "587")),
        username: smtp_username,
        password: System.get_env("SMTP_PASSWORD"),
        # STARTTLS by default; set SMTP_TLS=never for a relay on a trusted
        # network that does not offer it.
        tls: String.to_atom(System.get_env("SMTP_TLS", "always")),
        auth: if(smtp_username, do: :always, else: :never),
        retries: 2

    System.get_env("EMAIL_DELIVERY") == "none" ->
      # Explicit opt-out, for an instance that only uses OAuth sign-in or is
      # being evaluated. Email verification gates nothing when the link can
      # never be delivered, so registration auto-verifies accounts in this
      # mode (:email_enabled below) instead of dead-ending them.
      # IO.puts rather than IO.warn: a stacktrace here points at config code and
      # tells the operator nothing.
      config :fountain, :email_enabled, false

      IO.puts(:stderr, """

      [fountain] EMAIL_DELIVERY=none — email is disabled.

      Accounts self-verify at registration, but password-reset and all other
      account email cannot be delivered — a forgotten password is not
      recoverable in this mode. Prefer OAuth sign-in, or configure SMTP.
      """)

    true ->
      raise """
      No mail delivery is configured.

      Verification and password-reset emails would be discarded, and signup
      would dead-end with no visible error. Set one of:

        RESEND_API_KEY=...                 hosted delivery via Resend
        SMTP_HOST=... SMTP_PORT=587        any SMTP server
          SMTP_USERNAME=... SMTP_PASSWORD=...
        EMAIL_DELIVERY=none                deliberately disable email

      With EMAIL_DELIVERY=none, accounts self-verify at registration, but
      password-reset email cannot be delivered.
      """
  end

  if (resend_api_key || smtp_host) && is_nil(email_from) do
    raise """
    Mail delivery is configured but EMAIL_FROM is not set.

    Every provider that checks SPF/DKIM would reject mail sent from a domain
    you don't control, so there is no usable default. Set it to an address on
    a domain your provider is verified for:

      EMAIL_FROM=noreply@fountain.example.com
    """
  end

  config :fountain, :email_from, email_from || "noreply@localhost"
end

# Boot-time migrations (#610). A release migrates before it serves, on every
# replica, which is right for the single-replica shape this ships as. The
# standard Kubernetes shape is the other one: migrations run once in a Job,
# and the app pods only serve — which needs a way to tell a pod not to
# migrate. MIGRATE_ON_BOOT=false is that way; `bin/migrate` (and
# `Fountain.Release.migrate/0` behind it) always migrates regardless, because
# it is the entrypoint the Job runs.
#
# Skipped in :test — config/test.exs pins it, so a developer's shell cannot
# change what the suite exercises.
if config_env() != :test do
  config :fountain,
         :migrate_on_boot,
         System.get_env("MIGRATE_ON_BOOT", "true") not in ~w(false 0 no)
end

# Database config is deliberately NOT behind `server?`. Release tasks
# (`bin/fountain_server eval 'Fountain.Release...'`) run without PHX_SERVER
# and still need the repo — gating this on `server?` left them with a repo
# that had no :database at all.
if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise "environment variable DATABASE_URL is missing."

  # verify_none is the historical behaviour. DATABASE_SSL_VERIFY=true turns on
  # real certificate verification, using an explicit CA bundle when given and
  # the OS trust store otherwise — no extra dependency, and OTP loads it.
  #
  # A blank CA file counts as unset (#497): the compose file passes
  # `${DATABASE_SSL_CA_FILE:-}`, and verify_peer with `cacertfile: ''` would
  # reject every certificate instead of falling back to the OS trust store.
  database_ssl_ca_file =
    case System.get_env("DATABASE_SSL_CA_FILE") do
      blank when blank in [nil, ""] -> nil
      path -> path
    end

  database_ssl_opts =
    case {System.get_env("DATABASE_SSL_VERIFY"), database_ssl_ca_file} do
      {"true", nil} ->
        [verify: :verify_peer, cacerts: :public_key.cacerts_get(), depth: 3]

      {"true", ca_file} ->
        [verify: :verify_peer, cacertfile: to_charlist(ca_file), depth: 3]

      _ ->
        [verify: :verify_none]
    end

  config :fountain, Fountain.Repo,
    url: database_url,
    # Fly Managed Postgres (`fly mpg attach`) hands out a *.flympg.net host
    # that resolves to a private 6PN IPv6 address only. Postgrex resolves as
    # IPv4 unless told otherwise, so without this every boot on Fly dies in
    # migrate_on_boot with :nxdomain. Opt-in, because an IPv4-only database
    # host would stop resolving under :inet6.
    socket_options: if(System.get_env("DATABASE_IPV6") == "true", do: [:inet6], else: []),
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # TLS was hardcoded on with no override, which meant the canonical
    # self-host setup — app and Postgres in containers — could not connect at
    # all, because a stock postgres image does not serve TLS. Defaults to on so
    # the hosted deployment is unchanged.
    ssl: System.get_env("DATABASE_SSL", "true") != "false",
    # verify_none is the historical behaviour: encrypted but not authenticated,
    # so a MITM between app and database is possible. Set DATABASE_SSL_VERIFY=true
    # with DATABASE_SSL_CA_FILE to actually verify the server.
    ssl_opts: database_ssl_opts
end

if config_env() == :prod and server? do
  # "" counts as missing (#392): the compose file passes `${SECRET_KEY_BASE:-}`,
  # and an empty string must not sail past an `||` guard into the endpoint.
  secret_key_base =
    case System.get_env("SECRET_KEY_BASE") do
      blank when blank in [nil, ""] ->
        raise "environment variable SECRET_KEY_BASE is missing."

      value ->
        value
    end

  host = phx_host

  # Scheme and port come from PUBLIC_URL rather than being pinned to https/443,
  # so a self-hoster terminating on plain HTTP or a non-standard port generates
  # correct URLs. For the hosted deployment PUBLIC_URL is https, and URI.parse
  # fills in 443, so this is byte-identical to the previous hardcoding.
  public_uri = URI.parse(public_url)

  extra_origins =
    case System.get_env("CHECK_ORIGIN_EXTRA") do
      blank when blank in [nil, ""] -> []
      list -> list |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
    end

  # Everything below only makes sense over TLS, so it is derived from the scheme
  # of PUBLIC_URL rather than set independently. A self-hoster on plain http
  # gets none of it and keeps working; anyone on https gets all of it without
  # having to know it exists.
  https? = public_uri.scheme == "https"

  # A cookie marked secure is never sent back over http, so this must not be on
  # for an http deployment — it would look like login silently failing.
  config :fountain, :secure_cookie, https?

  # Deliberately NOT `config :fountain, FountainWeb.Endpoint, force_ssl: ...`.
  # Phoenix reads that key with Application.compile_env, so setting it here
  # fails the release's validate_compile_env check and aborts boot:
  #
  #   ERROR! the application :fountain has a different value set for path
  #   [:force_ssl] inside key FountainWeb.Endpoint during runtime compared to
  #   compile time.
  #
  # The endpoint applies Plug.SSL itself from this key instead, which is what
  # `force_ssl:` does internally anyway — and it has to be a runtime decision,
  # since one release artifact serves both an https deployment and a
  # self-hoster's http compose stack.
  #
  # rewrite_on is required behind a terminating proxy: without it every request
  # looks like http to the app and the redirect loops.
  # FORCE_SSL_EXCLUDE_HOSTS: hosts the redirect and HSTS leave alone, for callers
  # inside the deployment's own network that reach the app over plain http at
  # its service name (a Kubernetes Service, a compose service), with no proxy
  # in front to set X-Forwarded-Proto. Without it they are sent to https:// on
  # a host that serves nothing there. localhost stays excluded, as Plug.SSL's
  # default has it.
  force_ssl_exclude =
    (System.get_env("FORCE_SSL_EXCLUDE_HOSTS") || "")
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))

  if https? do
    config :fountain, :force_ssl,
      rewrite_on: [:x_forwarded_proto, :x_forwarded_host, :x_forwarded_port],
      exclude: Enum.uniq(["localhost" | force_ssl_exclude]),
      hsts: true,
      # One year, including subdomains. No `preload`: that is a one-way door —
      # getting off the preload list takes months — and not this change's call.
      expires: 31_536_000,
      subdomains: true
  end

  config :fountain, FountainWeb.Endpoint,
    url: [host: host, port: public_uri.port || 443, scheme: public_uri.scheme || "https"],
    http: [ip: {0, 0, 0, 0, 0, 0, 0, 0}],
    # check_origin guards the LiveView websocket/longpoll handshake. Setting an
    # explicit list replaces the default (the endpoint's own host), so we must
    # re-list it here. `//*.replit.dev` allows Replit preview/dev subdomains.
    # An explicit list replaces the default (the endpoint's own host), so the
    # host has to be re-listed here. `//*.replit.dev` used to be in this list,
    # which let a LiveView websocket be opened from any Replit subdomain — dev
    # convenience that leaked into the production branch. Extra origins are now
    # opt-in via CHECK_ORIGIN_EXTRA, so a preview environment can add its own
    # without every deployment inheriting it.
    check_origin: ["//#{host}" | extra_origins],
    secret_key_base: secret_key_base

  # ── OpenTelemetry ─────────────────────────────────────────────────────────
  #
  # Export traces via OTLP (HTTP/protobuf). Reads standard OTEL env vars:
  #   OTEL_SERVICE_NAME          — defaults to "fountain"
  #   OTEL_EXPORTER_OTLP_ENDPOINT — e.g. "https://api.honeycomb.io"
  #   OTEL_EXPORTER_OTLP_HEADERS  — e.g. "x-honeycomb-team=<key>"
  #
  # OFF unless an export target is explicitly configured (#317): the exporter
  # used to default to :otlp aimed at api.honeycomb.io, so a self-hoster who
  # set none of these got continuous rejected span batches against a
  # third-party vendor plus exporter noise in the logs. The SDK still honours
  # OTEL_TRACES_EXPORTER itself (with higher precedence than this), so
  # export can be forced on or off either way.
  otel_endpoint = System.get_env("OTEL_EXPORTER_OTLP_ENDPOINT")
  otel_configured? = not is_nil(otel_endpoint)

  # Parse "key=val,key2=val2" header strings from OTEL_EXPORTER_OTLP_HEADERS.
  # A vendor that authenticates by header takes it here (Honeycomb:
  # x-honeycomb-team=<key>); the HONEYCOMB_* shortcuts that used to add it
  # are gone.
  otel_headers =
    case System.get_env("OTEL_EXPORTER_OTLP_HEADERS") do
      nil ->
        []

      raw ->
        raw
        |> String.split(",")
        |> Enum.flat_map(fn pair ->
          case String.split(pair, "=", parts: 2) do
            [k, v] -> [{String.trim(k), String.trim(v)}]
            _ -> []
          end
        end)
    end

  config :opentelemetry,
    span_processor: :batch,
    traces_exporter: if(otel_configured?, do: :otlp, else: :none),
    resource: [
      {"service.name", System.get_env("OTEL_SERVICE_NAME", "fountain")},
      {"deployment.environment", System.get_env("FLY_APP_NAME", "prod")}
    ]

  if otel_configured? do
    config :opentelemetry_exporter,
      otlp_protocol: :http_protobuf,
      otlp_endpoint: otel_endpoint,
      otlp_headers: otel_headers
  end
end

# ── CORS for /api ─────────────────────────────────────────────────────────
#
# Browser clients on other origins (the standalone team app, #809). Empty —
# the default — leaves CORS off. See FountainWeb.Plugs.Cors. Read in every
# env so a dev server can allow its Vite origin the same way prod does.
config :fountain,
       :api_cors_origins,
       "API_CORS_ORIGINS"
       |> System.get_env("")
       |> String.split(",", trim: true)
       |> Enum.map(&String.trim/1)

# ── The browser apps on top of the API ────────────────────────────────────
#
# Fountain's own UI is a console; conversations and the team roster are
# separate single-page apps (Fountain.Apps). Both default to the builds
# hosted on demo.managoat.com, which work against any Fountain the reader types
# in — provided this server admits that origin in API_CORS_ORIGINS. Point
# these at your own deployment instead, or set one to "" to say this
# deployment has no such app.
for {key, env} <- [conversations_app_url: "CONVERSATIONS_APP_URL", team_app_url: "TEAM_APP_URL"] do
  case System.get_env(env) do
    nil -> :ok
    value -> config :fountain, key, String.trim(value)
  end
end

# ── OAuth clients ─────────────────────────────────────────────────────────
#
# The public browser apps allowed to sign in with Fountain (#818), as JSON:
#   OAUTH_CLIENTS='[{"id":"fountain-conversations","name":"Fountain Conversations",
#                    "redirect_uris":["https://fountain-conversations.demo.managoat.com/"]}]'
# Unset (or invalid) means no clients — /oauth/authorize refuses everything —
# except in dev and test, whose config files register the local apps.
case System.get_env("OAUTH_CLIENTS") do
  blank when blank in [nil, ""] ->
    :ok

  json ->
    case Jason.decode(json) do
      {:ok, list} when is_list(list) ->
        config :fountain, Fountain.OAuth, clients: list

      _ ->
        raise "OAUTH_CLIENTS must be a JSON array of {id, name, redirect_uris}"
    end
end
