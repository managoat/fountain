defmodule FountainWeb.Router do
  @moduledoc false
  use FountainWeb, :router

  ## ─── Pipelines ──────────────────────────────────────────────────────────────────────────────────

  # Public JSON — spec rendering, health, public auth endpoints
  pipeline :api_public do
    plug :accepts, ["json"]
    plug FountainWeb.Plugs.PutApiSpec, module: FountainWeb.ApiSpec
  end

  # Authenticated API — TenantAPIAuth gate for all resource endpoints.
  #
  # Content negotiation is deliberately NOT part of this pipeline. Every
  # authenticated route pipes through `:accepts_json` as well, except the SSE
  # stream, which cannot: a real EventSource client sends
  # `Accept: text/event-stream`, and `plug :accepts, ["json"]` refuses that with
  # 406 before the action ever runs. Keeping the auth chain in one pipeline
  # means the stream route cannot drift out of it — a second copy of these
  # plugs would be one forgotten line away from an unauthenticated endpoint.
  pipeline :api do
    plug FountainWeb.Plugs.PutApiSpec, module: FountainWeb.ApiSpec
    # A coarse pre-auth ceiling protects the lookup work (#316). It is ten
    # key budgets, so one key using its allowance does not exhaust a shared
    # ingress address (#1771). Every attempt counts toward this ceiling.
    plug FountainWeb.Plugs.RateLimit, bucket: "api", max: 6_000
    # Refused authentication has its own 600/min address bucket inside auth;
    # it cannot consume a valid key's allowance.
    plug FountainWeb.Plugs.TenantAPIAuth
    # Authenticated clients keep independent 600/min budgets per replica.
    plug FountainWeb.Plugs.RateLimit, bucket: "api-key", max: 600, key: :api_key
    plug FountainWeb.Plugs.Audit
  end

  pipeline :accepts_json do
    plug :accepts, ["json"]
  end

  # As tight as the current asset setup allows: the root layout runs Tailwind
  # and Phoenix/LiveView/d3 off CDNs and carries large inline scripts and
  # onclick handlers, so script-src needs 'unsafe-inline' plus the two CDN
  # hosts (a nonce scheme can't cover inline event handlers). That means this
  # CSP does NOT block javascript: URLs — Managoat.Docs.Markdown filters those
  # at render time (#323). What it does pin down: no framing, no <object>,
  # no off-origin form posts, fetch/websocket restricted to self + the LV
  # socket, images to self + the data: URLs the image picker and avatars use.
  #
  # This is the console's policy, and it names no PostHog origin — the console
  # loads no analytics script (`FountainWeb.Plugs.WebAnalytics`), so it has no
  # business permitting one. The public pages, which do load it, get those two
  # origins appended at runtime by that same plug: `POSTHOG_HOST` is read in
  # `config/runtime.exs`, so a compile-time entry here would carry whatever
  # the *build* saw — for a release, nothing — and would block every
  # self-hosted PostHog behind a header that looked correct in the source.
  @csp [
         "default-src 'self'",
         "base-uri 'self'",
         "frame-ancestors 'self'",
         "form-action 'self'",
         "object-src 'none'",
         "img-src 'self' data:",
         "style-src 'self' 'unsafe-inline'",
         "script-src 'self' 'unsafe-inline' https://cdn.tailwindcss.com https://cdn.jsdelivr.net",
         "connect-src 'self' ws: wss:"
       ]
       |> Enum.join("; ")

  # Base browser pipeline — session, flash, CSRF, secure headers
  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {FountainWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers, %{"content-security-policy" => @csp}
    # After the policy is set: widens img-src with the brand bundle's origin
    # (BRAND_ASSETS_URL), which is read at runtime and so cannot be in @csp.
    plug FountainWeb.Plugs.BrandAssets
    # After :fetch_session — it reads the session on both sides of the
    # request to spot a sign-in. On every browser route on purpose: the merge
    # has to happen wherever a session is established, and five controllers do
    # that today.
    plug FountainWeb.Plugs.AnalyticsIdentity
  end

  # Public browser routes (login, register, verify) — no auth check
  pipeline :browser_public do
    # intentionally empty; inherits :browser
  end

  # The public, unauthenticated surface: the landing and legal pages, the
  # manual, and the auth flow. The only routes that load the PostHog browser
  # snippet — see FountainWeb.Plugs.WebAnalytics for why the console does not.
  pipeline :public_analytics do
    plug FountainWeb.Plugs.WebAnalytics
  end

  # Authenticated browser routes — loads current_user from session
  pipeline :browser_authenticated do
    plug FountainWeb.Plugs.TenantSessionAuth
  end

  # Optional browser auth — loads current_user if session exists, no redirect if absent
  pipeline :browser_optional_auth do
    plug FountainWeb.Plugs.OptionalSessionAuth
  end

  # Layered on top of :api for routes that manage API keys themselves.
  pipeline :require_key_management do
    plug FountainWeb.Plugs.RequireKeyManagement
  end

  # Layered on top of :api for account-level writes. Same rule as
  # :require_key_management, wider remit: a leaked per-conversation sprite token
  # must not be able to replace the tenant's inference credentials any more than
  # it can mint a second API key.
  pipeline :require_full_scope do
    plug FountainWeb.Plugs.RequireFullScope
  end

  # Layered on top of :api + :require_full_scope for the operator surface.
  pipeline :require_admin_api do
    plug FountainWeb.Plugs.RequireAdminApi
  end

  ## ─── Public routes ────────────────────────────────────────────────────────────────────

  scope "/", FountainWeb do
    pipe_through :api_public
    # Liveness: static. Readiness: checks the dependencies this instance cannot
    # serve without. See FountainWeb.HealthController for why they are separate.
    get "/health", HealthController, :show
    get "/health/ready", HealthController, :ready
  end

  # llms.txt convention (https://llmstxt.org/) + external SKILL.md for agentic IDEs.
  # No pipeline: plain-text GETs with no auth, no CSRF, no session. The
  # controller sets `text/plain; charset=utf-8` explicitly.
  scope "/", FountainWeb do
    get "/llms.txt", LlmsController, :index
    get "/llms-full.txt", LlmsController, :full
    get "/skill", LlmsController, :skill
    get "/skills/fountain/SKILL.md", LlmsController, :skill
  end

  scope "/api" do
    pipe_through :api_public
    get "/openapi.json", OpenApiSpex.Plug.RenderSpec, []
    get "/docs", OpenApiSpex.Plug.SwaggerUI, path: "/api/openapi.json"
  end

  ## ─── Public browser routes ────────────────────────────────────────────────────────────────────────

  # Marketing landing page + legal pages — public, auth-aware nav for logged-in users
  scope "/", FountainWeb do
    pipe_through [:browser, :browser_optional_auth, :public_analytics]
    get "/", MarketingController, :home
    get "/launch", MarketingController, :launch
    get "/oss-launch", MarketingController, :oss_launch
    get "/buzz-launch", MarketingController, :buzz_launch
    get "/integrations", MarketingController, :integrations
    get "/built-with", MarketingController, :built_with
    get "/self-hosted", MarketingController, :self_hosted
    get "/faq", MarketingController, :faq
    get "/code-review-bot", MarketingController, :code_review_bot
    # One study today, so the bare path redirects to it rather than 404ing on
    # the segment a reader will inevitably chop off the URL.
    get "/case-studies", MarketingController, :case_studies
    get "/case-studies/self-healing-infrastructure", MarketingController, :case_study
    get "/terms", MarketingController, :terms
    get "/privacy", MarketingController, :privacy
    # The public manual, and since #1008 the only place it is published —
    # content embedded at compile time by Fountain.Docs. Distinct from /help
    # (curated in-app topics) and /api/docs (Swagger).
    get "/docs", DocsController, :show
    get "/docs/*page", DocsController, :show
  end

  # Multi-tenant auth routes (no session auth required)
  scope "/auth", FountainWeb do
    pipe_through [:browser, :public_analytics]

    get "/login", SessionController, :new
    post "/login", SessionController, :create
    get "/logout", SessionController, :delete

    get "/register", RegistrationController, :new
    post "/register", RegistrationController, :create
    get "/check-email", RegistrationController, :check_email

    get "/resend-verification", RegistrationController, :resend_form
    post "/resend-verification", RegistrationController, :resend

    get "/forgot-password", PasswordResetController, :forgot_form
    get "/reset/:token", PasswordResetController, :reset_form
    post "/reset", PasswordResetController, :reset

    # Ueberauth OAuth routes
    get "/oauth/:provider", UeberauthController, :request
    get "/oauth/:provider/callback", UeberauthController, :callback
  end

  # Email verification (token in path)
  scope "/users", FountainWeb do
    pipe_through [:browser, :public_analytics]
    get "/confirm/:token", EmailVerificationController, :confirm
  end

  # ── Unverified waiting room (#533) ────────────────────────────────────────────────────────────────
  # Deliberately NOT behind :browser_authenticated. That plug now redirects
  # unverified sessions here, so routing this page through it would make it
  # redirect to itself. :require_pending_verification is the whole gate: it
  # sends a session-less visitor to login, tolerates an unverified session —
  # the only gate in the app that does — and bounces a verified one out so the
  # page cannot be camped on. layout: false because the app chrome reads
  # sidebar assigns only :require_authenticated_user sets.
  scope "/", FountainWeb do
    pipe_through :browser

    live_session :verify_pending,
      layout: false,
      on_mount: [{FountainWeb.Live.Hooks, :require_pending_verification}] do
      live "/auth/verify-pending", VerifyPendingLive, :index
    end
  end

  # Email-change confirmation (#448) — public like /users/confirm: the link
  # lands from an inbox, possibly in a browser with no session.
  scope "/account", FountainWeb do
    pipe_through :browser
    get "/email/confirm/:token", AccountSecurityController, :confirm_email_change
  end

  # OAuth 2.0 consent page (#818): the browser half of Fountain as an
  # authorization server for its own apps. Optional session auth — the
  # controller stashes the request and sends a signed-out user to login.
  scope "/oauth", FountainWeb do
    pipe_through [:browser, :browser_optional_auth]

    get "/authorize", OAuthAuthorizeController, :show
    post "/authorize", OAuthAuthorizeController, :create
  end

  ## ─── Public JSON auth endpoints ───────────────────────────────────────────────────────────────────────

  scope "/api/auth", FountainWeb do
    pipe_through :api_public

    post "/token", AuthTokenController, :create

    # Device authorization (#1305): the CLI login path for accounts that have
    # no password ("Sign up with GitHub"). Unauthenticated by design — the
    # approval happens in a signed-in browser at /device; rate-limited in the
    # controller.
    post "/device", DeviceAuthController, :create
    post "/device/token", DeviceAuthController, :token

    post "/register", RegistrationController, :api_create
    post "/resend-verification", RegistrationController, :api_resend
    post "/forgot", PasswordResetController, :api_forgot

    # Completions (#522). Authenticated by the emailed token itself, so an
    # account can be activated and a password reset without a browser. The
    # links in the mail keep pointing at the browser routes above.
    post "/verify", EmailVerificationController, :api_verify
    post "/reset", PasswordResetController, :api_reset
    post "/email/confirm", AccountSecurityController, :api_confirm_email_change
  end

  ## ─── Stripe webhook (credit packs, ADR 0031) ───────────────────────────────────────────────────────────
  # No TenantAPIAuth: authenticated via Stripe-Signature header verification.
  # Must be reachable by Stripe's servers without a bearer token.

  scope "/api/stripe", FountainWeb do
    pipe_through :api_public
    post "/webhook", StripeWebhookController, :create
  end

  # AgentPhone's master webhook (flag `team_comms`): inbound texts to a
  # teammate's number become prompts. Same shape as Stripe's — no bearer
  # token, authenticated by the HMAC signature in the request.
  scope "/api/webhooks", FountainWeb do
    pipe_through :api_public
    post "/agentphone", AgentPhoneWebhookController, :create
  end

  # Outbound webhooks (#700) — the ones Fountain *sends*. Declared after the
  # inbound AgentPhone route above so its literal path is matched first; a
  # `/:id` segment would otherwise swallow "agentphone". Full scope, like key
  # management: a sandbox's per-conversation token must not be able to point
  # the account's lifecycle events at a URL of its choosing.
  scope "/api/webhooks", FountainWeb do
    pipe_through [:accepts_json, :api, :require_full_scope]

    get "/", WebhookEndpointController, :index
    post "/", WebhookEndpointController, :create
    get "/:id", WebhookEndpointController, :show
    patch "/:id", WebhookEndpointController, :update
    delete "/:id", WebhookEndpointController, :delete
    post "/:id/rotate-secret", WebhookEndpointController, :rotate
    post "/:id/test", WebhookEndpointController, :test
    get "/:id/deliveries", WebhookEndpointController, :deliveries
    post "/:id/deliveries/:delivery_id/redeliver", WebhookEndpointController, :redeliver
  end

  ## ─── Authenticated JSON resource endpoints ──────────────────────────────────────────────────────────────

  scope "/api/auth", FountainWeb do
    pipe_through [:accepts_json, :api]

    get "/me", AuthMeController, :show
  end

  # OAuth token endpoint (#818): unauthenticated by design — the code, the
  # PKCE verifier and the exact redirect_uri are the proof; rate-limited in
  # the controller. Revoke needs the token it revokes.
  scope "/api/oauth", FountainWeb do
    pipe_through :api_public
    post "/token", OAuthTokenController, :token
  end

  scope "/api/oauth", FountainWeb do
    pipe_through [:accepts_json, :api]
    post "/revoke", OAuthTokenController, :revoke
  end

  # OAuth clients an account registers for itself (#1125). Full scope because
  # a client is a standing path to a full-scope key after consent.
  scope "/api/oauth", FountainWeb do
    pipe_through [:accepts_json, :api, :require_full_scope]

    get "/clients", OAuthClientController, :index
    post "/clients", OAuthClientController, :create
    get "/clients/:id", OAuthClientController, :show
    patch "/clients/:id", OAuthClientController, :update
    delete "/clients/:id", OAuthClientController, :delete
  end

  # Key management is scope-gated: the per-conversation token a sprite holds
  # must not be able to mint a second key that survives conversation teardown.
  scope "/api/auth", FountainWeb do
    pipe_through [:accepts_json, :api, :require_key_management]

    get "/api-keys", ApiKeyController, :index
    post "/api-keys", ApiKeyController, :create
    delete "/api-keys/:id", ApiKeyController, :delete
  end

  # Claimable principals (ADR 0044): the anonymous tenants an application opens
  # for visitors who have no account yet. Full scope on every route, which is
  # what keeps a principal out of its own grant surface — a `principal`-scoped
  # key cannot open a second principal, enumerate anyone else's, claim itself,
  # or release the grant that bounds it.
  #
  # `/:id/claim` is declared before `/:id` so a literal segment is never read
  # as a grant id.
  scope "/api/claimable-users", FountainWeb do
    pipe_through [:accepts_json, :api, :require_full_scope]

    post "/", ClaimableUserController, :create
    post "/:id/claim", ClaimableUserController, :claim
    get "/:id", ClaimableUserController, :show
    delete "/:id", ClaimableUserController, :delete
  end

  # Self-hosted runners (ADR 0022). Full scope: a sandbox's per-conversation
  # token must not be able to attach a machine that then runs the account's
  # agents. `/ws` is the daemon's WebSocket; it authenticates like any other
  # /api route (bearer key) and upgrades in the controller.
  scope "/api/runners", FountainWeb do
    pipe_through [:accepts_json, :api, :require_full_scope]

    get "/", RunnerController, :index
    delete "/:id", RunnerController, :delete
  end

  # Connections (#1178): the provider accounts the tenant has signed in to.
  # Full scope: a conversation-scoped token must not be able to list or cut
  # the account's connections. Connecting one needs a browser and a session,
  # so it is not an API operation — `GET /api/connections/providers` says
  # where to send the owner.
  scope "/api/connections", FountainWeb do
    pipe_through [:accepts_json, :api, :require_full_scope]

    get "/", ConnectionController, :index
    get "/providers", ConnectionController, :providers
    get "/:id", ConnectionController, :show
    delete "/:id", ConnectionController, :delete
  end

  # Connection providers (#1186): where a tenant's connections get their
  # tokens — their own OAuth app, or a discovered MCP authorization server.
  # Full scope: a provider holds a client secret and names where a token goes.
  scope "/api/connection-providers", FountainWeb do
    pipe_through [:accepts_json, :api, :require_full_scope]

    get "/", ConnectionProviderController, :index
    post "/", ConnectionProviderController, :create
    get "/:id", ConnectionProviderController, :show
    patch "/:id", ConnectionProviderController, :update
    delete "/:id", ConnectionProviderController, :delete
    post "/:id/discover", ConnectionProviderController, :discover
  end

  # Secret bindings (ADR 0019 gate 1b). Full scope for the same reason as
  # runners: a conversation-scoped token must not be able to redirect the
  # account's credentials to another host.
  scope "/api/secret-bindings", FountainWeb do
    pipe_through [:accepts_json, :api, :require_full_scope]

    get "/", SecretBindingController, :index
    get "/presets", SecretBindingController, :presets
    post "/", SecretBindingController, :create
    patch "/:id", SecretBindingController, :update
    delete "/:id", SecretBindingController, :delete
  end

  # What left the sandbox through the egress broker (ADR 0019 gate 4). Full
  # scope, like the bindings that put the credentials there: the log names
  # which secrets went to which host, and a sandbox's per-conversation token
  # must not be able to map another conversation's traffic (#1152).
  scope "/api/conversations/:conversation_id", FountainWeb do
    pipe_through [:accepts_json, :api, :require_full_scope]

    get "/egress", ConversationController, :egress, as: :conversation_egress
  end

  # A sandbox's disk, read-only (ADR 0039): a listing, a file, `git status`
  # and `git diff`.
  # Full scope for the same reason as the egress log: a sandbox's own
  # `sprite` token must not read another sandbox of the tenant, whose disk
  # was built from a different vault.
  scope "/api/sandboxes/:sandbox_id", FountainWeb do
    pipe_through [:accepts_json, :api, :require_full_scope]

    get "/files", SandboxFilesController, :index, as: :sandbox_files
    get "/file", SandboxFilesController, :show, as: :sandbox_file
    get "/diff", SandboxFilesController, :diff, as: :sandbox_diff

    # `git-status`, not `status`: a sandbox already has a `status` of its own
    # (`ready`, `suspended`), and that is what a caller reading the route
    # would expect back from it.
    get "/git-status", SandboxFilesController, :git_status, as: :sandbox_git_status
  end

  # The daemon's socket skips content negotiation like the SSE routes do: a
  # WebSocket client sends no JSON `Accept`, and the upgrade is not a JSON
  # response.
  scope "/api/runners", FountainWeb do
    pipe_through [:api, :require_full_scope]

    get "/ws", RunnerController, :connect
  end

  # Credential changes (#521) — same gate, same reason: a conversation-scoped
  # sprite token must not be able to rotate the account password or start an
  # email change. Both require the current password on top of the bearer token.
  scope "/api/auth", FountainWeb do
    pipe_through [:accepts_json, :api, :require_full_scope]

    post "/password", AccountSecurityController, :api_change_password
    post "/email", AccountSecurityController, :api_request_email_change
  end

  # Account-level configuration. Inference credentials are what a conversation
  # actually runs on, so a sprite token replacing them is the same class of
  # escalation as minting an API key — hence the full-scope gate (#518).
  scope "/api/account", FountainWeb do
    pipe_through [:accepts_json, :api, :require_full_scope]

    # Billing self-serve (#524). The controller lives in ee/ with the rest of
    # billing; the route has to be here, like the Stripe webhook above.
    get "/billing", CreditsApiController, :show
    post "/billing/credits/checkout", CreditsApiController, :credits_checkout

    # Export and deletion (#523). Deletion is irreversible and takes the
    # tenant key with it, so it wants the strongest credential the account has.
    post "/exports", AccountDataController, :create_export
    get "/exports", AccountDataController, :index_exports
    get "/exports/:id", AccountDataController, :show_export
    get "/exports/:id/download", AccountDataController, :download_export
    delete "/", AccountDataController, :delete_account

    get "/onboarding", OnboardingController, :show
    post "/onboarding/complete", OnboardingController, :complete

    get "/inference-credentials", InferenceCredentialController, :index
    put "/inference-credentials/:provider", InferenceCredentialController, :update
    delete "/inference-credentials/:provider", InferenceCredentialController, :delete

    # The named sets behind those three, which write the default one
    # (ADR 0053 decision 1).
    get "/inference-credential-sets", InferenceCredentialSetController, :index
    post "/inference-credential-sets", InferenceCredentialSetController, :create
    patch "/inference-credential-sets/:id", InferenceCredentialSetController, :update
    delete "/inference-credential-sets/:id", InferenceCredentialSetController, :delete

    # The per-set write, on the controller that owns the provider ping and
    # its three distinguishable outcomes rather than a second copy of them.
    put "/inference-credential-sets/:id/credentials/:provider",
        InferenceCredentialController,
        :update_in_set

    delete "/inference-credential-sets/:id/credentials/:provider",
           InferenceCredentialController,
           :delete_in_set
  end

  # The team's SSE stream (#810). Declared before the JSON team routes so
  # `/team/stream` is not swallowed by `/team/:agent_id`; no `:accepts_json`
  # for the same reason as the conversation stream below.
  scope "/api", FountainWeb do
    pipe_through :api

    get "/team/stream", TeamController, :stream, as: :team_stream
    # Every conversation of the caller on one connection (#813).
    get "/events/stream", EventsController, :stream, as: :events_stream
  end

  scope "/api", FountainWeb do
    pipe_through [:accepts_json, :api]

    # The tenant's own trail (#526). Cross-tenant listing is an admin concern.
    get "/audit", AuditController, :index

    # Full-text search across the caller's conversations (#826).
    get "/search", SearchController, :index

    # The team tools a teammate's sandbox calls to see and message the team (#851).
    post "/mcp/team/:conversation_id", TeamMcpController, :handle

    # MCP tools a teammate's sandbox calls to use its email address and phone
    # number (flag `team_comms`). Same transport; the AgentMail/AgentPhone
    # keys stay server-side.
    post "/mcp/team-comms/:conversation_id", TeamCommsMcpController, :handle

    # The Gmail tools for a Google connection the conversation's agent names
    # (#1178). Same transport; the Google token stays server-side.
    post "/mcp/gmail/:conversation_id/:connection_id", GmailMcpController, :handle

    # The tools a chat-completions / AG-UI client defined on its request,
    # served back to that conversation's sandbox (#1202). A call parks until
    # the client answers it with a `role: "tool"` message.
    post "/mcp/caller/:conversation_id", CallerMcpController, :handle

    resources "/environments", EnvironmentController, except: [:new, :edit] do
      resources "/secrets", SecretController, only: [:index, :create, :delete]
    end

    resources "/vaults", VaultController, except: [:new, :edit] do
      patch "/secrets/:id", VaultSecretController, :update
      resources "/secrets", VaultSecretController, only: [:index, :create, :delete]
    end

    resources "/agents", AgentController, except: [:new, :edit]

    # The bounded sandbox-capacity queue (ADR 0042). Read and cancel only:
    # work enters it through `POST /api/conversations` with `queue: true`, or
    # through a teammate schedule's own cron firing.
    get "/sandbox-queue", SandboxQueueController, :index
    get "/sandbox-queue/:id", SandboxQueueController, :show
    delete "/sandbox-queue/:id", SandboxQueueController, :delete
    # Config history (ADR 0029, #1051): read-only. Rollback stays a console action.
    get "/agents/:id/versions", AgentVersionController, :index
    get "/agents/:id/versions/:version", AgentVersionController, :show
    # The form vocabulary and the avatar generator, for clients that build
    # the agent/environment forms elsewhere (#815).
    get "/catalog", CatalogController, :show
    post "/avatars/generate", AvatarGenerateController, :create

    # Bulk apply for compiled fountain.yml manifests (`fountain apply`).
    post "/apply", ApplyController, :create

    # The team (#810): the roster `/team` shows, for clients that are not this
    # web app. Every action wraps Fountain.Team.
    get "/team", TeamController, :index
    post "/team", TeamController, :create
    # Before `/team/:agent_id`, or "schedules" would be read as an agent id.
    get "/team/schedules", TeamScheduleController, :index_all
    # Likewise before `/team/:agent_id`: can teammates here get an email
    # address and phone number (flag `team_comms`)?
    get "/team/comms", TeamController, :comms_status
    get "/team/:agent_id", TeamController, :show
    patch "/team/:agent_id", TeamController, :update
    delete "/team/:agent_id", TeamController, :delete
    post "/team/:agent_id/messages", TeamController, :message
    # The teammate's history (#832): every conversation it has had on the team.
    get "/team/:agent_id/conversations", TeamController, :conversations
    # A fresh conversation on the same computer; the current one is retired.
    post "/team/:agent_id/conversations", TeamController, :fresh_conversation
    # The teammate's own email address and phone number (flag `team_comms`).
    post "/team/:agent_id/contact", TeamController, :provision_contact
    patch "/team/:agent_id/contact", TeamController, :update_contact
    delete "/team/:agent_id/contact", TeamController, :release_contact

    # Team schedules (#825): the routines `/team` offers, per teammate.
    get "/team/:agent_id/schedules", TeamScheduleController, :index
    post "/team/:agent_id/schedules", TeamScheduleController, :create
    get "/team/:agent_id/schedules/:id", TeamScheduleController, :show
    patch "/team/:agent_id/schedules/:id", TeamScheduleController, :update
    delete "/team/:agent_id/schedules/:id", TeamScheduleController, :delete
    post "/team/:agent_id/schedules/:id/run", TeamScheduleController, :run

    # Problem reports (#843) used to be declared here. They are the
    # `fountain_support` extension's now (ADR 0043, #1528): `/api/support` is a
    # mount, dispatched at the end of this same pipeline, and a core-only
    # release serves none of it.

    # The machines conversations run on (ADR 0023 gate 3). Read-only: a
    # sandbox is made by creating a conversation and reused by naming it as
    # `sandbox_id` on the next one.
    get "/sandboxes", SandboxController, :index
    get "/sandboxes/:id", SandboxController, :show
    delete "/sandboxes/:id", SandboxController, :delete

    resources "/conversations", ConversationController, only: [:index, :show, :create, :delete] do
      post "/prompts", ConversationController, :prompt, as: :prompt
      post "/reapply", ConversationController, :reapply, as: :reapply
      post "/interrupt", ConversationController, :interrupt, as: :interrupt
      post "/terminate", ConversationController, :terminate, as: :terminate
      get "/turns", ConversationController, :turns, as: :turns
      # The JSON read-model for the log feed; /stream below is the tail (#519).
      get "/events", ConversationController, :events, as: :events
      post "/read", ConversationController, :read, as: :read
      # Labels (#1637). Not behind :require_full_scope on purpose: the point
      # of the route is that a sandbox stamps its own conversation.
      # `Conversations.set_conversation_labels/4` is what refuses a sandbox
      # token naming a different one, and it is the door the team message and
      # a channel resume write through as well — the two other places a
      # request can change a conversation's labels.
      patch "/labels", ConversationController, :labels, as: :labels
      # Answer a permission request the agent is blocked on (#940). Nested so
      # the conversation is tenant-scoped before the request id is looked at.
      post "/requests/:request_id", ConversationController, :answer_request, as: :answer_request
      get "/tree", ConversationController, :tree, as: :tree
    end
  end

  # Image bytes over a bearer token. Outside the :accepts_json scope for the
  # same reason the SSE route is: a client fetching an image sends
  # `Accept: image/*`, which `plug :accepts, ["json"]` would refuse with 406
  # before the action ran. The JSON responses on the write paths are explicit,
  # so nothing here depends on negotiation.
  #
  # Avatars (#528) were written here from the start. Turn images were not —
  # they sat in the :accepts_json conversations scope and 406'd on
  # `Accept: image/png` until #578 moved them here, which is also what let
  # them be specced: one action per route, so `:api_show` can carry an
  # operation without dragging the browser route into the spec with it.
  scope "/api", FountainWeb do
    pipe_through :api

    get "/agents/:id/avatar", AgentAvatarController, :api_show
    put "/agents/:id/avatar", AgentAvatarController, :api_update
    delete "/agents/:id/avatar", AgentAvatarController, :api_delete

    get "/conversations/:conversation_id/turns/:turn_id/images/:position",
        TurnImageController,
        :api_show
  end

  # Server-sent events. Same auth chain as the rest of /api, minus content
  # negotiation — see the `:api` pipeline. The action sets its own
  # `text/event-stream` content-type and its error paths go through
  # FallbackController's `json/2`, which does not consult the negotiated
  # format, so there is nothing here for `:accepts` to decide.
  scope "/api", FountainWeb do
    pipe_through :api

    get "/conversations/:conversation_id/stream", ConversationController, :stream,
      as: :conversation_stream

    # AG-UI. Here rather than in the JSON scope for the same reason:
    # the request body is JSON but the *response* is an event stream, and an
    # AG-UI client sends `Accept: text/event-stream`, which `:accepts_json`
    # would refuse with 406 before the action ran.
    post "/agui/:agent_id", AguiController, :run, as: :agui_run
  end

  # OpenAI-compatible (ADR 0035). At `/v1`, not `/api/v1`, because every
  # base-URL client and gateway appends `/chat/completions` and `/models` to
  # whatever it is given, and `https://host/v1` is the shape they all expect.
  # Same auth chain as `/api`, no content negotiation for the same reason as
  # the stream above: `stream: true` answers as an event stream.
  scope "/v1", FountainWeb do
    pipe_through :api

    post "/chat/completions", OpenAIController, :create_chat_completion
    get "/models", OpenAIController, :list_models
    get "/models/:model", OpenAIController, :show_model
  end

  # Operator surface (#527). Three gates in order: :api authenticates the key,
  # :require_full_scope keeps a sandbox's per-conversation token out, and
  # :require_admin_api demands the role — the bearer-token analogue of
  # Live.Hooks.require_admin.
  scope "/api/admin", FountainWeb do
    pipe_through [:accepts_json, :api, :require_full_scope, :require_admin_api]

    get "/users", AdminController, :index_users
    get "/users/:id", AdminController, :show_user
    post "/users/:id/role", AdminController, :set_role
    post "/users/:id/sandbox-limit", AdminController, :set_sandbox_limit
    post "/users/:id/comp", AdminController, :set_comp
    post "/users/:id/credits", AdminController, :grant_credits
    post "/users/:id/suspend", AdminController, :set_suspended
    delete "/users/:id", AdminController, :delete_user

    get "/sandboxes", AdminController, :index_sandboxes
    post "/sandboxes/:id/reap", AdminController, :reap_sandbox

    get "/audit", AdminController, :index_audit
    get "/events", AdminController, :index_admin_events
  end

  ## ─── Authenticated browser / LiveView routes ──────────────────────────────────────────────────────────────────

  scope "/", FountainWeb do
    pipe_through [:browser, :browser_authenticated]

    # ── Theme preference — CSRF-protected, session-authenticated ─────────────────────────────────────────
    patch "/api/settings/theme", SettingsController, :update_theme

    # ── Avatar serving — tenant-scoped image endpoint ─────────────────────────────────────────────────────
    get "/agents/:id/avatar", AgentAvatarController, :show

    # ── Account data export download — owner-scoped, expiring artifact (#288) ─────────────────────────────
    get "/account/exports/:id/download", ExportController, :download

    # ── Credential management (#448) — controller POSTs so the session can be
    # re-issued after a password change and RateLimit applies; the page they
    # POST from is AccountSecurityLive below ─────────────────────────────────
    post "/account/security/password", AccountSecurityController, :change_password
    post "/account/security/email", AccountSecurityController, :request_email_change

    # ── Connections (#1178): the OAuth round trip to a provider. Session-
    # authenticated so the grant lands on the signed-in account; the page
    # they start from is ConnectionsLive below ───────────────────────────
    get "/connections/:provider/start", ConnectionsController, :start
    get "/connections/:provider/callback", ConnectionsController, :callback

    # ── The pages that moved out (#867) ───────────────────────────────────────
    # Conversations and the team roster are their own apps on the API now, and
    # onboarding is the dashboard's own first-run guidance. These paths are in
    # sent emails, filed issues, agents' skills and bookmarks, so they redirect
    # rather than 404. `/conversations/new` is declared before `/:id` or "new"
    # reads as a conversation id.
    get "/conversations", MovedController, :conversations
    get "/conversations/new", MovedController, :new_conversation
    get "/conversations/:id", MovedController, :conversation
    get "/conversations/:id/:logs", MovedController, :conversation
    get "/team", MovedController, :team
    get "/team/:agent_id", MovedController, :team
    get "/onboarding", MovedController, :onboarding
    get "/onboarding/:step", MovedController, :onboarding

    # ── The console ───────────────────────────────────────────────────────────
    # What Fountain's own UI is for: the account, its keys and credentials, and
    # the three primitives a conversation runs on. No billing gate — an
    # account at zero can still read and manage what it has, and the gate that
    # protects spend is in the context (ADR 0031), not here.
    live_session :authenticated,
      on_mount: [{FountainWeb.Live.Hooks, :require_authenticated_user}] do
      # The verified landing (ADR 0038): a key, one request, the reply. Where
      # `GET /users/confirm/:token` sends a person, and where the welcome
      # email points. The dashboard is what they get afterwards.
      live "/start", StartLive, :index
      live "/dashboard", DashboardLive.Index, :index
      live "/agents", AgentsLive.Index, :index
      live "/agents/new", AgentsLive.Form, :new
      live "/agents/:id/edit", AgentsLive.Form, :edit
      live "/agents/:id/versions", AgentsLive.Versions, :index
      live "/environments", EnvironmentsLive.Index, :index
      live "/environments/new", EnvironmentsLive.Form, :new
      live "/environments/:id/edit", EnvironmentsLive.Form, :edit
      live "/vaults", VaultsLive.Index, :index
      live "/vaults/new", VaultsLive.Form, :new
      live "/vaults/:id/edit", VaultsLive.Form, :edit
      live "/audit", AuditLive.Index, :index
      live "/api-keys", ApiKeysLive.Index, :index
      # Device-authorization approval (#1305): where `fountain auth login
      # --device` sends the human. Authenticated so the key lands on the
      # signed-in account.
      live "/device", DeviceLive, :index
      live "/help", HelpLive.Show, :index
      live "/help/:topic", HelpLive.Show, :show

      # ── Account page: data export + deletion (#479) ────────────────────────────────────────
      live "/account", Live.AccountLive, :index

      # ── Credits: account/billing. Redirects to /account when billing is disabled ────────────
      live "/account/billing", Live.CreditsLive, :index

      # ── BYO inference credentials (ADR 0008) ───────────────────────────────────────────────
      live "/account/inference-credentials", InferenceCredentialsLive.Index, :index

      # ── Self-hosted runners (ADR 0022) ─────────────────────────────────────────────────────
      live "/account/runners", RunnersLive.Index, :index

      # ── OAuth apps the account registered for itself (#1125) ───────────────────────────────
      live "/account/oauth-apps", OAuthClientsLive.Index, :index

      # ── Secret bindings at the egress broker (ADR 0019 gate 1b) ────────────────────────────
      live "/account/bindings", SecretBindingsLive.Index, :index

      # ── Connections: provider accounts Fountain holds the credential for (#1178) ────────────
      live "/account/connections", ConnectionsLive.Index, :index

      # ── Outbound webhooks (#700) ───────────────────────────────────────────────────────────
      live "/account/webhooks", WebhooksLive.Index, :index

      # ── Credential management (#448) ───────────────────────────────────────────────────────
      live "/account/security", AccountSecurityLive, :index
    end

    live_session :admin,
      on_mount: [
        {FountainWeb.Live.Hooks, :require_authenticated_user},
        {FountainWeb.Live.Hooks, :require_admin}
      ] do
      # One section per page. `/admin` was a single LiveView stacking all of
      # these, whose mount and 10s refresh ran every query behind every
      # section no matter which one was on screen.
      live "/admin", AdminLive.Index, :index
      live "/admin/users", AdminLive.Users, :index
      live "/admin/sandboxes", AdminLive.Sandboxes, :index
      live "/admin/inference", AdminLive.Inference, :index
      live "/admin/broker", AdminLive.Broker, :index
      live "/admin/activity", AdminLive.Activity, :index
      # Lives in ee/ with the rest of billing (#472): it is a revenue page.
      live "/admin/finance", Live.AdminFinanceLive, :index
      live "/admin/users/:id", AdminLive.UserDetail, :show
      live "/admin/conversations/:id", AdminLive.ConversationDetail, :show
    end
  end

  ## ─── Extension API surface (ADR 0043, #1505) ────────────────────────────────────────────────────────

  # Whatever an installed extension serves under /api/<its prefix>. Declared
  # LAST, after every core route including the browser scope's
  # `/api/settings/theme`, because Phoenix matches in declaration order: an
  # extension therefore cannot shadow a core path, and this plug only ever sees
  # a request core routing had no answer for.
  #
  # Inside the ordinary `:api` pipeline on purpose. The rate limit,
  # TenantAPIAuth and the request audit run before the extension's plug does,
  # so there is no prefix an extension can pick that reaches it without the
  # host having authenticated the caller and assigned current_user. An
  # extension gets a mount point, not a door of its own.
  #
  # `/api/<unknown>` reaches here too and answers 404 JSON rather than raising
  # NoRouteError. That is the intended trade: one unmatched-path behaviour for
  # the whole authenticated API, and no way for a client to learn from a status
  # code which optional extensions a deployment installed.
  scope "/api" do
    pipe_through [:accepts_json, :api]

    forward "/", FountainWeb.Plugs.ExtensionDispatch
  end

  ## ─── Dev dashboard ──────────────────────────────────────────────────────────────────────────────────

  if Application.compile_env(:fountain, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through [:browser]
      live_dashboard "/dashboard", metrics: FountainWeb.Telemetry
    end
  end
end
