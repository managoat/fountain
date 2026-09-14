defmodule Fountain.Analytics do
  @moduledoc """
  Product analytics: what people do with Fountain, captured into PostHog.

  This is the *product* sink, and it is the third of three that already
  existed and kept answering different questions:

    * `Fountain.Audit` — who changed what, kept forever, tenant-visible. A
      compliance record, not a metric.
    * `Fountain.Billing.record_usage/5` — what to charge for. A closed set of
      event types, shaped by the invoice.
    * OTel spans / `Fountain.Telemetry` — how the machine is behaving.

  None of them answers "did the people who verified last week come back", so
  the funnel was hand-rolled in SQL (`Fountain.Funnel`) and everything past
  the funnel was unanswerable. This module sends the same events PostHog can
  slice, retain and cohort without anyone writing a query first.

  ## The events come from choke points, not from call sites

  The same argument the audit trail makes (ADR 0013): a call site that has to
  remember to instrument is a call site that will not. Every event below is
  emitted from a function that *already* had to be called for the thing to
  have happened, so a new door onto an existing action is instrumented by
  construction:

  | Choke point | Events |
  |---|---|
  | `Fountain.Audit.record/1` | every audited mutation, under its own action name (`agent.created`, `vault.secret.write`, …), plus `api.request` for the `:api` pipeline's request log |
  | `Fountain.Billing.record_usage/5` | `usage.sandbox_provisioned`, `usage.turn_started`, `usage.sandbox_terminated`, … |
  | `Fountain.Conversations.publish_stage/4` | `conversation.turn.done` and the other outcome stages webhooks already subscribe to |
  | `FountainWeb.Live.Hooks` | `$pageview` for the console |
  | `Fountain.FeatureFlags` | `$feature_flag_called`, plus `$feature/<key>` on every other event |

  Adding an instrumented action means adding an audit call — which the
  guardrail test already requires — and nothing else.

  ## It is best-effort, and it is off by default

  `capture/4` casts to `Fountain.Analytics.Sink` and returns `:ok` before any
  HTTP happens. Nothing here can slow down, fail, or roll back the operation
  it describes; a full queue drops events and says so in telemetry rather
  than growing without bound.

  With no `POSTHOG_PROJECT_API_KEY` the whole module is inert — a self-hoster
  who never sets one sends nothing, ever. When a key *is* set it is the
  operator's own PostHog project, which is also why person properties carry
  the account's email by default; `POSTHOG_PERSON_PII=false` turns that off
  and leaves the user id, which is what the audit trail stores anyway.

  ## What is deliberately not sent

    * **Secret values, env var values, prompts and agent output.** The audit
      rule (never record values, only keys and sizes) is the same rule here,
      and `sanitize/1` enforces it on anything arriving from audit metadata.
    * **Per-chunk conversation output.** A chatty turn writes thousands of
      stdout events; the same reason `Fountain.Webhooks.Events` refuses to
      dispatch `kind: "output"` applies to a capture endpoint.
    * **Anonymous events.** An event with no user is dropped rather than
      given a synthetic id, so PostHog person counts mean accounts. The
      browser snippet on the public pages does send anonymous events — that
      is the only way a visitor who has no account can be counted at all —
      but under `person_profiles: "identified_only"`, so it does not mint a
      person either. See `FountainWeb.Plugs.WebAnalytics`.

  ## The browser half

  Everything above is captured on the server. It cannot answer anything about
  a *visitor*: a synthesised `$pageview` has no session, no referrer and no
  device, and the rule directly above means nobody who is not signed in
  appears at all. `browser_config/0` and `FountainWeb.Plugs.WebAnalytics` put
  posthog-js on the public pages for exactly that, and `alias_anonymous/2`
  joins the two halves when someone signs in. The console stays server-only —
  ADR 0028 and `FountainWeb.Live.Hooks` say why.
  """

  require Logger

  alias Fountain.Analytics.Sink
  alias Fountain.Accounts.User

  @typedoc "Anything that can name the person an event belongs to."
  @type subject :: User.t() | %{id: String.t()} | String.t() | nil

  @lib "fountain-elixir"

  # PostHog group analytics, one group type: the deployment. Every event
  # carries it, so a hosted instance and a self-hoster reporting into the same
  # project stay separable, and instance-level properties (version, provider
  # mix) can be set once instead of on every person.
  @group_type "instance"

  ## Public API

  @doc """
  Whether capture is on: a project API key is configured and
  `POSTHOG_CAPTURE` has not turned it off.

  `Fountain.FeatureFlags.configured?/0` answers the same question for the
  *flag* half of the same key — an operator can evaluate flags without
  sending product events, but not the other way round.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    Fountain.FeatureFlags.configured?() and
      Application.get_env(:fountain, :analytics_enabled, true) != false
  end

  @doc """
  Capture one event for one person.

  `subject` is a `%User{}`, a user id, or `nil`; a `nil` subject with no
  `:distinct_id` option is dropped (see the moduledoc). Returns `:ok` in
  every case, including when analytics is off — callers are choke points on
  the hot path and must never branch on this.

  ## Options

    * `:distinct_id` — override the person id (the only way to capture for a
      subject that is not a user row, e.g. a boot-time instance event).
    * `:timestamp` — event time; defaults to now, which matters because the
      sink batches.
    * `:request_ip` — the *end user's* IP, forwarded as `$ip` so PostHog
      geolocates the person rather than the deployment. Omitting it sets
      `$geoip_disable` instead; PostHog reads a missing `$ip` as "use the
      address this batch came from", which is not the same as "unknown".
    * `:set` / `:set_once` — person properties to merge on this event.
    * `:groups` — extra group associations beyond the instance group.
  """
  @spec capture(String.t(), subject(), map(), keyword()) :: :ok
  def capture(event, subject, properties \\ %{}, opts \\ [])

  def capture(event, subject, properties, opts) when is_binary(event) do
    with true <- enabled?(),
         id when is_binary(id) <- distinct_id(subject, opts) do
      Sink.enqueue(payload(event, id, properties, opts))
    else
      _ -> :ok
    end
  rescue
    # A capture that raises must not take the operation with it. This is the
    # same contract `Audit.record/1` keeps, for the same reason.
    e ->
      Logger.warning("analytics: capture #{event} failed: #{inspect(e)}")
      :ok
  end

  @doc """
  Send the account's current shape to PostHog as person properties.

  Called wherever the shape changes in a way a cohort would care about
  (registration, verification, onboarding, a credit event), not on
  every request — person property writes are the expensive half of ingestion
  and the properties only change on those events.
  """
  @spec identify(subject(), map()) :: :ok
  def identify(subject, extra \\ %{})

  def identify(%{__struct__: User} = user, extra) do
    capture("$identify", user, %{},
      set: Map.merge(person_properties(user), extra),
      set_once: set_once_properties(user)
    )
  end

  def identify(_subject, _extra), do: :ok

  @doc """
  Associate the deployment group with its current properties.

  Sent once per boot from `Fountain.Analytics.Sink`; group properties are
  last-write-wins, so a rolling deploy converges on the new version.
  """
  @spec identify_instance(map()) :: :ok
  def identify_instance(properties \\ %{}) do
    capture(
      "$groupidentify",
      nil,
      %{
        "$group_type" => @group_type,
        "$group_key" => instance(),
        "$group_set" => Map.merge(instance_properties(), properties)
      },
      distinct_id: "instance:#{instance()}"
    )
  end

  @doc """
  Merge the browser's anonymous person into an account that just signed in.

  The public pages (`FountainWeb.Plugs.WebAnalytics`) capture with posthog-js
  under a generated anonymous id, so everything a visitor did before they had
  an account — landing, reading the manual, reaching the register form — is
  recorded against a person nothing later connects to them. Signing in is the
  moment that connection becomes knowable, and this is where it is made:
  PostHog merges the anonymous person *into* the identified one, so the
  pre-signup pageviews join the account's history and the acquisition funnel
  has a top.

  Done from the server rather than by calling `posthog.identify()` in the
  browser, because the pages a person lands on *after* signing in are the
  console, and the console ships no snippet (`FountainWeb.Live.Hooks`). The
  anonymous id is read out of posthog-js's own cookie by
  `FountainWeb.Plugs.AnalyticsIdentity`, which is the only thing on the server
  that ever sees it.

  A no-op when the two ids are the same, when there is no anonymous id, or
  when the visitor arrived with no PostHog cookie at all (an ad blocker, a
  first request that skipped every public page, a direct API sign-in).
  """
  @spec alias_anonymous(subject(), String.t() | nil) :: :ok
  def alias_anonymous(subject, anon_distinct_id)

  def alias_anonymous(_subject, blank) when blank in [nil, ""], do: :ok

  def alias_anonymous(subject, anon_distinct_id) when is_binary(anon_distinct_id) do
    case distinct_id(subject, []) do
      ^anon_distinct_id ->
        :ok

      id when is_binary(id) ->
        capture("$identify", id, %{"$anon_distinct_id" => anon_distinct_id})

      _ ->
        :ok
    end
  end

  def alias_anonymous(_subject, _anon), do: :ok

  @doc """
  What the browser snippet needs, or `nil` when there is to be no snippet.

  The same project key the server sends with — one project, one person per
  account, so a visitor's anonymous pageviews and their account's server-side
  events land somewhere they can be joined (`alias_anonymous/2`). Returns
  `nil` unless capture is on *and* `POSTHOG_BROWSER_CAPTURE` allows it: a
  self-hoster who wants server-side product events without loading a
  third-party script into their users' browsers sets that to false and keeps
  everything else.
  """
  @spec browser_config() :: %{required(:api_key) => String.t(), optional(atom()) => any()} | nil
  def browser_config do
    key = Application.get_env(:fountain, :posthog_project_api_key)

    if enabled?() and browser_capture?() and is_binary(key) and key != "" do
      host = host()
      %{api_key: key, api_host: host, assets_host: assets_host(host)}
    end
  end

  defp browser_capture?,
    do: Application.get_env(:fountain, :analytics_browser_capture, true) != false

  defp host, do: Application.get_env(:fountain, :posthog_host, "https://us.i.posthog.com")

  @doc """
  Where posthog-js itself is served from, given the ingestion host.

  PostHog Cloud serves ingestion from `<region>.i.posthog.com` and static
  assets from `<region>-assets.i.posthog.com` — the snippet on posthog.com
  hardcodes both — while a self-hosted instance serves both from one origin.
  Deriving it keeps `POSTHOG_HOST` the single thing an operator sets, and
  keeps the CSP entry (`FountainWeb.Router`) honest for cloud and self-host
  alike.
  """
  @spec assets_host(String.t()) :: String.t()
  def assets_host(host) when is_binary(host) do
    case Regex.run(~r{^(https?://)([a-z0-9-]+)\.i\.posthog\.com/?$}i, host) do
      [_, scheme, region] -> "#{scheme}#{region}-assets.i.posthog.com"
      _ -> String.trim_trailing(host, "/")
    end
  end

  @doc """
  The origins the browser snippet talks to, for `FountainWeb.Router`'s CSP.

  Always the configured pair, whether or not capture is on: the header is one
  shared policy and naming an origin no page loads from costs nothing, while
  recomputing the policy when a key appears would mean a CSP that depends on
  runtime state a cached response may not share.
  """
  @spec browser_origins() :: [String.t()]
  def browser_origins do
    host = host()

    [String.trim_trailing(host, "/"), assets_host(host)]
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  # A context action name: dotted, lowercase, closed vocabulary
  # (`agent.created`, `team.member.added`). Anything else arriving from
  # the audit trail is the `:api` pipeline's request-log row, which is named
  # after the request line and carries a UUID.
  @context_action ~r/^[a-z][a-z0-9_]*(\.[a-z0-9_]+)+$/

  # The two surfaces a person mints an API key from. Everything else is a
  # credential the system issued itself.
  @human_actors ~w(ui api)

  @doc """
  Whether an audited action belongs in PostHog.

  The audit trail and a product analytics stream want different things, and
  mirroring one into the other wholesale was wrong in two ways that a day of
  production data made obvious (2,160 audit rows in 24 hours).

  ## The request log is not a product event

  ADR 0013 §4 keeps a **second** row for every API mutation, written by the
  `:api` pipeline plug and named after the request line
  (`POST /api/conversations/<uuid>/read`). It answers "what was attempted",
  including for requests that were refused, which is what an access log is
  for. The semantic row for the same mutation (`conversation.created`) is
  already captured, so nothing is lost by declining the second one.

  What would be lost by keeping it is the event taxonomy. Those names embed
  resource ids: **73 distinct action names in one day**, every one of which
  PostHog registers as its own event definition. A product vocabulary has to
  be closed, and `@context_action` is that fence.

  ## A credential the system issued itself is not a product event

  `api_key.created` and `api_key.revoked` were **1,513 of those 2,160 rows —
  70% of the entire trail**. Not one carried a human actor: 534 `self`
  (the context default, which OAuth token issuance takes — a Fountain OAuth
  token *is* an API key, ADR 0021), 445 `system:conversation_server`, 341
  `system:buzz_harness`, 193 `system:buzz_boot_sweep`. Those are sprite
  credentials minted and revoked per conversation and per harness boot. They
  say how busy the machine is, which is a telemetry question, and they would
  have drowned every real signal in the project.

  A person minting a key in the console or through the API is genuine product
  usage and is kept: both call sites pass `FountainWeb.Audited.attribution/2`,
  so they arrive as `ui` or `api`.

  This filter never touches what is *audited*. The trail keeps every row.
  """
  @spec product_event?(String.t(), String.t() | nil) :: boolean()
  def product_event?(action, actor) when is_binary(action) do
    cond do
      not Regex.match?(@context_action, action) -> false
      String.starts_with?(action, "api_key.") -> actor in @human_actors
      true -> true
    end
  end

  def product_event?(_action, _actor), do: false

  # The `:api` pipeline's request-log row, whose action is a request line:
  # "POST /api/agents/:id". `FountainWeb.Plugs.Audit` builds it from the
  # matched route pattern, so the tail is bounded by the router.
  @api_request ~r{^(GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS) (/\S*)$}

  @doc """
  Split an `:api` pipeline request-log action into `{method, route}`.

  `product_event?/2` refuses these rows and gives the reason: their *names*
  are request lines, and one PostHog event definition per route — per uuid,
  before `FountainWeb.Plugs.Audit` started recording the pattern — is
  unbounded cardinality in the one taxonomy every reader of the project
  shares: the event picker, autocomplete, and anyone trying to learn the
  vocabulary.

  That argument is about the name, and only the name. It was read as "API
  traffic does not belong in PostHog", which left the product with no answer
  to "which endpoints does anyone actually call", "is the SDK erroring", or
  "did that release change the shape of API usage" — questions the audit rows
  had the data for all along.

  So the row still becomes an event; it becomes **one** event,
  `api.request`, with the route as a *property*. Cardinality moves from the
  event definition, which is shared, to a property value, where PostHog is
  built to break down by it and the router bounds the set. One name, one
  definition, and `route`, `method` and `status` are the three breakdowns that
  answer all three questions.

  ADR 0028's Correction section retracts a stronger claim this docstring and
  ADR 0025 both used to make — that a definition is permanent, and that PostHog
  never removes one. The retired request-line definitions left the taxonomy
  about a day after their last event. The cost is paid while they exist, which
  is reason enough; it is not paid forever.

  Returns `:error` for anything that is not a request line, which is every
  semantic context action.
  """
  @spec api_request(String.t()) :: {:ok, {String.t(), String.t()}} | :error
  def api_request(action) when is_binary(action) do
    case Regex.run(@api_request, action) do
      [_, method, route] -> {:ok, {method, route}}
      _ -> :error
    end
  end

  def api_request(_action), do: :error

  @doc """
  Person properties derived from a user row.

  Everything here is a fact about the *account*, never about its content:
  no agent names, no vault keys, no conversation text.
  """
  @spec person_properties(User.t()) :: map()
  def person_properties(%{__struct__: User} = user) do
    %{
      "role" => user.role,
      "comped" => user.comped,
      "credit_balance_cents" => user.credit_balance_cents,
      "email_verified" => not is_nil(user.email_verified_at),
      "onboarded" => not is_nil(user.onboarding_completed_at),
      "suspended" => not is_nil(user.suspended_at),
      "max_concurrent_sandboxes" => Fountain.Quotas.sandbox_limit_for(user),
      "sandbox_limit_override" => user.sandbox_limit_override,
      "has_stripe_customer" => not is_nil(user.stripe_customer_id)
    }
    |> with_pii(user)
  end

  # The email is the only field here PostHog does not need and a person
  # browsing the project *will* see. It goes to the operator's own project
  # and makes a person searchable by the address support was contacted from,
  # which is why it defaults on — but a deployment that would rather hold
  # pseudonymous persons sets POSTHOG_PERSON_PII=false and loses nothing else.
  defp with_pii(props, user) do
    if Application.get_env(:fountain, :analytics_person_pii, true) != false do
      Map.merge(props, %{"email" => user.email, "$email" => user.email})
    else
      props
    end
  end

  defp set_once_properties(%{__struct__: User} = user) do
    %{"signed_up_at" => iso(user.inserted_at)}
  end

  @doc """
  Strip an audit/metering metadata map down to what may leave the building.

  Audit metadata is already values-free by rule (ADR 0013), so this is a
  second fence rather than the first: it drops anything that is not a scalar,
  truncates long strings, and refuses keys that name a secret even though
  none should reach it.
  """
  @spec sanitize(map() | nil) :: map()
  def sanitize(nil), do: %{}

  def sanitize(metadata) when is_map(metadata) do
    metadata
    |> Enum.flat_map(fn {k, v} ->
      key = to_string(k)

      cond do
        secretish?(key, v) -> []
        scalar?(v) -> [{key, truncate(v)}]
        is_list(v) -> [{key, length(v)}]
        is_map(v) -> [{key, map_size(v)}]
        true -> []
      end
    end)
    |> Map.new()
  end

  def sanitize(_), do: %{}

  @secretish ~w(value secret token password key credential prompt content body output)

  # Only strings are refused. A count, a byte size or a boolean under one of
  # these names — `value_bytes`, `secret_count`, `has_token` — is exactly the
  # shape the audit trail is required to record instead of the value, so
  # dropping it here would throw away the safe half of the convention and
  # leave the events unable to say how big anything was.
  defp secretish?(key, value) when is_binary(value) do
    down = String.downcase(key)
    Enum.any?(@secretish, &String.contains?(down, &1))
  end

  defp secretish?(_key, _value), do: false

  defp scalar?(v), do: is_binary(v) or is_number(v) or is_boolean(v) or is_atom(v)

  defp truncate(v) when is_binary(v) and byte_size(v) > 200,
    do: binary_part(v, 0, 200) <> "…"

  defp truncate(v) when is_atom(v) and not is_boolean(v) and not is_nil(v), do: to_string(v)
  defp truncate(v), do: v

  ## Payload construction

  defp payload(event, distinct_id, properties, opts) do
    %{
      event: event,
      distinct_id: distinct_id,
      timestamp: opts |> Keyword.get(:timestamp, DateTime.utc_now()) |> DateTime.to_iso8601(),
      properties:
        properties
        |> Map.new(fn {k, v} -> {to_string(k), v} end)
        |> Map.merge(base_properties(distinct_id, opts))
        |> maybe_put("$set", Keyword.get(opts, :set))
        |> maybe_put("$set_once", Keyword.get(opts, :set_once))
    }
  end

  defp base_properties(distinct_id, opts) do
    %{
      "$lib" => @lib,
      "$lib_version" => version(),
      "$groups" => Map.merge(%{@group_type => instance()}, Keyword.get(opts, :groups, %{})),
      "environment" => env()
    }
    |> Map.merge(location(Keyword.get(opts, :request_ip)))
    |> Map.merge(feature_flag_properties(distinct_id))
  end

  # Where the person is, or an explicit statement that we do not know.
  #
  # This used to send `"$ip" => nil` and call that "no location". It is not:
  # PostHog fills a missing or null `$ip` from the address the batch arrived
  # from — which, for a sink that flushes from a pod, is the deployment's
  # egress address — and then geolocates that. It put **every one of 108
  # pageviews in a single city** in the Fountain project, which is the exact
  # failure the old comment believed it was preventing.
  #
  # `$geoip_disable` is the documented way to say "do not enrich this event",
  # and it is what the server SDKs set by default. So: forward the real client
  # address when the caller has one (any request-scoped capture), and suppress
  # enrichment when it does not (a boot event, a background sweep, a metering
  # row written by a worker). An unknown location is now absent rather than
  # wrong, and a wrong one cannot come back by omission.
  defp location(ip) when is_binary(ip) and ip != "", do: %{"$ip" => ip}
  defp location(_), do: %{"$geoip_disable" => true}

  # `$feature/<key>` is what makes "did the flagged cohort behave differently"
  # answerable in PostHog without re-deriving the flag at query time. Read from
  # the FeatureFlags ETS cache only — a cache miss means no HTTP and no
  # properties, because an analytics event must never be the thing that makes
  # a flag lookup happen.
  defp feature_flag_properties(distinct_id) do
    case Fountain.FeatureFlags.cached_flags(distinct_id) do
      flags when map_size(flags) > 0 ->
        Map.new(flags, fn {key, value} -> {"$feature/#{key}", value} end)

      _ ->
        %{}
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, empty) when map_size(empty) == 0, do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp distinct_id(nil, opts), do: Keyword.get(opts, :distinct_id)
  defp distinct_id(%{id: id}, _opts) when is_binary(id), do: id
  defp distinct_id(id, _opts) when is_binary(id), do: id
  defp distinct_id(_, opts), do: Keyword.get(opts, :distinct_id)

  ## Configuration

  @doc false
  def instance do
    Application.get_env(:fountain, :analytics_instance) ||
      System.get_env("PHX_HOST") || "localhost"
  end

  defp instance_properties do
    %{
      "name" => instance(),
      "version" => version(),
      "environment" => env(),
      "sandbox_providers" =>
        Enum.map_join(Fountain.SandboxProviders.enabled_providers(), ",", &to_string/1)
    }
  rescue
    _ -> %{"name" => instance(), "version" => version(), "environment" => env()}
  end

  # Baked at compile time on purpose: `Mix.env/0` does not exist in a release,
  # and the build env is the fact we want anyway ("what was this image built
  # as"), not whatever a runtime caller happens to be doing.
  @env to_string(Mix.env())

  defp env, do: @env

  defp version do
    case Application.spec(:fountain, :vsn) do
      nil -> "unknown"
      vsn -> to_string(vsn)
    end
  end

  defp iso(nil), do: nil
  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp iso(%NaiveDateTime{} = dt), do: NaiveDateTime.to_iso8601(dt)
  defp iso(other), do: to_string(other)
end
