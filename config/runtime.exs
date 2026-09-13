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

# Fixed testing runtime; never enabled by the presence of ordinary provider keys.
# Keep tests independent of the operator's shell environment.
if env != :test do
  config :fountain, :deployed_acp_fixture, %{
    enabled: System.get_env("DEPLOYED_ACP_FIXTURE_ENABLED") == "true",
    user_id: System.get_env("DEPLOYED_ACP_FIXTURE_USER_ID")
  }
end

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

daytona_api_key =
  case System.get_env("DAYTONA_API_KEY") do
    blank when blank in [nil, ""] -> nil
    key -> key
  end

daytona_api_url =
  case System.get_env("DAYTONA_API_URL") do
    blank when blank in [nil, ""] -> "https://app.daytona.io/api"
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

daytona_snapshot =
  case System.get_env("DAYTONA_SNAPSHOT") do
    blank when blank in [nil, ""] -> nil
    snapshot -> snapshot
  end

config :managoat_sandbox, Managoat.Sandbox.Daytona,
  api_key: daytona_api_key,
  api_url: daytona_api_url,
  snapshot: daytona_snapshot

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

# BROKER_URL selected a whole backend, so a deployment still carrying it is
# told rather than left to broker nothing in silence.
if blank_to_nil.(System.get_env("BROKER_URL")) do
  raise "BROKER_URL is set, but the Agent Vault backend was removed in #1487. " <>
          "Set BROKER_LISTEN_PORT and BROKER_PROXY_URL instead; see docs/configuration.md."
end

# BROKER_TOKEN is only a warning, and the difference matters. It never turned
# anything on by itself: it was the credential BROKER_URL used. Refusing to
# boot over a leftover one punishes an upgrade for a variable that was doing
# nothing, and it is the kind of value that outlives a deployment change by
# sitting in a secret store rather than in a manifest. That is exactly how it
# crash-looped this deployment's own rollout: the variable had been dropped
# from the Deployment, and arrived anyway through `envFrom`.
if blank_to_nil.(System.get_env("BROKER_TOKEN")) do
  IO.warn(
    "BROKER_TOKEN is set and is ignored: the Agent Vault backend was removed in #1487. " <>
      "Remove it from your secret store; it is a credential for a service that no longer exists."
  )
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
# itself off for everyone, each sandbox gets plaintext GitHub, inference and
# connection credentials instead, and the console and the connections keep
# working, so nothing downstream can tell it from a deployment that meant to
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

broker_session_ttl =
  case System.get_env("BROKER_SESSION_TTL_SECONDS") do
    blank when blank in [nil, ""] ->
      21_600

    raw ->
      case Integer.parse(raw) do
        {n, ""} when n >= 300 and n <= 604_800 -> n
        _ -> raise "BROKER_SESSION_TTL_SECONDS must be an integer between 300 and 604800"
      end
  end

config :fountain, :broker_listen_port, broker_listen_port
config :fountain, :broker_proxy_url, broker_proxy_url
config :fountain, :broker_session_ttl_seconds, broker_session_ttl
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

    value when value in ["sprites", "e2b", "daytona", "runner"] ->
      # An *explicitly chosen* default must be usable: failing at boot with
      # the missing variable named beats every conversation failing at
      # provision time. An unset SANDBOX_PROVIDER keeps the old behavior —
      # default sprites, credential checked lazily at first use — so
      # migration-only boots and credential-less dev/test still start.
      credential =
        case value do
          "sprites" -> {sprites_token, "SPRITES_TOKEN"}
          "e2b" -> {e2b_api_key, "E2B_API_KEY"}
          "daytona" -> {daytona_api_key, "DAYTONA_API_KEY"}
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
      raise "SANDBOX_PROVIDER must be one of sprites|e2b|daytona|runner, got: #{inspect(other)}"
  end

config :fountain, :sandbox_default_provider, sandbox_default_provider

# Two different shapes are needed and they are not interchangeable:
#
#   :public_url — absolute, scheme-ful. Used to build links that leave the app
#                 (verification/reset emails, llms.txt) and as FOUNTAIN_BASE_URL
#                 inside every sprite.
#   :phx_host   — bare host. Used for the endpoint url and check_origin.
#
# `FOUNTAIN_DOMAIN` was used verbatim for both, and every shipped example sets
# it bare (render.yaml, fly.toml, k8s/deployment.yaml), so :public_url came out
# schemeless — "fountain.example.com/users/confirm/<token>" is not a link, and
# a schemeless FOUNTAIN_BASE_URL is not resolvable by the in-sprite client.
#
# PUBLIC_URL and PHX_HOST are the explicit replacements. FOUNTAIN_DOMAIN still
# works and is normalised into whichever shape is being asked for, so existing
# deployments keep booting and get correct links without an env change.
default_scheme = if env == :prod, do: "https", else: "http"

# RENDER_EXTERNAL_URL and FLY_APP_NAME are the two entries nobody sets by
# hand. Render injects the former into every web service as the absolute URL
# that service is reachable at. Without it, render.yaml has a chicken-and-egg
# problem — the hostname does not exist until the first deploy, and the raise
# below means that first deploy is the one that cannot come up. An operator's
# own PUBLIC_URL still wins, which is what a custom domain sets.
#
# Each candidate is trimmed and tested on its own rather than chained with
# `||`: "" is truthy in Elixir, so a present-but-empty PUBLIC_URL — the shape
# every `${VAR:-}` and every dashboard field left blank delivers — would win
# the chain and take the fallbacks out of reach.
#
# Spelled as separate quoted literals because `config_reference_test` extracts
# the variables this file reads by scanning for exactly that shape. Folded
# into a `~w` sigil they become invisible to it, and PUBLIC_URL reads as
# documentation for a variable nothing consumes.
#
# FLY_APP_NAME is the same problem in a different shape, and it is last
# because it is the only candidate that is derived rather than read: Fly
# injects the app's name, and `<app>.fly.dev` is the hostname its proxy
# answers on. fly.toml therefore ships with no PUBLIC_URL. It carries an app
# name that `fly launch` is about to replace, and a base URL still naming the
# old one is silently wrong rather than broken — it builds the links in
# verification emails and every sandbox reads it as FOUNTAIN_BASE_URL. An
# operator's own PUBLIC_URL wins here too, which is what a custom domain sets.
fly_public_url =
  case System.get_env("FLY_APP_NAME") do
    blank when blank in [nil, ""] -> nil
    app -> "https://#{app}.fly.dev"
  end

public_url_env =
  [
    System.get_env("PUBLIC_URL"),
    System.get_env("FOUNTAIN_DOMAIN"),
    System.get_env("RENDER_EXTERNAL_URL"),
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

# ADR 0031 made the credit gate a product invariant. For a self-hosted
# instance it is just a lock on the front door with no key, so it is config
# rather than a source patch — and off by default (#336): an operator
# exporting env by hand who never hears of CREDITS_ENABLED must not lock
# themselves out of their own instance. The hosted deployment is the one that
# opts in (its overlay sets CREDITS_ENABLED=true explicitly).
#
# BILLING_ENABLED was the name until #1144; it is read as an alias for one
# release, with a warning, so a deployment can flip at its own pace.
#
# Skipped in :test — the suite pins the gate on in config/test.exs and
# toggles it per-test through the application env, independent of whatever
# CREDITS_ENABLED happens to be in the developer's shell or .env.
credits_enabled? =
  case {System.get_env("CREDITS_ENABLED"), System.get_env("BILLING_ENABLED")} do
    {nil, nil} ->
      false

    {nil, legacy} ->
      IO.puts(:stderr, """

      WARNING: BILLING_ENABLED is deprecated; set CREDITS_ENABLED=#{legacy} instead.
      The alias will be removed in a later release.
      """)

      legacy != "false"

    {value, _} ->
      value != "false"
  end

if config_env() != :test do
  config :fountain, :credits_enabled, credits_enabled?
end

# What the chrome calls this deployment (Fountain.Brand): the sidebar header,
# the <title>, the sign-in and consent pages and every email subject. The
# engine stays Fountain everywhere it is named as the engine — the CLI, the
# API, the manual — so a hosted deployment under another brand sets this and
# the manual explains the split at the top of every page.
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

# Which page `/` serves. The hosted deployment shows the product pitch; every
# other deployment shows a plain front door, for the reason a self-hosted
# instance does not serve the upstream project's legal terms either. Off by
# default, opted into by the hosted deployment's overlay.
#
# Skipped in :test — config/test.exs pins it on, so the suite exercises the
# marketing page and flips it off per-test through the application env.
if config_env() != :test do
  config :fountain, :marketing_site, System.get_env("MARKETING_SITE", "false") != "false"
end

# The legal identity /terms and /privacy render (#517). Instance config, not
# source: a self-hosted operator must never serve the upstream project's legal
# terms, and the hosted instance's real entity does not belong in the repo.
# All four or none — a partial set is a typo, and a terms page with a real
# entity but a blank jurisdiction is broken legal copy, so refuse to boot
# rather than render it. Unset entirely, the pages are hidden (billing off)
# or keep #506's loud {{...}} placeholders (billing on) — see Fountain.Legal.
# Skipped in :test — config/test.exs pins values so the developer's shell
# cannot leak into the suite.
if config_env() != :test do
  legal_vars = [
    "LEGAL_ENTITY",
    "LEGAL_CONTACT_EMAIL",
    "LEGAL_JURISDICTION",
    "LEGAL_EFFECTIVE_DATE"
  ]

  legal_values =
    Map.new(legal_vars, fn var ->
      case System.get_env(var) do
        blank when blank in [nil, ""] -> {var, nil}
        value -> {var, String.trim(value)}
      end
    end)

  case Enum.split_with(legal_vars, &legal_values[&1]) do
    {_set, []} ->
      config :fountain, :legal, %{
        entity: legal_values["LEGAL_ENTITY"],
        contact_email: legal_values["LEGAL_CONTACT_EMAIL"],
        jurisdiction: legal_values["LEGAL_JURISDICTION"],
        updated: legal_values["LEGAL_EFFECTIVE_DATE"]
      }

    {[], _unset} ->
      config :fountain, :legal, nil

      # A billing-enabled instance is charging money with no published terms.
      # Warn hard rather than refuse to boot: /terms and /privacy keep serving
      # the loud {{COMPANY_LEGAL_NAME}} placeholders, which is the visible
      # enforcement, and a raise here would take down a running deployment
      # over copy rather than correctness.
      if env == :prod and credits_enabled? do
        IO.puts(:stderr, """

        WARNING: CREDITS_ENABLED is set but no legal identity is configured.
        /terms and /privacy are rendering {{COMPANY_LEGAL_NAME}} placeholders
        to your paying users. Set LEGAL_ENTITY, LEGAL_CONTACT_EMAIL,
        LEGAL_JURISDICTION, and LEGAL_EFFECTIVE_DATE.
        """)
      end

    {set, unset} ->
      raise """
      Legal identity is partially configured: #{Enum.join(set, ", ")} set,
      but #{Enum.join(unset, ", ")} missing. /terms and /privacy need all
      four (entity, contact email, jurisdiction, effective date) to render
      coherent legal copy — set the missing ones, or unset all four to leave
      the pages unpublished.
      """
  end
end

# Registration was open to the world with no way to close it. A self-hoster
# exposing an instance had no control over who signed up, and on the hosted
# side every signup consumes the platform Sprites token.
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

# Webhooks (#700). On by default; a deployment with no outbound HTTP egress
# can switch dispatch off entirely. WEBHOOK_ALLOW_HTTP relaxes the https-only
# rule on endpoint URLs, which is for a self-hosted instance calling a
# receiver on its own network. It does NOT relax the SSRF address checks —
# loopback, link-local and RFC1918 targets stay refused either way.
#
# Skipped in :test, like the runner switch above: config/test.exs pins both
# so the suite exercises a known state, and an unguarded override here would
# silently replace it with whatever the developer's shell happens to say.
if config_env() != :test do
  config :fountain,
    webhooks_enabled: System.get_env("WEBHOOKS_ENABLED", "true") == "true",
    webhook_allow_http: System.get_env("WEBHOOK_ALLOW_HTTP", "false") == "true"
end

# Durable log volume per conversation (#331). Retention bounds the age of
# log_events rows; this bounds the rate — without it a sandbox printing
# garbage could write tens of GB into the same Postgres volume the app
# depends on. 0 disables the cap.
config :fountain,
  log_output_byte_budget: parse_bound.("LOG_OUTPUT_BUDGET_MB", "50") * 1_000_000

# Accounts that registered and never verified are deleted after this many
# days (#258) — they cannot log in, so they are rows, not users. 0 disables
# the sweep. UNVERIFIED_PRUNE_EXEMPT is a comma-separated list of email
# substrings that are never pruned (operator/test accounts that deliberately
# stay unverified).
unverified_prune_exempt =
  case System.get_env("UNVERIFIED_PRUNE_EXEMPT") do
    blank when blank in [nil, ""] -> []
    list -> list |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
  end

config :fountain,
  unverified_prune_after_days: parse_bound.("UNVERIFIED_PRUNE_AFTER_DAYS", "30"),
  unverified_prune_exempt: unverified_prune_exempt

# How many days before a vault secret's recorded expiry the owner is emailed
# (`Fountain.Workers.SecretExpirySweeper`). 0 disables the notice and the
# matching amber badge on the vault page.
config :fountain, secret_expiry_notice_days: parse_bound.("SECRET_EXPIRY_NOTICE_DAYS", "7")

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

# OAuth clients for the platform connection providers (#1178, #1299): a
# tenant signs in to Google, Microsoft or Slack once in the console and
# Fountain holds the refresh token. Not the sign-in provider — that is
# GitHub above. Absent stays absent, so the console says a provider is not
# configured rather than sending anyone to a consent screen with an empty
# client id. The env var names stay literal here for the reference guard.
platform_oauth_clients = [
  {"GOOGLE_OAUTH_CLIENT_ID", "GOOGLE_OAUTH_CLIENT_SECRET", :google_oauth_client_id,
   :google_oauth_client_secret},
  {"MICROSOFT_OAUTH_CLIENT_ID", "MICROSOFT_OAUTH_CLIENT_SECRET", :microsoft_oauth_client_id,
   :microsoft_oauth_client_secret},
  {"SLACK_OAUTH_CLIENT_ID", "SLACK_OAUTH_CLIENT_SECRET", :slack_oauth_client_id,
   :slack_oauth_client_secret}
]

for {id_var, secret_var, id_key, secret_key} <- platform_oauth_clients do
  case System.get_env(id_var) do
    blank when blank in [nil, ""] ->
      :ok

    client_id ->
      config :fountain, [{id_key, client_id}, {secret_key, System.get_env(secret_var)}]
  end
end

# The scopes each platform provider asks for, space-separated, overriding
# the defaults in Fountain.Connections.Platform. The lever for app
# verification: a deployment whose Google app is not verified for a scope
# simply does not request it, and the provider's products light up to match.
platform_oauth_scopes = [
  {"GOOGLE_OAUTH_SCOPES", :google_oauth_scopes},
  {"MICROSOFT_OAUTH_SCOPES", :microsoft_oauth_scopes},
  {"SLACK_OAUTH_USER_SCOPES", :slack_oauth_user_scopes}
]

for {var, key} <- platform_oauth_scopes do
  case System.get_env(var) do
    blank when blank in [nil, ""] -> :ok
    scopes -> config :fountain, [{key, String.split(scopes)}]
  end
end

# Stripe (§5.2)
config :stripity_stripe, api_key: System.get_env("STRIPE_SECRET_KEY")

# Absent stays absent, and "" counts as absent (#390). An unconditional write
# would clobber the secret config/test.exs pins with nil, and a blank value
# must never reach signature verification — Stripe.Webhook.construct_event
# happily HMACs with an empty key, so the webhook controller fails closed
# when this is unset. A billing-enabled prod instance without the secret
# cannot process a purchase or a clawback, so refuse to boot rather than let
# every webhook 400 quietly.
case System.get_env("STRIPE_WEBHOOK_SECRET") do
  blank when blank in [nil, ""] ->
    if config_env() == :prod and credits_enabled? do
      raise """
      CREDITS_ENABLED is set but STRIPE_WEBHOOK_SECRET is empty or unset.
      Set it to the signing secret of your Stripe webhook endpoint
      (Stripe dashboard → Developers → Webhooks).
      """
    end

  secret ->
    config :stripity_stripe, webhook_secret: secret
end

# Cents, whole or fractional. Fractional is the normal case for a per-message
# rate: AgentMail bills about $0.002 an email, which as a whole number of cents
# is zero, and the panel would report email as free.
parse_cents = fn var, raw ->
  trimmed = String.trim(raw)

  case Float.parse(trimmed) do
    {cents, ""} when cents >= 0 -> cents
    _ -> raise "#{var} must be a number of cents, 0 or more, got #{inspect(raw)}"
  end
end

provider_hourly_cents =
  case System.get_env("PROVIDER_HOURLY_CENTS") do
    value when value in [nil, ""] ->
      %{}

    value ->
      value
      |> String.split(",", trim: true)
      |> Map.new(fn pair ->
        case String.split(pair, "=", parts: 2) do
          [provider, cents] ->
            {String.trim(provider), parse_cents.("PROVIDER_HOURLY_CENTS", cents)}

          _ ->
            raise "PROVIDER_HOURLY_CENTS: #{inspect(pair)} is not provider=cents"
        end
      end)
  end

config :fountain, :provider_hourly_cents, provider_hourly_cents

# Which hours that rate multiplies. `active` (the default) is every hour a
# sandbox was awake, idle included. `turn` is only the hours with a prompt in
# flight, which is the closer match where a provider scales to near-zero
# between prompts. /admin/finance can switch between the two per view; this
# sets what it opens on. Anything unrecognised reads as `active`, because a
# typo must not quietly halve the reported bill.
config :fountain,
       :cost_basis,
       if(System.get_env("PROVIDER_COST_BASIS") == "turn", do: :turn, else: :active)

# Teammate contacts: what AgentMail charges per inbox per month, AgentPhone
# per number per month, and each of them per message. The monthly pair is
# pro-rated to whatever window the panel is showing; messages are counted from
# the `comms_*` usage events. Unset means unpriced, which the panel reports as
# `—` rather than as free.
contact_rate = fn var ->
  case System.get_env(var) do
    value when value in [nil, ""] -> nil
    value -> parse_cents.(var, value)
  end
end

config :fountain, :agentmail_inbox_cents, contact_rate.("AGENTMAIL_INBOX_CENTS")
config :fountain, :agentphone_number_cents, contact_rate.("AGENTPHONE_NUMBER_CENTS")
config :fountain, :agentmail_message_cents, contact_rate.("AGENTMAIL_MESSAGE_CENTS")
config :fountain, :agentphone_message_cents, contact_rate.("AGENTPHONE_MESSAGE_CENTS")

# Prepaid credits (ADR 0030): what the *customer* pays, in whole cents, as
# distinct from the provider costs above. CREDIT_TURN_HOUR_CENTS is one hour
# of turn time (default 25, a placeholder until #1038 gives a cost number).
# The four comms prices default to unset, and unset burns nothing: contacts
# bill nothing today and turning a price on is a price increase (#1042).
# CREDIT_PACKS_CENTS lists the packs a tenant can buy, e.g. "1000,2500,10000".
credit_cents = fn var ->
  case System.get_env(var) do
    value when value in [nil, ""] ->
      nil

    value ->
      case Integer.parse(String.trim(value)) do
        {cents, ""} when cents >= 0 -> cents
        _ -> raise "#{var} must be a whole number of cents, 0 or more, got #{inspect(value)}"
      end
  end
end

credit_packs =
  case System.get_env("CREDIT_PACKS_CENTS") do
    value when value in [nil, ""] ->
      [1_000, 2_500, 10_000]

    value ->
      value
      |> String.split(",", trim: true)
      |> Enum.map(fn cents ->
        case Integer.parse(String.trim(cents)) do
          {n, ""} when n > 0 -> n
          _ -> raise "CREDIT_PACKS_CENTS: #{inspect(cents)} is not a positive number of cents"
        end
      end)
      |> Enum.sort()
  end

# Per-turn host ceiling. Empty until runtime enforcement and later-turn/recovery
# ceiling checks are integrated. Never inherit an operator's shell policy in tests.
execution_limit_ceiling =
  if env == :test do
    %{}
  else
    case Fountain.Conversations.ExecutionLimits.from_json_env(
           System.get_env("FOUNTAIN_EXECUTION_LIMITS")
         ) do
      {:ok, limits} ->
        limits

      {:error, {:execution_limits_invalid, field}} ->
        raise "FOUNTAIN_EXECUTION_LIMITS is invalid: #{field}"
    end
  end

config :fountain, :execution_limit_ceiling, execution_limit_ceiling

# The deadline coordinator polls `turn_executions` on every node, so it starts
# only where there is something for it to expire: a configured host ceiling.
# An operator who sets a per-account ceiling without the host one sets this
# explicitly, which is the case the docs row names. `false` turns it off
# anywhere, without a rebuild, which is what an incident needs.
execution_deadline_worker =
  case System.get_env("FOUNTAIN_EXECUTION_DEADLINE_WORKER") do
    nil -> map_size(execution_limit_ceiling) > 0
    value when value in ~w(1 true TRUE yes) -> true
    value when value in ~w(0 false FALSE no) -> false
    value -> raise "FOUNTAIN_EXECUTION_DEADLINE_WORKER must be true or false, got: #{value}"
  end

config :fountain, :execution_deadline_worker_enabled, execution_deadline_worker

# How often it looks. Deadlines are absolute and durable, so lateness costs
# accuracy rather than correctness, and a second of it is not worth a poll per
# second per replica on a hot table.
config :fountain,
       :execution_deadline_interval_ms,
       String.to_integer(System.get_env("FOUNTAIN_EXECUTION_DEADLINE_INTERVAL_MS") || "5000")

# Concurrency (ADR 0031): the reserve one live sandbox needs in the balance,
# the per-account floor and ceiling the balance rule is clamped to, and the
# fleet ceiling — the most live sandboxes the deployment will run in total,
# which is the provider plan's number (Sprites' $20 plan allows about 20).
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

config :fountain, :sandboxes,
  reserve_cents: whole_number.("SANDBOX_RESERVE_CENTS", 200),
  cap_floor: whole_number.("SANDBOX_CAP_FLOOR", 2),
  cap_ceiling: whole_number.("SANDBOX_CAP_CEILING", 20),
  fleet_ceiling: whole_number.("SANDBOX_FLEET_CEILING", 20)

# The bounded sandbox-capacity queue (ADR 0042).
config :fountain,
  sandbox_queue_max_depth: whole_number.("SANDBOX_QUEUE_MAX_DEPTH", 10),
  sandbox_queue_max_wait_seconds: whole_number.("SANDBOX_QUEUE_MAX_WAIT_SECONDS", 3600)

# Teammate contacts one account may hold at once — an abuse ceiling.
config :fountain, :team_contact_ceiling, whole_number.("TEAM_CONTACT_CEILING", 10)

# Hosted Buzz agents one account may run at once — an abuse ceiling (#1017).
config :fountain_buzz, :buzz_identity_ceiling, whole_number.("BUZZ_IDENTITY_CEILING", 10)

config :fountain, :credits,
  # The opening grant a new account gets, and how many days it lasts.
  opening_cents: credit_cents.("CREDIT_OPENING_CENTS") || 500,
  opening_days: credit_cents.("CREDIT_OPENING_DAYS") || 14,
  turn_hour_cents: credit_cents.("CREDIT_TURN_HOUR_CENTS") || 25,
  number_cents: credit_cents.("CREDIT_NUMBER_CENTS"),
  inbox_cents: credit_cents.("CREDIT_INBOX_CENTS"),
  email_message_cents: credit_cents.("CREDIT_EMAIL_MESSAGE_CENTS"),
  sms_message_cents: credit_cents.("CREDIT_SMS_MESSAGE_CENTS"),
  packs_cents: credit_packs

# Claimable principals (ADR 0044). Defaults match config.exs; a deployment
# that opens none of these never has to set any of them.
config :fountain, Fountain.Principals,
  default_ttl_seconds: whole_number.("PRINCIPAL_DEFAULT_TTL_SECONDS", 86_400),
  max_ttl_seconds: whole_number.("PRINCIPAL_MAX_TTL_SECONDS", 604_800),
  max_grant_cents: whole_number.("PRINCIPAL_MAX_GRANT_CENTS", 500),
  max_outstanding_per_application: whole_number.("PRINCIPAL_MAX_OUTSTANDING", 500),
  max_created_per_hour: whole_number.("PRINCIPAL_MAX_PER_HOUR", 500),
  purge_after_days: whole_number.("PRINCIPAL_PURGE_AFTER_DAYS", 7)

# Platform inference keys (#1388, ADR 0038 decision 3, amending ADR 0008).
#
# Fountain runs a tenant's agent on one of these when the tenant has no
# credential of their own for the model's provider, and meters the tokens
# against their credit balance. The tenant's own credential always wins.
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

# The circuit breaker: the most this deployment's platform keys may cost in a
# UTC day, across every tenant together. A log line and a 503 when it is hit
# (`FountainWeb.FallbackController`), so one bad day cannot cost more than the
# number written here. It is measured from the `burn_inference` ledger rows,
# so it needs CREDITS_ENABLED=true and it lags the pricer's tick: it bounds
# the day, not the minute.
config :fountain,
       :platform_inference_daily_cents,
       whole_number.("PLATFORM_INFERENCE_DAILY_CENTS", 5_000)

# The deployment's ChatGPT grant for the codex runtime (ADR 0047), connected
# from /admin/inference. Fountain refreshes the access token this many seconds
# ahead of its expiry — it must exceed the longest turn the deployment expects,
# because codex cannot refresh in this mode and a turn that outlives the token
# fails at the proxy — and renews a grant nobody has used for this many days,
# so it never idles past the auth server's eight-day window.
config :fountain,
  platform_chatgpt_refresh_margin_seconds:
    whole_number.("PLATFORM_CHATGPT_REFRESH_MARGIN_SECONDS", 900),
  platform_chatgpt_keepalive_days: whole_number.("PLATFORM_CHATGPT_KEEPALIVE_DAYS", 6)

# Per-model inference rates, overriding the compiled card in
# `Fountain.Credits.InferenceRates`. One entry per comma:
#
#   PLATFORM_INFERENCE_RATES="anthropic/claude-opus-5:500:2500:50:625,openai/*:500:3000:50:500"
#
# Five colon-separated fields: `provider/model_id` (or `provider/*` for that
# provider's fallback), then input, output, cached-read and cached-write
# prices **in cents per million tokens**, which is the unit every provider
# publishes in. Decimals are allowed and are the point — OpenAI's cached
# input for gpt-5.3-codex is 17.5 cents per million tokens.
#
# The compiled card is list price with **no markup, a 1.0x margin**, and that
# is a decision (ADR 0038, noted on 0030 and 0031): Fountain's margin is
# sandbox time (CREDIT_TURN_HOUR_CENTS), and marking inference up would make
# the opening credit buy less of the one thing it was granted to buy. This
# variable exists so a price change does not need a deploy, not so a
# deployment can quietly add a margin — though a self-hoster reselling
# inference is welcome to.
inference_rates =
  case System.get_env("PLATFORM_INFERENCE_RATES") do
    value when value in [nil, ""] ->
      %{}

    value ->
      value
      |> String.split(",", trim: true)
      |> Map.new(fn entry ->
        cents_per_mtok = fn field ->
          case Float.parse(String.trim(field)) do
            {n, ""} when n >= 0 ->
              # Cents per billion tokens: the unit the rate card holds, so a
              # fraction of a cent per million tokens is still an integer.
              round(n * 1_000)

            _ ->
              raise "PLATFORM_INFERENCE_RATES: #{inspect(field)} is not a price in cents per million tokens"
          end
        end

        case String.split(String.trim(entry), ":") do
          [model, input, output, cache_read, cache_write] when model != "" ->
            {model,
             %{
               input: cents_per_mtok.(input),
               output: cents_per_mtok.(output),
               cache_read: cents_per_mtok.(cache_read),
               cache_write: cents_per_mtok.(cache_write)
             }}

          _ ->
            raise "PLATFORM_INFERENCE_RATES: #{inspect(entry)} is not " <>
                    "provider/model:input:output:cache_read:cache_write"
        end
      end)
  end

config :fountain, :inference_rates, inference_rates

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

  # Optional (#843): where "Report a problem" reports are forwarded besides
  # SUPPORT_EMAIL — a GitHub issue in this repo, created with this token
  # (needs `issues:write`). Unset, reports stay on the row and in the mail.
  #
  # Under `:fountain_support` rather than `:fountain` since #1528: these two
  # exist for the extension and nothing else, so a core-only release reads no
  # key for a feature it does not carry. SUPPORT_EMAIL above stays the host's,
  # because the account emails and the team-comms replies name it too.
  # Configuring an extension that is not installed is inert, not an error.
  config :fountain_support, :support_github_repo, System.get_env("SUPPORT_GITHUB_REPO")
  config :fountain_support, :support_github_token, System.get_env("SUPPORT_GITHUB_TOKEN")

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

  config :fountain, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

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
  if https? do
    config :fountain, :force_ssl,
      rewrite_on: [:x_forwarded_proto, :x_forwarded_host, :x_forwarded_port],
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
  # For Honeycomb specifically you can also set HONEYCOMB_API_KEY and the
  # exporter config below will wire it up automatically.
  #
  # OFF unless an export target is explicitly configured (#317): the exporter
  # used to default to :otlp aimed at api.honeycomb.io, so a self-hoster who
  # set none of these got continuous rejected span batches against a
  # third-party vendor plus exporter noise in the logs. The SDK still honours
  # OTEL_TRACES_EXPORTER itself (with higher precedence than this), so
  # export can be forced on or off either way.
  otel_configured? =
    Enum.any?(
      ~w(OTEL_EXPORTER_OTLP_ENDPOINT HONEYCOMB_ENDPOINT HONEYCOMB_API_KEY),
      &System.get_env/1
    )

  otel_endpoint =
    System.get_env("OTEL_EXPORTER_OTLP_ENDPOINT") ||
      System.get_env("HONEYCOMB_ENDPOINT", "https://api.honeycomb.io")

  # Parse "key=val,key2=val2" header strings produced by OTEL_EXPORTER_OTLP_HEADERS,
  # then layer on Honeycomb-specific headers if HONEYCOMB_API_KEY is set.
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

  otel_headers =
    case System.get_env("HONEYCOMB_API_KEY") do
      nil -> otel_headers
      key -> [{"x-honeycomb-team", key} | otel_headers]
    end

  config :opentelemetry,
    span_processor: :batch,
    traces_exporter: if(otel_configured?, do: :otlp, else: :none),
    resource: [
      {"service.name", System.get_env("OTEL_SERVICE_NAME", "fountain")},
      {"deployment.environment", System.get_env("FLY_APP_NAME", "prod")}
    ]

  config :opentelemetry_exporter,
    otlp_protocol: :http_protobuf,
    otlp_endpoint: otel_endpoint,
    otlp_headers: otel_headers
end

# The first-party extensions (ADR 0043). Naming a module here is the whole of
# Fountain's knowledge of it: `Fountain.Extensions` reads this list and reaches
# each one only through `Fountain.Extension` callbacks. Drop a line and the
# release serves none of that extension's routes, runs none of its jobs and
# applies none of its migrations — which is what a core distribution is
# (decision 7).
#
# A configured module that will not load is a bad deploy and
# `Fountain.Extensions.validate!/0` refuses to boot on it, on purpose.
#
# The whole extension list, for every environment, in ONE declaration —
# `config :fountain, :extensions` replaces the key rather than appending, so two
# declarations would silently delete one another. That is not hypothetical: it
# happened in #1507, where a second declaration deleted every fixture extension
# `config/test.exs` installs and the seam's own tests measured an empty list.
#
# Each extension is installed *where it loads*. `apps/fountain` deliberately
# depends on no sibling app, so `mix test` run from there — which is what CI's
# partition script does — has neither `:fountain_buzz` nor `:fountain_support`
# on the code path, and naming them unconditionally would make
# `Fountain.Extensions.validate!/0` refuse to boot every partition. That check
# working exactly as intended, on a configuration that is wrong for that run.
#
# `Code.ensure_loaded?/1` can only answer that after compilation, which is why
# this lives here and not in `config/test.exs`: that file is evaluated before
# the apps are built, where the answer is always false.
installed_extensions =
  Enum.filter(
    [FountainBuzz.Extension, FountainSupport.Extension],
    &Code.ensure_loaded?/1
  )

# Fixture extensions prove the seam without a real one (#1505). They are named
# here rather than set per test because `:extensions` is global application
# state and a test that wrote it would collide with every async test in the VM
# (#1214); tests vary the fixture, not the configuration.
#
# The misbehaving ones each fail for a single conversation id, which is what
# makes them safe to install beside the others and what lets the isolation tests
# exercise the real fan-out rather than a copy of its logic.
extension_fixtures =
  if config_env() == :test do
    [
      Fountain.ExtensionFixtures.Enabled,
      Fountain.ExtensionFixtures.Disabled,
      Fountain.ExtensionFixtures.Silent,
      Fountain.ExtensionFixtures.Exploding,
      Fountain.ExtensionFixtures.WrongShape
    ]
  else
    []
  end

config :fountain, :extensions, installed_extensions ++ extension_fixtures

# The Buzz extension's own configuration, under its own otp_app, and only what
# an operator overrides. Where its binaries live is `FountainBuzz.Assets`'s to
# know (#1509) — a core release's configuration has no business naming a path
# only the bundled image has — so these exist to be *overridden* and default to
# nothing here.
#
# The harness's ACP child (`fountain acp`) talks back to THIS server, so its
# base URL defaults to the loopback endpoint: no egress, no TLS, no dependence
# on PUBLIC_URL resolving inside the pod.
if config_env() == :prod do
  config :fountain_buzz,
         :fountain_cli_path,
         System.get_env("FOUNTAIN_CLI_PATH", "/usr/local/bin/fountain")

  config :fountain_buzz,
         :buzz_acp_base_url,
         System.get_env("BUZZ_ACP_BASE_URL") ||
           "http://127.0.0.1:#{System.get_env("PORT", "4000")}"

  # Only when set. An unset BUZZ_ACP_PATH means "wherever the image installed
  # it", which FountainBuzz.Assets answers.
  if path = System.get_env("BUZZ_ACP_PATH") do
    config :fountain_buzz, :buzz_acp_path, path
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

# ── PostHog: feature flags and product analytics ──────────────────────────
#
# One project API key serves both halves. `Fountain.FeatureFlags` reads it to
# evaluate per-user flags; `Fountain.Analytics` reads it to send product
# events. Neither does anything without it, so an instance that sets no key
# evaluates no flags and sends nothing.
#
# ── Feature flags ─────────────────────────────────────────────────────────
#
# Per-user flags are evaluated by PostHog (`Fountain.FeatureFlags`) when a
# project API key is set; the module caches answers and falls back to the
# last one it got when PostHog is unreachable, and to "off" when it has
# none — an outage never turns a feature on. FEATURE_FLAGS_ON is the
# no-PostHog path: a comma-separated list of flag keys forced on for every
# user (a self-hoster, or dev). Read in every env.
# Set only when present, so config/test.exs keeps its own value.
case System.get_env("POSTHOG_PROJECT_API_KEY") do
  blank when blank in [nil, ""] -> :ok
  key -> config :fountain, :posthog_project_api_key, key
end

config :fountain,
       :posthog_host,
       System.get_env("POSTHOG_HOST", "https://us.i.posthog.com")

config :fountain,
       :feature_flag_overrides,
       "FEATURE_FLAGS_ON"
       |> System.get_env("")
       |> String.split(",", trim: true)
       |> Enum.map(&String.trim/1)
       |> Enum.reject(&(&1 == ""))
       |> Map.new(&{&1, true})

# ── Product analytics ─────────────────────────────────────────────────────
#
# `Fountain.Analytics` captures product events into the same PostHog project
# the flags come from. On whenever a key is set; POSTHOG_CAPTURE=false keeps
# flag evaluation and turns capture off, for a deployment that wants one
# without the other.
#
# POSTHOG_PERSON_PII=false drops the account email from person properties,
# leaving the user id — which is all the audit trail stores either. The
# events themselves never carry PII: no secret values, no prompts, no agent
# output (`Fountain.Analytics.sanitize/1`).
#
# POSTHOG_INSTANCE names this deployment. Every event is associated with it
# as a PostHog group, so a hosted instance and a self-hoster reporting into
# one project stay separable. Defaults to PHX_HOST.
config :fountain,
       :analytics_enabled,
       System.get_env("POSTHOG_CAPTURE", "true") not in ~w(false 0 no off)

config :fountain,
       :analytics_person_pii,
       System.get_env("POSTHOG_PERSON_PII", "true") not in ~w(false 0 no off)

# POSTHOG_BROWSER_CAPTURE=false stops the public pages (landing, legal, the
# manual, the auth flow) loading posthog-js, leaving the server-side capture
# untouched. The console never loads it either way.
#
# The snippet is what makes visitors countable at all: a server-side pageview
# has no session, no referrer and no device, and `Fountain.Analytics` drops
# events with no subject — so before it, nobody who was not signed in was
# counted anywhere. The off-switch exists because loading a third-party script
# into a visitor's browser is a different decision from sending product events
# from a server, and a self-hoster is entitled to make them separately.
config :fountain,
       :analytics_browser_capture,
       System.get_env("POSTHOG_BROWSER_CAPTURE", "true") not in ~w(false 0 no off)

case System.get_env("POSTHOG_INSTANCE") || System.get_env("PHX_HOST") do
  blank when blank in [nil, ""] -> :ok
  name -> config :fountain, :analytics_instance, name
end

# ── Teammate email + phone (flag `team_comms`) ───────────────────────────
#
# Fountain holds the AgentMail and AgentPhone keys; a teammate gets an inbox
# and a number under them, and reaches both through MCP tools Fountain serves
# (`Fountain.Team.Comms`). The keys never enter a sandbox. Unset, the feature
# reports itself unavailable even when the flag is on.
# Keys are set only when present, so config/test.exs keeps its own values.
case System.get_env("AGENTMAIL_API_KEY") do
  blank when blank in [nil, ""] -> :ok
  key -> config :fountain, :agentmail_api_key, key
end

config :fountain,
       :agentmail_base_url,
       System.get_env("AGENTMAIL_BASE_URL", "https://api.agentmail.to")

# Optional: a verified custom domain for teammate inboxes; unset uses
# AgentMail's shared domain.
config :fountain, :agentmail_domain, System.get_env("AGENTMAIL_DOMAIN")

case System.get_env("AGENTPHONE_API_KEY") do
  blank when blank in [nil, ""] -> :ok
  key -> config :fountain, :agentphone_api_key, key
end

config :fountain,
       :agentphone_base_url,
       System.get_env("AGENTPHONE_BASE_URL", "https://api.agentphone.ai")

# The signing secret AgentPhone issued for this instance's master webhook
# (POST /v1/webhooks → `secret`), which verifies POST /api/webhooks/agentphone.
# Unset, the endpoint answers 503 and no inbound text becomes a prompt.
case System.get_env("AGENTPHONE_WEBHOOK_SECRET") do
  blank when blank in [nil, ""] -> :ok
  secret -> config :fountain, :agentphone_webhook_secret, secret
end
