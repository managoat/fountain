defmodule Site.Pages do
  @moduledoc """
  The pages, and the data they render.

  Moved from `FountainWeb.MarketingHTML` in the fountain repo, where the same
  templates were rendered per request. Everything the app read at request
  time is a constant here (`Site.Brand`); the rest of the
  module was literal data already.
  """
  use Phoenix.Component
  import Site.Icons, only: [mark: 1]

  embed_templates("pages/*")

  @doc """
  The homepage's section mark: a short accent rule and a one-word label.

  The page is ten sections of argument and every one of them used to open with
  the same centred `text-2xl` heading, so nothing told a reader which section
  they had landed in or how far through they were. The label is navigational
  rather than a claim, which is why it is one word wherever one word will do.

  The rule is the page's only repeated ornament. It carries `--color-accent`,
  which appears nowhere clickable, so it reads as a mark rather than a link.

  `tone` picks the palette: `:page` on the light sections and inside the
  case-study panel, whose warm ground `--color-accent-ink` also reads on, and
  `:ink` on the two dark ones.
  """
  attr(:label, :string, required: true)
  attr(:tone, :atom, default: :page)
  attr(:align, :atom, default: :center)
  attr(:class, :string, default: nil)

  def eyebrow(assigns) do
    ~H"""
    <p class={[
      "flex items-center gap-3 text-xs font-semibold uppercase tracking-[0.18em]",
      @align == :center && "justify-center",
      @tone == :ink && "text-[var(--color-accent)]",
      @tone == :page && "text-[var(--color-accent-ink)]",
      @class
    ]}>
      <span class="h-px w-6 shrink-0 bg-[var(--color-accent)]" aria-hidden="true"></span>
      {@label}
    </p>
    """
  end

  @doc """
  The homepage's build sequence: three document annotations, apply, then call.

  The first three beats annotate one `---`-separated manifest. Keeping their
  source as individual documents lets each annotation stay attached to the
  document it explains while `apply_example/0` renders the file the reader
  actually writes.

  `nil` for `:n` is the connector, which is unnumbered because applying the
  file is not one of the three templates and is not the call either.

  Every key in the YAML is one the CLI reads. `manifest.go` decodes a
  `---`-separated file document by document, and `fountain apply` reconciles
  these three kinds and no others (`docs/cli.md`). `op://` is a documented
  secret-manager reference, which is what lets the manifest be committed
  rather than carry a plaintext token on a public page.

  The Agent is named `reviewer` because that is the agent `sdk_example/0`
  starts in the last beat. Renaming it here means renaming it there.

  The Vault beat says what the record is, when to attach it, and that it is
  optional. The collision with HashiCorp is stated once on this page, in the
  "Whose token does it push with?" card below, where the longer distinction
  belongs.
  """
  def build_steps do
    [
      %{
        n: 1,
        title: "Describe the machine once.",
        body:
          "Repositories, packages, env vars, setup scripts. Write it in the " <>
            "console, or keep it in git.",
        code: """
        # fountain.yml
        apiVersion: fountain.dev/v1
        kind: Environment
        metadata:
          name: app
        spec:
          repositories:
            - url: https://github.com/acme/app
              mount_path: /work/app
              secret_key: GITHUB_TOKEN
          setup_script: cd /work/app && npm install\
        """
      },
      %{
        n: 2,
        title: "Add credentials only when a run needs them.",
        body:
          "A Vault is an optional set of environment-variable overrides. " <>
            "Attach one in the API call; leave it off when a run needs no credentials.",
        code: """
        apiVersion: fountain.dev/v1
        kind: Vault
        metadata:
          name: ci-bot
        spec:
          secrets:
            GITHUB_TOKEN: op://Private/github/token # resolved from 1Password at apply time\
        """
      },
      %{
        n: 3,
        title: "Name the agent and its tools.",
        body:
          "Pick the runtime and model, add skills and MCP tools, and attach the " <>
            "Environment. The public DeepWiki server needs no credential.",
        code: """
        apiVersion: fountain.dev/v1
        kind: Agent
        metadata:
          name: reviewer
        spec:
          runtime: claude
          model: anthropic/claude-sonnet-5
          environment: app
          skills:
            - source: obra/superpowers
              ref: v2.1.0
          mcp_servers:
            deepwiki:
              type: http
              url: https://mcp.deepwiki.com/mcp\
        """
      },
      %{
        n: nil,
        title: "One file, three documents.",
        body: "Apply it once. It creates what is new and updates what changed.",
        code: "fountain apply -f fountain.yml"
      },
      %{
        n: 4,
        title: "Send a prompt.",
        body:
          "A sandbox spawns and the agent works, streaming as it goes. Send " <>
            "another prompt and the machine is still there with its work on it.",
        code: sdk_example()
      }
    ]
  end

  @doc "The three manifest documents, joined as the one file `apply` reads."
  def apply_example do
    build_steps()
    |> Enum.filter(&(&1.code =~ "kind: "))
    |> Enum.map_join("\n---\n", & &1.code)
  end

  @doc "The kinds `fountain apply` supports. `apply_example/0` may name no other."
  def apply_kinds, do: ~w(Environment Vault Agent)

  @doc """
  The SDK call on the homepage, kept out of the template so its braces are not
  HEEx.

  It is the whole builder pitch in nine lines, so every identifier in it has to
  be one the published SDK exports. `channelId` binds the conversation to an id
  the caller already has (`RunConfig.channelId`), and `text` is the answer with
  the tool noise removed (`RunResult.text`). An earlier draft printed
  `run.output`, which is not a field, and a reader who pasted it got
  `undefined`.
  """
  def sdk_example do
    """
    import { Fountain } from "@managoat/fountain-sdk";

    const fountain = new Fountain(); // FOUNTAIN_API_KEY

    const run = await fountain.run(
      "Fix the failing test and open a PR",
      { agent: "reviewer", vault: "ci-bot", channelId: ticket.id }
    );

    console.log(run.text);\
    """
  end

  @doc """
  The SDK walkthrough on the open-source launch page, one action per beat.

  The page keeps the three definitions and first prompt separate so the
  explanation beside each stays attached to the code it describes. The first
  three are one setup script: the Environment and Vault ids returned by
  Fountain are passed to the Agent. The last beat changes to `run.ts`, where
  the Agent and Vault names match the definitions above it.

  The secret write is deliberately separate from `vaults.create/1`. Secret
  values are write-only in the SDK, and showing that call keeps the Vault from
  reading like an empty marker record.
  """
  def oss_sdk_steps do
    [
      %{
        n: 1,
        file: "setup.ts",
        label: "environment",
        title: "Describe the machine once.",
        body:
          "Repositories, packages, env vars and setup scripts. The Environment is reusable across agents and runs.",
        code: """
        import { Fountain } from "@managoat/fountain-sdk";

        const fountain = new Fountain(); // FOUNTAIN_API_KEY

        const environment = await fountain.environments.create({
          name: "app",
          repositories: [{
            url: "https://github.com/acme/app",
            mount_path: "/work/app",
          }],
          setup_script: "cd /work/app && npm install",
        });\
        """
      },
      %{
        n: 2,
        file: "setup.ts",
        label: "vault",
        title: "Add credentials only when a run needs them.",
        body:
          "A Vault is an optional set of environment-variable overrides. Write its values separately, then attach it only to runs that need them.",
        code: """
        const vault = await fountain.vaults.create({ name: "ci-bot" });

        await fountain.vaults.secrets.set(
          vault.id,
          "GITHUB_TOKEN",
          process.env.GITHUB_TOKEN!
        );\
        """
      },
      %{
        n: 3,
        file: "setup.ts",
        label: "agent",
        title: "Name the agent and its tools.",
        body:
          "Pick the runtime and model, add skills and MCP tools, attach the Environment, and allow the Vault callers may opt into.",
        code: """
        await fountain.agents.create({
          name: "reviewer",
          runtime: "claude",
          model: "anthropic/claude-sonnet-5",
          environment_id: environment.id,
          allowed_vault_ids: [vault.id],
          skills: [{ source: "obra/superpowers", ref: "v2.1.0" }],
          mcp_servers: {
            deepwiki: {
              type: "http",
              url: "https://mcp.deepwiki.com/mcp",
            },
          },
        });\
        """
      },
      %{
        n: 4,
        file: "run.ts",
        label: "prompt",
        title: "Send a prompt.",
        body:
          "Attach the Vault when this run needs its GitHub token; leave it off otherwise. " <>
            "Fountain streams the work as it happens and keeps the conversation ready for the next prompt.",
        code: sdk_example()
      }
    ]
  end

  ## The security review
  #
  # What a builder's security reviewer asks, answered on the page. Every answer
  # names a mechanism that exists in this repo today, and every one that has a
  # limit carries it in `:limit` rather than leaving the reader to find it.
  # That field is not decoration: a reviewer who discovers an unstated limit
  # stops believing the answers above it too.
  #
  # Sources, so a later edit can be checked rather than guessed:
  #   crypto.ex + docs/concepts/secrets.md      the DEK and the write-only rule
  #   conversations/redaction.ex                the 8-byte literal match
  #   cross_tenant_isolation_test.exs           the scoping guardrail
  #   decisions/0013-audit-trail.md             what is recorded, and what is not
  #   docs/concepts/permissions.md              `ask`, and what each runtime asks about
  #   workers/retention_pruner.ex               the retention windows
  #   decisions/0009 + account deletion         export, deletion, crypto-shred
  #
  # The egress broker (ADR 0019) is deliberately absent. It is off until an
  # operator configures it, so it belongs in `security_absent/0` rather than in
  # an answer.

  @doc "The questions a security reviewer asks, and the mechanism that answers each."
  def security_answers do
    [
      %{
        question: "Where do the credentials live, and who can read them?",
        answer:
          "An Environment holds the machine's own variables and a Vault holds a small " <>
            "bag of overrides for one run. The name collides with HashiCorp's and means " <>
            "close to the opposite here. A Vault is a per-run override layer rather " <>
            "than a central store. " <>
            "Both are encrypted at rest with AES-256-GCM under a key derived for your " <>
            "account alone. Values are write-only. No endpoint returns one, to anybody, " <>
            "including an operator.",
        limit:
          "Deleting your account destroys that key with it, so what any backup still " <>
            "holds is unreadable rather than merely deleted."
      },
      %{
        question: "Does the model ever see them?",
        answer:
          "No. Secrets merge into the sandbox's process environment when it spawns, " <>
            "and reach an agent's configuration through ${VAR} substitution. Nothing " <>
            "puts them in the prompt, the system prompt or the model's context.",
        limit:
          "An agent that reads its own environment and says the value out loud has " <>
            "said it. The next answer is what happens to that line."
      },
      %{
        question: "What ends up in your logs?",
        answer:
          "Every secret value you registered that is eight bytes or longer is replaced " <>
            "with [REDACTED] before the log line is written, not after. The transcript " <>
            "we store never held it.",
        limit:
          "The match is on exact bytes. A value the agent re-encodes, splits or prints " <>
            "in pieces is not caught, and neither is one shorter than eight bytes."
      },
      %{
        question: "Can one account's agent reach another's?",
        answer:
          "Every user-facing query is scoped by account. The few unscoped internal " <>
            "reads carry an _unsafe_ prefix so a reviewer can grep for all of them in " <>
            "one command, and a cross-tenant isolation suite in CI asserts the scoped " <>
            "endpoints answer 404 on another account's data.",
        limit: nil
      },
      %{
        question: "What is recorded when something changes, and for how long?",
        answer:
          "The event is written where the change happens rather than where the request " <>
            "arrived, so the console, the API and a background worker are covered by one " <>
            "rule. An update names the fields that moved and never their values; a secret " <>
            "event records the key, the size and the provider. Read your own trail at " <>
            "GET /api/audit, filtered by action, resource or time.",
        limit:
          "Conversation log events are kept 90 days, audit events a year, usage 400 " <>
            "days. On your own instance every window is a setting."
      },
      %{
        question: "Can the agent do something nobody approved?",
        answer:
          "Set an agent's permission policy to ask and a tool call stops for a human " <>
            "before it runs, not after. The stronger pattern is the one the case study " <>
            "uses. Build the last gate somewhere the agent cannot reach, so refusing " <>
            "is somebody else's job rather than the model's.",
        limit:
          "Asking is not the default, and it is not universal. Each runtime decides " <>
            "which tool calls it asks about, and a policy answers only the ones it is " <>
            "asked."
      },
      %{
        question: "What if none of this may leave our network?",
        answer:
          "Run the server yourself. The control plane, the transcripts, the audit trail " <>
            "and the encrypted secrets then live in your deployment and your Postgres.",
        limit:
          "The sandboxes still run at a hosted provider, Sprites or E2B. Fountain no " <>
            "longer runs agents on hardware you own, so the repositories and credentials " <>
            "a run uses reach that provider."
      }
    ]
  end

  @doc """
  What this platform does not have, said on the page.

  A security reviewer asks for the first two of these in week one. Finding out
  then is cheaper for both sides than finding out in a questionnaire, and the
  voice standard's "concede the failure case in the same breath" applies to a
  product's posture as much as to a feature. Every row was verified absent
  from the repo. Do not soften one into "coming soon", and do not add a row
  that has not been checked.
  """
  def security_absent do
    [
      "No SOC 2 report, no ISO 27001 certificate, and no HIPAA posture. " <>
        "None of that work has been done. A review that requires one of them is a " <>
        "review this platform cannot pass.",
      "No data processing agreement on file and no published sub-processor list.",
      "No single sign-on, no organizations and no seats. An account is one person, " <>
        "and a team shares one or runs an instance of its own.",
      "No independent penetration test. The security work in the repo is the " <>
        "security work there is, and it is open source, so you can read all of it.",
      "The egress broker that keeps a credential out of the sandbox entirely is off " <>
        "until the operator configures it. On an instance without it, assume the " <>
        "sandbox holds the values you give it."
    ]
  end

  ## /integrations
  #
  # The page is data first: the protocols Fountain speaks, what already speaks
  # each one, and one snippet for each shape of builder. Each entry links a
  # page of the manual, and the controller test checks every such link
  # resolves, so a renamed docs page fails here rather than on the site.

  attr(:protocol, :map, required: true)
  attr(:works_label, :string, default: "Works with")

  def protocol_card(assigns) do
    ~H"""
    <article
      id={@protocol.id}
      class="rounded-xl border border-[var(--color-border)] bg-[var(--color-bg-0)] p-6 sm:p-8 scroll-mt-6"
      data-role="protocol"
    >
      <div class="grid md:grid-cols-5 gap-8">
        <div class="md:col-span-3">
          <div class="flex flex-wrap items-baseline gap-x-3 gap-y-1 mb-1">
            <h3 class="text-xl font-semibold text-[var(--color-text-primary)]">
              {@protocol.name}
            </h3>
            <span class="text-sm text-[var(--color-text-muted)]">{@protocol.long}</span>
            <span
              :if={@protocol[:status]}
              class="inline-flex items-center rounded px-1.5 py-0.5 text-[10px] font-semibold uppercase tracking-wide bg-[var(--color-bg-2)] text-[var(--color-text-muted)]"
            >
              {@protocol.status}
            </span>
          </div>
          <code
            class="inline-block mt-1 mb-4 text-xs text-[var(--color-code-text)] bg-[var(--color-code-bg)] rounded px-1.5 py-0.5"
            phx-no-format
          >{@protocol.surface}</code>
          <p class="text-sm text-[var(--color-text-secondary)] leading-relaxed">
            {@protocol.pitch}
          </p>
          <p class="mt-3 text-xs text-[var(--color-text-muted)]">
            {@protocol.direction}
          </p>
          <a
            href={@protocol.docs}
            class="inline-block mt-4 text-sm font-medium text-[var(--color-text-primary)] underline underline-offset-2 hover:text-[var(--color-brand)]"
          >
            {@protocol.docs_label} →
          </a>
        </div>
        <div class="md:col-span-2">
          <p class="text-xs font-medium uppercase tracking-wide text-[var(--color-text-muted)] mb-3">
            {@works_label}
          </p>
          <ul class="space-y-2">
            <li
              :for={item <- @protocol.works_with}
              class="flex items-start gap-2.5 text-sm"
              data-role="works-with"
            >
              <span class="mt-0.5 flex-shrink-0 text-[var(--color-text-primary)]">
                <.mark name={item.name} slug={item.slug} class="size-4" />
              </span>
              <span>
                <span class="font-medium text-[var(--color-text-primary)]">{item.name}</span>
                <span class="text-[var(--color-text-muted)]">· {item.note}</span>
              </span>
            </li>
          </ul>
        </div>
      </div>
    </article>
    """
  end

  @doc "The protocol integrations this page describes."
  def protocols do
    [
      %{
        id: "acp",
        kind: :client,
        name: "ACP",
        long: "Agent Client Protocol",
        surface: "fountain acp --agent <name>",
        direction: "An editor or chat app launches the local CLI; the work runs remotely.",
        pitch:
          "Run a Fountain agent from an ACP-capable editor or chat app. The CLI " <>
            "connects the client to a remote sandbox, so you can close your laptop " <>
            "mid-turn and pick up the result when you return. The protocol's block " <>
            "vocabulary passes through without another adapter.",
        docs: "/docs/integrations/editors",
        docs_label: "Editors over ACP",
        works_with: [
          %{name: "Zed", slug: "zedindustries", note: "an agent_servers entry, verified"},
          %{
            name: "JetBrains IDEs",
            slug: "jetbrains",
            note: "AI Assistant's acp.json, no subscription needed"
          },
          %{name: "Neovim", slug: "neovim", note: "CodeCompanion, avante"},
          %{name: "Emacs", slug: "gnuemacs", note: "agent-shell"},
          %{name: "VS Code", slug: nil, note: "the ACP client extensions"},
          %{name: "Obsidian", slug: "obsidian", note: "the Agent Client plugins"},
          %{name: "Jupyter", slug: "jupyter", note: "agent-client-kernel"},
          %{
            name: "OpenClaw",
            slug: nil,
            note: "its acpx plugin, verified, from Telegram, Discord, Slack, Signal or iMessage"
          },
          %{name: "Discord", slug: "discord", note: "the community ACP bridges, and Telegram's"},
          %{
            name: "Vercel AI SDK",
            slug: "vercel",
            note: "the community acp-ai-provider, an ACP agent as a LanguageModel"
          }
        ]
      },
      %{
        id: "mcp",
        kind: :tool,
        name: "MCP",
        long: "Model Context Protocol, both ways",
        surface: "Any MCP server, on any agent",
        # Fountain hosts no MCP server of its own (docs/catalog/mcp-servers):
        # Connections and the Buzz extension, which used to add servers here,
        # were removed.
        direction: "Agents call the servers you name. Fountain hosts none of its own.",
        pitch:
          "Give each Fountain agent the stdio or HTTP MCP servers it needs. Fountain " <>
            "passes their declarations to the runtime without curating them, and fills " <>
            "each ${VAR} in their config from the agent's environment and vault.",
        docs: "/docs/catalog/mcp-servers",
        docs_label: "Declare MCP servers",
        works_with: [
          %{
            name: "Any stdio server",
            slug: nil,
            note: "named on the agent, run in its sandbox"
          },
          %{
            name: "Any remote HTTP server",
            slug: nil,
            note: "a url and headers, its token from a vault"
          }
        ]
      },
      %{
        id: "api",
        kind: :client,
        name: "REST and SSE",
        long: "Fountain's own API",
        surface: "/api, with a TypeScript SDK and a CLI",
        direction: "Your code drives everything the console can, and more.",
        pitch:
          "Start and follow agents from your own code. Create a Conversation, send a " <>
            "prompt and stream the parsed blocks until the turn ends. Sign in with " <>
            "Fountain gives browser apps an OAuth flow. The apps this project ships use " <>
            "the same public API and SDK.",
        docs: "/docs/api",
        docs_label: "The API reference",
        works_with: [
          %{
            name: "Conversations",
            slug: nil,
            note: "the chat app we ship, static files on the SDK"
          },
          %{name: "Workbench", slug: nil, note: "the shared engineering workbench"},
          %{name: "TypeScript", slug: "typescript", note: "@managoat/fountain-sdk on npm"},
          %{name: "Go", slug: "go", note: "the fountain CLI, and its source"},
          %{
            name: "GitHub Actions",
            slug: "githubactions",
            note: "the CLI in a step"
          },
          %{name: "React", slug: "react", note: "a static app on Sign in with Fountain"},
          %{name: "Claude Code", slug: "claudecode", note: "the /skill file teaches it the API"},
          %{name: "Cursor", slug: "cursor", note: "the same skill, and /llms.txt"},
          %{
            name: "Hermes Agent",
            slug: nil,
            note: "the plugin this repo ships: fountain_run and six more"
          },
          %{name: "curl", slug: "curl", note: "everything the SDK does"}
        ]
      }
    ]
  end

  @doc "The interfaces a client uses to start and follow an agent."
  def client_protocols, do: Enum.filter(protocols(), &(&1.kind == :client))

  @doc "The protocol an agent uses to reach its tools."
  def tool_protocol, do: Enum.find(protocols(), &(&1.kind == :tool))

  @doc """
  What runs behind an integration, split into choices the developer makes.
  `title` names each group on /integrations; `pitch` is the imperative heading
  /oss-launch gives the same group.
  """
  def inside do
    [
      %{
        title: "Runtimes",
        pitch: "Bring the runtime you want.",
        blurb:
          "Choose the coding agent the sandbox runs. Every client-facing interface sees the same shape.",
        items: [
          %{name: "Claude Code", slug: "claudecode"},
          %{name: "Codex", slug: "openai"},
          %{name: "Gemini CLI", slug: "googlegemini"}
        ]
      },
      %{
        title: "Model access",
        pitch: "Use the model provider you trust.",
        blurb:
          "Bring your own credentials. Your model provider bills you directly; Fountain never marks up tokens.",
        items: [
          %{name: "Anthropic", slug: "anthropic"},
          %{name: "OpenAI", slug: "openai"},
          %{name: "Google Gemini", slug: "googlegemini"},
          %{name: "Claude subscription", slug: "claude"}
        ]
      },
      %{
        title: "Sandboxes",
        pitch: "Run on the sandbox you choose.",
        blurb: "Where the agent runs: a sandbox provider your instance holds a token for.",
        items: [
          %{name: "Sprites", slug: "sprites"},
          %{name: "E2B", slug: "e2b"}
        ]
      }
    ]
  end

  @doc """
  Services the egress broker ships a credential preset for, read from the same
  catalog the console offers, so the page cannot name one the broker lacks.
  """
  # `Fountain.SecretBindings.Catalog.presets/0` with `usable: true`, in catalog
  # order (apps/fountain/priv/broker/service_catalog.json). The app read the
  # catalog so the page could not name a preset the broker lacks; this copy
  # has to be re-read when that file changes.
  @brokered_presets [
    {"anthropic", "Anthropic"},
    {"cloudflare", "Cloudflare"},
    {"cohere", "Cohere"},
    {"datadog", "Datadog"},
    {"deepseek", "DeepSeek"},
    {"discord", "Discord"},
    {"fireworks", "Fireworks AI"},
    {"gemini", "Google Gemini"},
    {"github", "GitHub"},
    {"gitlab", "GitLab"},
    {"groq", "Groq"},
    {"linear", "Linear"},
    {"mistral", "Mistral AI"},
    {"notion", "Notion"},
    {"npm", "NPM"},
    {"npmgh", "Github NPM registry"},
    {"openai", "OpenAI"},
    {"openrouter", "OpenRouter"},
    {"pagerduty", "PagerDuty"},
    {"perplexity", "Perplexity"},
    {"postmark", "Postmark"},
    {"resend", "Resend"},
    {"sendgrid", "SendGrid"},
    {"sentry", "Sentry"},
    {"shopify", "Shopify"},
    {"slack", "Slack"},
    {"stripe", "Stripe"},
    {"supabase", "Supabase"},
    {"telegram", "Telegram"},
    {"together", "Together AI"},
    {"vercel", "Vercel"},
    {"xai", "xAI (Grok)"}
  ]

  def brokered_services do
    Enum.map(@brokered_presets, fn {id, name} -> %{name: name, slug: broker_slug(id)} end)
  end

  @broker_slugs %{
    "anthropic" => "anthropic",
    "cloudflare" => "cloudflare",
    "datadog" => "datadog",
    "discord" => "discord",
    "github" => "github",
    "gitlab" => "gitlab",
    "gemini" => "googlegemini",
    "linear" => "linear",
    "notion" => "notion",
    "openai" => "openai",
    "pagerduty" => "pagerduty",
    "sentry" => "sentry",
    "shopify" => "shopify",
    "slack" => "slack",
    "stripe" => "stripe",
    "supabase" => "supabase",
    "telegram" => "telegram",
    "vercel" => "vercel"
  }

  defp broker_slug(id), do: Map.get(@broker_slugs, id)

  @doc "One snippet for each shape of builder, kept here so braces are not HEEx."
  def scenarios do
    [
      # Fountain retired its AG-UI and OpenAI-compatible endpoints (fountain
      # ADR 0057), so no scenario here may suggest that pointing an existing
      # client at a Fountain URL is enough. These two used to be CopilotKit's
      # HttpAgent and a chat-completions curl; both are now the native API,
      # with the application reading the stream itself.
      %{
        id: "react",
        have: "A React app",
        want: "An agent in the product, with a sandbox of its own behind the chat.",
        how:
          "The TypeScript SDK and a user-scoped token from Sign in with Fountain. Your component starts the run and renders the stream itself.",
        lang: "ts",
        docs: "/docs/build",
        code: """
        import { Fountain } from "@managoat/fountain-sdk";

        const fountain = new Fountain({ apiKey: userToken }); // from Sign in with Fountain
        const run = fountain.runRequest({ agent_id: agentId, prompt });
        for await (const chunk of run.textStream) setReply((text) => text + chunk);
        """
      },
      %{
        id: "editor",
        have: "An editor",
        want: "A thread in Zed that runs on a machine that is not yours.",
        how: "One agent_servers entry. Credentials come from fountain auth login.",
        lang: "json",
        docs: "/docs/integrations/editors",
        code: """
        "agent_servers": {
          "Fountain: reviewer": {
            "command": "fountain",
            "args": ["acp", "--agent", "reviewer", "--permission", "ask"]
          }
        }
        """
      },
      %{
        id: "backend",
        have: "A backend or a script",
        want: "Start an agent and follow its work, with nothing installed.",
        how: "Two requests: create the conversation with a prompt, then read its event stream.",
        lang: "bash",
        docs: "/docs/api",
        code: """
        curl -sS -X POST https://managoat.com/api/conversations \\
          -H "Authorization: Bearer ftn_..." -H "Content-Type: application/json" \\
          -d '{"agent_id": "<agent_id>", "prompt": "Review the open PRs."}'

        curl -N -H "Authorization: Bearer ftn_..." \\
          "https://managoat.com/api/conversations/<id>/stream?blocks=true"
        """
      },
      %{
        id: "assistant",
        have: "A personal assistant",
        want:
          "OpenClaw or Hermes hands a task to a Fountain agent from Telegram, Discord or Slack.",
        how:
          "OpenClaw's acpx plugin spawns fountain acp. Hermes installs the plugin this repo ships.",
        lang: "bash",
        docs: "/docs/integrations/openclaw",
        code: """
        # OpenClaw: an ACP backend
        openclaw plugins install @openclaw/acpx

        # Hermes Agent: fountain_run and six siblings
        hermes plugins install managoat/fountain/integrations/hermes/fountain --enable
        """
      },
      %{
        id: "pipeline",
        have: "A pipeline",
        want: "Start a run from CI and keep the step until it ends.",
        how:
          "The CLI in a step. fountain run streams the turn and returns when it ends; reattach to a dropped stream by id.",
        lang: "bash",
        docs: "/docs/cli",
        # Both commands are real (docs/cli.md). Fountain removed its outbound
        # webhooks, so the step waits on the stream instead.
        code: """
        fountain run reviewer -p "Review PR #$PR"

        # a dropped connection loses nothing; reattach by id
        fountain conv stream <conversation-id>
        """
      },
      %{
        id: "product",
        have: "Your own product",
        want: "A roster of agents and threads, under your login, on your origin.",
        how: "The SDK for the calls, Sign in with Fountain for the user, one static app.",
        lang: "ts",
        docs: "/docs/build",
        code: """
        import { Fountain } from "@managoat/fountain-sdk";

        const fountain = new Fountain({ apiKey: token }); // from the OAuth flow
        const roster = await fountain.agents.list();
        const run = fountain.resume(conversationId).send("Pick up where you left off.");
        for await (const event of run) render(event);
        """
      }
    ]
  end

  ## /built-with
  #
  # The example apps this project built on the API, grouped by product shape.
  # Every one is a real deployment against the hosted instance, and every one
  # is open source, so a card carries two links and the page carries no claim
  # that cannot be clicked. The controller test asserts both are absolute and
  # that no app is listed twice.
  #
  # The first group holds the flagship apps, and they lead every page
  # that shows the roster. An app in it carries a `:flagship` key holding the
  # lines its featured cards add: a short homepage description, what it is
  # like, and who it is for. That key is what `flagship_apps/0` selects on, so
  # the tier is a property of the entry rather than a second list to keep in
  # step.

  @doc "The applications built on the API, in the order and grouping the page shows."
  def built_apps do
    [
      %{
        id: "flagship",
        title: "Two ways to work with your agents",
        blurb:
          "Fountain's web UI is the operator console for accounts, keys, agents, environments and audit. These two apps are working surfaces built on the same public API available to your product.",
        apps: [
          %{
            id: "fountain-conversations",
            glyph: "\u{1F9F5}",
            name: "Conversations",
            host: "fountain-conversations.demo.managoat.com",
            url: "https://fountain-conversations.demo.managoat.com/",
            source: "https://github.com/managoat/demos/tree/main/apps/fountain-conversations",
            screenshot: %{
              src: "/site/images/apps/conversations.jpg",
              alt:
                "Conversations showing a cart task, tool calls, an expanded code diff, and tests in progress"
            },
            blurb:
              "Start a run and watch the agent work turn by turn. Switch among chat, timeline and raw views of the same conversation, including the sandbox it shares with related runs.",
            shows:
              "event streams rendered as blocks and one sandbox shared by several conversations",
            flagship: %{
              homepage: "Run an agent and watch every step.",
              like: "A coding-agent chat with its checkout, shell and event stream visible.",
              who: "Start here to see one run from first prompt to final response."
            }
          },
          %{
            id: "fountain-workbench",
            glyph: "\u{1F9F0}",
            name: "Workbench",
            host: "fountain-workbench.demo.managoat.com",
            url: "https://fountain-workbench.demo.managoat.com",
            source: "https://github.com/managoat/demos/tree/main/apps/fountain-workbench",
            screenshot: %{
              src: "/site/images/apps/workbench.jpg",
              alt: "Workbench with a storefront work item and Builder assigned to it"
            },
            blurb:
              "A shared engineering workbench. Each project bundles a reusable environment and credentials with its work items, so assigning an agent takes one prompt.",
            shows:
              "projects composed from reusable environments and credentials, with agents as staff",
            flagship: %{
              homepage: "Assign work across shared projects.",
              like: "One board for shared projects, work items and the agents assigned to them.",
              who: "Use it when several people need the same agents and project setup."
            }
          }
        ]
      },
      %{
        id: "everyone",
        title: "Research and data",
        blurb:
          "The output is a document or a chart. The agent and its sandbox stay behind the interface.",
        apps: [
          %{
            id: "briefing-room",
            glyph: "\u{1F4F0}",
            name: "Briefing Room",
            host: "briefing-room.demo.managoat.com",
            url: "https://briefing-room.demo.managoat.com",
            source: "https://github.com/managoat/demos/tree/main/apps/briefing-room",
            blurb:
              "Describe what you need to understand and why. A research agent reads sources on the web and returns a cited brief instead of a chat transcript.",
            shows: "web research that returns a document instead of a chat interface"
          },
          %{
            id: "table-talk",
            glyph: "\u{1F4CA}",
            name: "Table Talk",
            host: "table-talk.demo.managoat.com",
            url: "https://table-talk.demo.managoat.com",
            source: "https://github.com/managoat/demos/tree/main/apps/table-talk",
            blurb:
              "Drop in a CSV. An analyst runs Python in its sandbox and returns charts with plain-language findings. Keep asking questions of the same data.",
            shows: "sandboxed Python analysis behind a file-upload interface"
          }
        ]
      },
      %{
        id: "engineers",
        title: "Software engineering",
        blurb:
          "Each app gives an agent a checkout, a shell and a bounded task, then makes the work visible.",
        apps: [
          %{
            id: "repo-sage",
            glyph: "\u{1F33F}",
            name: "Repo Sage",
            host: "repo-sage.demo.managoat.com",
            url: "https://repo-sage.demo.managoat.com",
            source: "https://github.com/managoat/demos/tree/main/apps/repo-sage",
            blurb:
              "Name any public GitHub repository. An agent clones it in a sandbox and answers with file-and-line citations that link back to the source.",
            shows: "repository checkout, search and file-and-line citations"
          },
          %{
            id: "mission-control",
            glyph: "\u{1F680}",
            name: "Mission Control",
            host: "mission-control.demo.managoat.com",
            url: "https://mission-control.demo.managoat.com",
            source: "https://github.com/managoat/demos/tree/main/apps/mission-control",
            blurb:
              "Describe a goal. A coordinator drafts a plan for your approval, then starts one sandboxed agent per task. Watch them work and receive one combined report.",
            shows: "approval gates, parallel runs, combined event streams and a final report"
          },
          %{
            id: "dns-desk",
            glyph: "\u{1F5C2}\u{FE0F}",
            name: "DNS Desk",
            host: "dns-desk.demo.managoat.com",
            url: "https://dns-desk.demo.managoat.com/",
            source: "https://github.com/managoat/demos/tree/main/apps/dns-desk",
            blurb:
              "A DNS operator for your Cloudflare zones. Ask in plain words, read the plan as a diff, approve. The zone tables stay on screen while the agent does the work.",
            shows: "a reviewable plan and explicit approval before changing a live system"
          }
        ]
      },
      %{
        id: "infrastructure",
        title: "Infrastructure operations",
        blurb:
          "Repair systems with tools scoped to the job, and take the result back as one reviewable patch.",
        apps: [
          %{
            id: "mend",
            glyph: "\u{1F526}",
            name: "Mend",
            host: "mend.demo.managoat.com",
            url: "https://mend.demo.managoat.com",
            source: "https://github.com/managoat/demos/tree/main/apps/mend",
            blurb:
              "Mend audits CI, manifests, Dockerfiles and cloud templates. It applies mechanical fixes, explains judgment calls and returns one patch.",
            shows: "a real CLI in the sandbox and ambiguous findings left for review"
          }
        ]
      },
      %{
        id: "ai-engineers",
        title: "Agent evaluation",
        blurb: "Run the same prompt across several agents, then compare their outputs and usage.",
        apps: [
          %{
            id: "arena",
            glyph: "\u{1F94A}",
            name: "Arena",
            host: "arena.demo.managoat.com",
            url: "https://arena.demo.managoat.com",
            source: "https://github.com/managoat/demos/tree/main/apps/arena",
            blurb:
              "Send one prompt to several agents in blind columns. Compare their live responses, latency and token counts, then vote on the result.",
            shows: "parallel conversations, model selection and per-turn usage"
          }
        ]
      }
    ]
  end

  @doc "Every app on /built-with, flattened. The count the page quotes comes from here."
  def built_apps_flat, do: Enum.flat_map(built_apps(), & &1.apps)

  @doc """
  The flagship applications, in the order every page shows them.
  Selected out of `built_apps/0` rather than restated, so a flagship card
  cannot drift from its roster entry.
  """
  def flagship_apps, do: Enum.filter(built_apps_flat(), &Map.has_key?(&1, :flagship))

  @doc "The group the flagship apps sit in, for the heading above their cards."
  def flagship_group, do: Enum.find(built_apps(), &(&1.id == "flagship"))

  @doc "The rest of the roster, which /built-with lists under the featured apps."
  def other_app_groups, do: Enum.reject(built_apps(), &(&1.id == "flagship"))

  ## /self-hosted

  @doc "The project's repository. The self-hosted page links it from four places."
  def repo_url, do: Site.Brand.repo_url()

  @doc """
  The four primitives as /oss-launch introduces them: one line each, framed by
  what an agent needs beyond a model rather than by Fountain's internals. The
  long versions live in `docs/primitives.md` and on the homepage.
  """
  def oss_primitives do
    [
      %{
        name: "Environment",
        body: "The machine: repositories, packages, env vars and setup scripts."
      },
      %{
        name: "Vault",
        body:
          "The credentials a run is allowed to use, kept apart so rotating a token is not a machine edit."
      },
      %{
        name: "Agent",
        body: "The runtime, model, skills and tools, under one name your software can call."
      },
      %{
        name: "Conversation",
        body: "The running work: prompts, streamed output and the sandbox behind them."
      }
    ]
  end

  @doc """
  Deployment paths featured by the Fountain open-source launch page. `slug` is
  the `Site.Icons` mark for each target's own platform.
  """
  def oss_deploy_targets do
    [
      %{
        name: "Docker Compose",
        slug: "docker",
        body:
          "One app container, Postgres and the same published release image used everywhere else.",
        href: "/docs/guides/operate/deploy"
      },
      %{
        name: "Fly.io",
        slug: "flydotio",
        body:
          "Deploy the published image from fly.toml and bring the Postgres database you choose.",
        href: "/docs/guides/operate/fly"
      },
      %{
        name: "Kubernetes",
        slug: "kubernetes",
        body:
          "Plain manifests, no operator or CRDs, with clustering and probes already described.",
        href: "/docs/guides/operate/kubernetes"
      },
      %{
        name: "Coolify",
        slug: "coolify",
        body: "Point Coolify at the repository and use the same Compose stack behind its proxy.",
        href: "/docs/guides/operate/coolify"
      }
    ]
  end

  @doc "The three observability signals an operator controls on /oss-launch."
  def oss_telemetry do
    [
      %{
        signal: "Metrics",
        destination: "Prometheus → Grafana",
        body:
          "Scrape routes, database timings, provisioning, turn latency and sandbox state from the private metrics listener. The repo includes dashboards and alerts.",
        config: "METRICS_PORT=9568",
        state: "Local by default"
      },
      %{
        signal: "Traces",
        destination: "OpenTelemetry → your OTLP backend",
        body:
          "Export request, provisioning and turn spans over OTLP. Point the standard exporter variables at Honeycomb, Grafana Tempo or another compatible collector.",
        config: "OTEL_EXPORTER_OTLP_ENDPOINT=…",
        state: "Off until configured"
      },
      %{
        signal: "Errors",
        destination: "Sentry API → Sentry or GlitchTip",
        body:
          "Send grouped crashes without cookies, IP addresses or request bodies. Unset the DSN and the SDK stays inert; nothing is buffered for later.",
        config: "SENTRY_DSN=…",
        state: "Off until configured"
      }
    ]
  end

  # The four apps /self-hosted shows, chosen for four different shapes of
  # front door: a commission that comes back as a document, an analyst behind a
  # file upload, a repair that comes back as one patch, and a fan-out. Selected from
  # `built_apps/0` by id rather than restated, so a card here cannot drift from
  # /built-with, and an app that is renamed or retired there raises at render
  # instead of linking nowhere — which is exactly what dropping Reflex from the
  # roster did to this list, and why briefing-room now holds the first slot.
  # The flagship apps are deliberately not here because the same page shows
  # them above as the front ends an instance gets. The showcase adds four
  # different product shapes without repeating those cards.
  @showcase_ids ~w(briefing-room table-talk mend mission-control)

  @doc """
  Four applications /self-hosted shows as different frontends over the same
  API and roster.
  """
  def self_host_showcase do
    by_id = Map.new(built_apps_flat(), &{&1.id, &1})
    Enum.map(@showcase_ids, &Map.fetch!(by_id, &1))
  end

  @doc "How many applications the roster holds. Both marketing pages quote it."
  def built_app_count, do: length(built_apps_flat())

  @doc """
  The bring-up, verbatim from the deploy guide, so the page cannot drift into
  showing commands the manual does not. Kept out of the template because
  `$(...)` and `${...}` are not HEEx.
  """
  def compose_example do
    """
    git clone https://github.com/managoat/fountain
    cd fountain

    cp .env.compose.example .env
    echo "SECRET_KEY_BASE=$(openssl rand -base64 48 | tr -d '\\n')" >> .env
    echo "MASTER_SECRETS_KEY=$(openssl rand 32 | base64 | tr '+/' '-_' | tr -d '=\\n')" >> .env
    # ... and your sandbox provider token

    docker compose up -d\
    """
  end

  @doc """
  What a bring-up needs before the first command, from the deploy guide's
  "Before you start". A reader who finds this out at command four has already
  spent the goodwill this page was for.
  """
  def prerequisites do
    [
      %{
        label: "Compose tools",
        body:
          "For the six-command path, bring Docker Engine with Compose v2 and openssl for the two key lines."
      },
      %{
        label: "Postgres 16+",
        body:
          "Fountain requires it. Compose runs one for you, or point Fountain at a Postgres you operate."
      },
      %{
        label: "Image access",
        body:
          "Pull the release image from ghcr.io. If your network blocks it, Compose can build from the checkout."
      },
      %{
        label: "Public URL",
        body:
          "Set PUBLIC_URL when users or sandboxes reach Fountain anywhere but localhost. It also builds verification links."
      }
    ]
  end

  @doc "How an operator knows the bring-up worked, verbatim from the deploy guide."
  def health_probe do
    """
    curl -sS localhost:4000/health/ready
    {"checks":{"database":"ok"},"status":"ok"}\
    """
  end

  @doc """
  The capabilities that ship switched off, and what each takes to turn on in
  an instance of your own. The rows track `docs/reference/feature-status.md`; a
  feature that comes off that page comes off this one. Several have: teammate
  email and phone, the OpenAI-compatible API (fountain ADR 0057) and
  Connections were all removed, which leaves the broker.
  """
  def rationed_features do
    [
      %{
        name: "Brokered credentials",
        blurb:
          "The real token never enters the sandbox. The broker attaches it on the way out, and the transcript keeps a placeholder.",
        yours:
          "Set BROKER_LISTEN_PORT and BROKER_PROXY_URL. Every account on the deployment is then brokered.",
        docs: "/docs/concepts/secrets"
      }
    ]
  end

  @doc "What each license lets you do, in the order that matters to somebody deciding."
  def licence_parts do
    [
      %{
        part: "The server",
        scope: "apps/fountain",
        licence: "Apache-2.0",
        means:
          "Run it, change it, host it, ship it in a closed product. Keep the license and notices when you redistribute it."
      },
      %{
        part: "The CLI and the SDK",
        scope: "cli/, sdk/typescript",
        licence: "Apache-2.0",
        means:
          "Ship them inside a closed product. An application that calls your instance takes on no obligation at all."
      }
    ]
  end

  @doc "The four ownership boundaries, with who controls each one."
  def ownership_boundaries do
    [
      %{
        status: "Runs in your account",
        title: "Control plane and database",
        body:
          "The API, console, conversations, transcripts, audit events and API keys live in your deployment and Postgres."
      },
      %{
        status: "Yours to protect",
        title: "Master key",
        body:
          "You generate the key that encrypts every tenant's environment variables. Fountain never stores it in Postgres, so back it up with the database."
      },
      %{
        status: "Your sandbox account",
        title: "Sandbox compute",
        body:
          "Sandboxes run at Sprites or E2B under a token your instance holds. The provider bills you for the machines, and Fountain parks them between messages."
      },
      %{
        status: "Your provider account",
        title: "Inference",
        body:
          "Each user supplies their own model credential. Their provider bills them directly, and Fountain adds no markup to token usage."
      }
    ]
  end

  @doc """
  What self-hosting costs, said plainly. A page that sells an instance and
  hides the bill for it gets found out in week three.
  """
  def self_host_costs do
    [
      %{
        title: "Choose a sandbox provider",
        body:
          "Sprites and E2B are both hosted, and each needs an account and a token of yours. Pick one before your first conversation, because without one every conversation fails.",
        docs: "/docs/concepts/sandboxes",
        docs_label: "About sandboxes"
      },
      %{
        title: "Configure email before inviting anyone",
        body:
          "Verification and password resets go through Resend, or an SMTP server of yours. The compose defaults skip delivery so the first account can register, and that default is for day one only.",
        docs: "/docs/guides/operate/email",
        docs_label: "Configure email"
      },
      %{
        title: "Back up the master key with the database",
        body:
          "Back it up before you have data. Lose it and every encrypted secret in the instance is gone, and no database restore brings them back.",
        docs: "/docs/guides/operate/back-up-and-restore",
        docs_label: "Back up and restore"
      },
      %{
        title: "Own every upgrade",
        body:
          "Pull the tag, run the migrations, read the note. There is no window where somebody else does it for you, and no window where somebody else does it to you.",
        docs: "/docs/guides/operate/upgrade",
        docs_label: "Upgrade an instance"
      }
    ]
  end

  @doc "The questions somebody asks between reading this page and running the clone."
  def self_host_faq do
    [
      %{
        q: "Is it really the same code?",
        a:
          "The same image and the same manifests. Every merge publishes deploy/ as an OCI artifact, and the maintainer's instance deploys from that artifact. There is no private overlay, and no patch that only we have."
      },
      %{
        q: "Does the license reach my application?",
        a:
          "No. The server, the CLI and the SDK are all Apache-2.0, so calling your instance, or changing the server and hosting it, puts no copyleft obligation on you. Keep the license and notices when you redistribute it."
      },
      %{
        q: "What do I pay for the software?",
        a:
          "Nothing. There is no license key and no seat count, and nobody has to talk to us first. The instance prices nothing and shows nobody a bill."
      },
      %{
        q: "Do I still bring a model key?",
        a:
          "Yes, and you always did. The agent bills your Anthropic, OpenAI or Google account for tokens. Nothing in the middle takes a cut of inference."
      },
      %{
        q: "How do I get rid of it?",
        a:
          "docker compose down -v. The -v flag deletes the database volume and " <>
            "every account and conversation in it. If you keep the volume instead, " <>
            "keep the same MASTER_SECRETS_KEY with it, because a new key cannot " <>
            "unwrap what the old one wrapped."
      },
      %{
        q: "How much of an instance is one person?",
        a:
          "A container, a Postgres and a sandbox token. It ships with a compose file that brings the database with it, and plain Kubernetes manifests for when it outgrows that."
      }
    ]
  end

  ## ─── /faq ─────────────────────────────────────────────────────────────────
  #
  # One page for the questions that used to sit at the bottom of three others.
  # The homepage kept its six-question grid, because that grid is the problem
  # statement rather than an FAQ, and every other question-shaped block on the
  # site now lives here.
  #
  # The sections are data so the page cannot drift from the blocks it
  # replaced: `security_answers/0` and `self_host_faq/0` are the same
  # functions those pages rendered, and `build_faq/0` is the homepage's
  # objection list moved rather than rewritten. Edit an answer once and both
  # the page and the tests that assert on it follow.

  @doc """
  The questions a builder asks before committing, moved off the homepage.

  Was `<dl>` markup inline in `home.html.heex` under "Things you would ask
  before building on it". It is data now because two pages want it and
  because the test suite can walk it.
  """
  def build_faq do
    [
      %{
        q: "Do I need a model key?",
        a:
          "Yes. Bring an Anthropic, OpenAI or Google key and the agent bills your own " <>
            "account for tokens. Nothing in between marks up the model.",
        docs: "concepts/vault",
        docs_label: "Where a key lives"
      },
      %{
        q: "I have no API key. I pay for Claude.",
        a:
          "That is a credential #{Site.Brand.name()} accepts. A Claude Pro or Team " <>
            "subscription works in place of a metered API key, and when you hold both, " <>
            "the subscription is the one your agents spend. It is usually the one you " <>
            "want spent."
      },
      %{
        q: "My product has users. Do they each need an account here?",
        a:
          "Usually not. Your account holds the agents and the key, and each of your " <>
            "users gets their own conversation on their own machine, keyed by an id you " <>
            "already have for them. When you would rather they held their own account " <>
            "and their own model key, Sign in with #{Site.Brand.name()} is OAuth " <>
            "with PKCE and the token it hands back is an ordinary API key.",
        docs: "build",
        docs_label: "Build a chat app"
      },
      %{
        q: "Can two people share one conversation?",
        a:
          "Not as a shared inbox. One conversation is one thread on one machine, so " <>
            "two users pointed at the same one see each other's work and each other's " <>
            "files. Give each person a conversation id of their own. Your account holds " <>
            "the agents, and the ids are yours to assign.",
        docs: "concepts/conversation",
        docs_label: "About conversations"
      },
      %{
        q: "Can an agent start another agent, and how deep does that go?",
        a:
          "It can, and the agent it starts can do the same from inside its own " <>
            "sandbox. Nothing caps the depth, so treat a spawning agent the way you " <>
            "would treat a recursive job anywhere else."
      },
      %{
        q: "Is this only good for writing code?",
        a:
          "The runtimes are coding agents, which is to say a shell, a filesystem and a " <>
            "network. One of the applications we built on it runs Python over a CSV you " <>
            "drop in. Another reads real sources and hands back a cited brief. If you " <>
            "would do the job at a terminal, it fits here."
      },
      %{
        q: "What happens to the sandbox between messages?",
        a:
          "It parks. The filesystem, the checkout and the agent's memory survive, " <>
            "and a parked sandbox takes none of your concurrency. The " <>
            "next message wakes it in seconds instead of minutes.",
        docs: "concepts/sandboxes",
        docs_label: "About sandboxes"
      },
      %{
        q: "Is my work separate from everyone else's?",
        a:
          "Every query is scoped to your account, every sandbox belongs to one " <>
            "conversation unless you put another on it, and your secrets are encrypted " <>
            "with a key derived for your tenant alone.",
        docs: "architecture",
        docs_label: "Architecture"
      },
      %{
        q: "Can I run it myself?",
        a: run_it_yourself_answer(),
        docs: "self-hosting",
        docs_label: "Self-host it"
      }
    ]
  end

  # The one answer that changes with the deployment. A branded hosted site
  # says which of the two things it is; an unbranded install just says the
  # engine is open source.
  defp run_it_yourself_answer do
    lead =
      if Site.Brand.hosted?() do
        "#{Site.Brand.name()} is the hosted edition of #{Site.Brand.engine()}, " <>
          "an open-source server"
      else
        "#{Site.Brand.engine()} is open source"
      end

    "Yes. #{lead}, and you can run it on your own infrastructure, with your own sandbox provider account."
  end

  @doc """
  The FAQ page, grouped into sections.

  Sections carry an `:id` because the pages that used to hold these blocks now
  link to them by anchor. Renaming one breaks an inbound link, so the suite
  asserts the anchors the other pages point at.
  """
  def faq_sections do
    building = [
      %{
        id: "building",
        title: "Building on it",
        blurb: "What a developer asks between reading the tour and writing the first call.",
        items: build_faq()
      }
    ]

    security = [
      %{
        id: "security",
        title: "Security and data",
        blurb:
          "Each answer names a mechanism rather than an intention, and each limit is " <>
            "stated beside the thing it limits.",
        items:
          Enum.map(security_answers(), fn item ->
            %{q: item.question, a: item.answer, note: item.limit}
          end)
      }
    ]

    self_hosting = [
      %{
        id: "self-hosting",
        title: "Running it yourself",
        blurb: "The questions somebody asks between reading the page and running the clone.",
        items: self_host_faq()
      }
    ]

    building ++ security ++ self_hosting
  end

  ## /case-studies/self-healing-infrastructure

  # The case study is data first, like /integrations above. Every number here
  # was counted once, by hand, over the window `case_window/0` names: the
  # dispatch counts and turn durations from this deployment's own database,
  # the pull requests and their timestamps from the cluster's repository. They
  # are literals on purpose. A figure that recomputed at request time would
  # quietly widen its own window and end up claiming something nobody checked.

  @doc "The window every number on the case study covers."
  def case_window, do: "11 to 25 August 2026"

  @doc "The lead result and its three supporting numbers, counted over `case_window/0`."
  def case_stats do
    [
      %{
        value: "7.5 min",
        label: "median alert-to-verdict time",
        home_label: "median alert-to-verdict time",
        note: "The longest investigation ran 50 minutes.",
        emphasis: :lead
      },
      %{
        value: "78",
        label: "alerts investigated by an agent",
        home_label: "alerts investigated",
        note: "Fifteen days, one cluster, one runbook.",
        emphasis: :supporting
      },
      %{
        value: "12",
        label: "fix pull requests opened",
        home_label: "fix pull requests opened",
        note: "Sixty-six alerts ended with no repository fix to propose.",
        emphasis: :supporting
      },
      %{
        value: "8",
        label: "fix pull requests merged",
        home_label: "fix pull requests merged",
        note: "The agent could neither approve nor merge.",
        emphasis: :supporting
      }
    ]
  end

  @doc "The result the case study leads with."
  def case_lead_stat, do: Enum.find(case_stats(), &(&1.emphasis == :lead))

  @doc "The counts that support the lead result."
  def case_supporting_stats, do: Enum.filter(case_stats(), &(&1.emphasis == :supporting))

  @doc "The two observed intervals around the case study's human handoff."
  def case_handoff_metrics do
    [
      %{
        id: "alert-to-pr",
        value: "4m 27s",
        prose_value: "4 minutes 27 seconds",
        seconds: 267,
        label: "Alert to proposed fix"
      },
      %{
        id: "pr-to-review",
        value: "1h 47m 45s",
        prose_value: "1 hour 47 minutes 45 seconds",
        seconds: 6_465,
        label: "Proposed fix to human review"
      }
    ]
  end

  @doc "The loop compressed into automatic work around its one human decision."
  def case_workflow do
    [
      %{
        owner: "Automatic",
        human?: false,
        body: "Detect → page and start agent → read cluster → trace git → open pull request"
      },
      %{
        owner: "Human",
        human?: true,
        body: "Decide whether to approve and merge"
      },
      %{
        owner: "Automatic",
        human?: false,
        body: "Flux applies the merge → agent verifies health"
      }
    ]
  end

  @doc "What the agent may do, and the mechanism that stops the rest."
  def case_guardrails do
    [
      %{
        can: "Read cluster state, including controller conditions.",
        cannot: "Change anything. The token is refused on any method but GET."
      },
      %{
        can: "Clone the infrastructure repository and push a branch.",
        cannot: "Push to the default branch. It is protected, and needs a pull request."
      },
      %{
        can: "Open a pull request and answer its review comments.",
        cannot:
          "Approve or merge it. GitHub blocks self-approval, and the branch " <>
            "needs another account's review."
      },
      %{
        can: "Name a secret, so the fix restores the reference.",
        cannot: "Read a secret value. The material never leaves the cluster."
      },
      %{
        can: "Decide the repository cannot fix this, and stop.",
        cannot:
          "Reach past the repository and fix it anyway. " <>
            "The sandbox has no kubectl and no kubeconfig."
      }
    ]
  end

  @doc """
  One real incident, in the order it happened. All times UTC, 25 August 2026.
  """
  def case_timeline do
    [
      %{
        time: "06:58:15",
        title: "The repo-sync sidecar runs out of memory",
        body:
          "A PodOOMKilled alert fires for the container that keeps the checkout current. " <>
            "Alertmanager sends it to the on-call engineer and the webhook at the same time."
      },
      %{
        time: "06:59:34",
        title: "The same sidecar starts throttling",
        body:
          "CPUThrottlingHigh reports 94.44%. Alertmanager sends that alert through the " <>
            "same route, starting a second investigation."
      },
      %{
        time: "07:02:42",
        title: "The OOM investigation opens a pull request",
        body:
          "The agent traces the memory spike to a package install that the sidecar's " <>
            "limit never accounted for. The pull request changes two files: nine lines " <>
            "added and four removed. It also names the commit that exercised the path."
      },
      %{
        time: "07:03:42",
        title: "The CPU investigation opens a second pull request",
        body:
          "The second run reaches the same root cause and references the first pull " <>
            "request instead of repeating the diagnosis. Its diff adds six lines and " <>
            "removes two."
      },
      %{
        time: "08:50:27",
        title: "The on-call engineer reviews both pull requests",
        body:
          "The CPU fix is merged first. Flux reconciles the change, and the agent " <>
            "watches the sidecar become healthy again."
      },
      %{
        time: "23:46:01",
        title: "The OOM fix is merged after review",
        body:
          "The OOM pull request stays open until that evening. The agent could open it, " <>
            "but it could not approve or merge it."
      }
    ]
  end

  @doc """
  The agent's own words, quoted from the pull request it opened at 07:02.

  Segmented rather than one string, because the source is a Markdown pull
  request body and rendering its backticks as literal characters in a
  blockquote reads as a mistake. `{:code, _}` becomes a code span, so the
  quote stays word for word.
  """
  def case_quote do
    [
      {:text, "Both modes call "},
      {:code, "install_members()"},
      {:text, " ("},
      {:code, "make install"},
      {:text, " → "},
      {:code, "npm ci"},
      {:text, " across every member) whenever a fetched commit touches a "},
      {:code, "package-lock.json"},
      {:text, ". The "},
      {:code, "repo-sync"},
      {:text,
       " sidecar's limit was sized only for its cheap steady-state git-fetch loop and " <>
         "never accounted for this shared, memory-heavy reinstall path — a gap latent " <>
         "since the container was authored and invisible until a commit actually moved " <>
         "a lockfile."}
    ]
  end

  @doc "What each Fountain primitive did in this loop."
  def case_primitives do
    [
      %{
        title: "Agent",
        body:
          "Runtime, model, runbook and tools, defined once in a file in a " <>
            "public repository. That reviewed file defines the job: diagnose, fix by " <>
            "pull request, wait for the human, verify, report."
      },
      %{
        title: "Environment",
        body:
          "The machine the agent wakes up on, with the repository, the CLI and " <>
            "a read-only service for cluster state. Described once, rebuilt " <>
            "per incident, never patched by hand."
      },
      %{
        title: "Fountain Vault",
        body:
          "Not a central secret store, a Fountain Vault is a small override layer. " <>
            "Here it supplied the bot identity separately from the environment. " <>
            "The token never entered the prompt, context or transcript."
      },
      %{
        title: "Conversation",
        body:
          "One incident, one sandbox, one transcript, addressed by its alert. " <>
            "The run and transcript stayed available while the human was away."
      }
    ]
  end

  @doc "The dispatcher, reduced to the part that matters. Kept out of the template."
  def case_dispatch_example do
    """
    // Alertmanager POSTs here.
    // This is the entire integration.
    await fetch(`${FOUNTAIN_URL}/api/conversations`, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${FOUNTAIN_KEY}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        agent_id: agentId,  // estate-medic
        vault_id: vaultId,  // the identity it acts as
        prompt: [
          `The cluster is alerting.`,
          alertLines,
          `Diagnose it. If a change to the repo can`,
          `fix it, open one minimal PR, wait for the`,
          `human merge, verify healthy, and report.`,
          `If nothing in the repo can fix it, do not`,
          `open a PR. Say so and stop.`,
        ].join("\\n\\n"),
      }),
    });\
    """
  end

  ## ─── /code-review-bot ──────────────────────────────────────────────────────
  #
  # The shortest useful thing anybody builds on this API, shown whole. Both
  # snippets live here rather than in the template, because HEEx would read
  # their braces, and the lengths the page quotes are counted off these
  # strings so an edit cannot leave the prose claiming the old one.

  @doc "The webhook handler. The page shows every line of it."
  def review_bot_webhook do
    """
    // api/github/webhook.ts
    import { Fountain } from "@managoat/fountain-sdk";
    import { verify } from "@octokit/webhooks-methods";

    export async function POST(req: Request) {
      const body = await req.text();
      const signature = req.headers.get("x-hub-signature-256") ?? "";
      const secret = process.env.GITHUB_WEBHOOK_SECRET!;
      if (!(await verify(secret, body, signature))) {
        return new Response("bad signature", { status: 401 });
      }

      const { action, pull_request: pr, repository: repo } = JSON.parse(body);
      if (action !== "opened" && action !== "synchronize") {
        return new Response("skipped");
      }

      // One client per request. It memoises name lookups, and the reviewer
      // on the next line may be one line old.
      const fountain = new Fountain();          // FOUNTAIN_API_KEY
      await ensureReviewer(fountain, repo);

      const run = fountain.run(
        `Review pull request #${pr.number}. The checkout is at /work/repo. ` +
          `Read the diff against origin/${pr.base.ref}, then leave one ` +
          `review with inline comments on the lines you mean.`,
        {
          agent: `reviewer/${repo.full_name}`,  // model, machine, house rules
          vault: "github-bot",                  // the identity it reviews as
          channelId: `pr/${repo.full_name}/${pr.number}`,
        },
      );

      await run.conversationId;   // booked, not finished
      return new Response("reviewing");
    }\
    """
  end

  @doc "The reviewer itself, upserted by name on every event."
  def review_bot_reviewer do
    """
    // Reconciled by name, so this is safe to run on every event: the first
    // pull request out of a repository builds the reviewer, and every pull
    // request after it changes nothing.
    type Repo = { full_name: string; clone_url: string };

    const ensureReviewer = (fountain: Fountain, repo: Repo) =>
      fountain.api.request("POST", "/api/apply", {
        body: {
          resources: [
            {
              kind: "Environment",
              name: `reviewer/${repo.full_name}`,
              spec: {
                repositories: [
                  {
                    url: repo.clone_url,
                    mount_path: "/work/repo",
                    secret_key: "GITHUB_TOKEN",
                  },
                ],
              },
            },
            {
              kind: "Agent",
              name: `reviewer/${repo.full_name}`,
              spec: {
                runtime: "claude",
                model: "anthropic/claude-opus-5",
                environment: `reviewer/${repo.full_name}`,
                system:
                  "You review pull requests, and you post the review with " +
                  "`gh`. Read the diff, not the whole repository. Name the " +
                  "specific thing that is wrong and the line it is on. One " +
                  "review per turn. Never approve.",
              },
            },
          ],
        },
      });\
    """
  end

  @doc "How long a snippet on this page is, counted rather than typed."
  def review_bot_length(snippet) when is_binary(snippet),
    do: snippet |> String.split("\n") |> length()

  @doc "The five lines that are the product, with what each one buys."
  def review_bot_anatomy do
    [
      %{
        code: "ensureReviewer(fountain, repo)",
        title: "The reviewer is a record, not a deployment.",
        body:
          "One POST to /api/apply, reconciled by name. The first pull request " <>
            "out of a repository writes an Environment holding that checkout and " <>
            "an Agent pointed at it. Every pull request after it is a no-op. " <>
            "Point the webhook at a second repository and there is no second step."
      },
      %{
        code: ~s(agent: "reviewer/<owner>/<repo>"),
        title: "One name carries the whole configuration.",
        body:
          "Which model reads the diff, which machine it wakes up on, which " <>
            "repository is already cloned on that machine, and the house rules " <>
            "it reviews by. Change any of them and no handler is redeployed."
      },
      %{
        code: ~s(vault: "github-bot"),
        title: "The credential goes to the machine, not to the model.",
        body:
          "Fountain decrypts the vault into the sandbox as the sandbox spawns. " <>
            "The token never enters the prompt, the model's context or the stored " <>
            "transcript. Put a read-only token in that vault and the same bot can " <>
            "comment and nothing else."
      },
      %{
        code: "channelId: `pr/<repo>/<number>`",
        title: "The second push lands on the first machine.",
        body:
          "A channel id resumes the live conversation bound to it instead of " <>
            "opening a new one. The checkout is still there, on the branch, and " <>
            "the reviewer still holds what it said about the last commit and why."
      },
      %{
        code: "await run.conversationId",
        title: "It returns once the work is booked.",
        body:
          "Not once the review is written. GitHub allows a webhook ten seconds " <>
            "and this answers in the time of one API call. The turn carries on in " <>
            "the sandbox after the handler has returned."
      }
    ]
  end

  @doc "What a review bot usually needs, against what this one needed."
  def review_bot_absent do
    [
      %{
        normally: "A machine, and something that decides how many to keep warm.",
        here: "A sandbox lasts as long as the review does. Nothing is warm between pull requests."
      },
      %{
        normally: "A container image per repository, rebuilt when the toolchain moves.",
        here:
          "An Environment names the repository and the packages. The bot writes it the first time it sees the repo."
      },
      %{
        normally: "A checkout on that machine, and a token that is allowed to fetch it.",
        here:
          "repositories[] clones before the agent wakes. secret_key names the secret the clone authenticates with."
      },
      %{
        normally: "Somewhere for the GitHub token to sit that the worker can read.",
        here:
          "A Vault, decrypted into the sandbox at spawn and redacted out of anything the run prints."
      },
      %{
        normally: "A queue, so a busy morning drops no pull request.",
        here:
          "One HTTP call per pull request. Concurrency is capped, and a full fleet answers 503."
      },
      %{
        normally:
          "Per-pull-request state, so a second push reviews the branch rather than the world.",
        here: "channel_id. The same pull request resumes the same conversation on the same disk."
      },
      %{
        normally: "A reaper, because what you forget to clean up is what you pay for.",
        here: "Idle sandboxes park themselves, and the reaper destroys what the ceiling says to."
      }
    ]
  end

  @doc "Everything between reading this page and the first review."
  def review_bot_setup do
    [
      %{
        step: "1",
        title: "Give it a token.",
        body:
          "One fine-grained GitHub token, scoped to the repositories you want " <>
            "reviewed. Set it under two keys, because two things read it: the " <>
            "clone reads GITHUB_TOKEN and gh reads GH_TOKEN.",
        mono: "fountain vault create github-bot"
      },
      %{
        step: "2",
        title: "Deploy the handler.",
        body:
          "Anywhere that serves one HTTP POST. It holds no state, so one instance " <>
            "and fifty behave the same. Two environment variables, and neither of " <>
            "them is a GitHub credential.",
        mono: "FOUNTAIN_API_KEY=...  GITHUB_WEBHOOK_SECRET=..."
      },
      %{
        step: "3",
        title: "Add the webhook.",
        body:
          "Repository settings, Webhooks, Add webhook. Pull request events, " <>
            "content type application/json, the same secret. The next pull " <>
            "request opened is the first one reviewed.",
        mono: "Settings → Webhooks → Pull requests"
      }
    ]
  end

  @doc "The variations that are one field rather than one rewrite."
  def review_bot_variations do
    [
      %{
        want: "It comments, and can never push.",
        change:
          "A read-only token in the vault. The sandbox holds the rights the credential holds."
      },
      %{
        want: "A harder reader on the risky directories.",
        change: "model on the Agent. Nothing else in the program knows which model it was."
      },
      %{
        want: "Two opinions on one diff.",
        change: "Call run() twice with two agent names. Each opinion gets its own sandbox."
      },
      %{
        want: "It runs the suite before it comments.",
        change: "setup_script on the Environment, and one more sentence in system."
      },
      %{
        want: "A clean reviewer for one pull request.",
        change: "fresh: true beside the channel id. The conversation it skips stays where it is."
      },
      %{
        want: "A review on a schedule rather than on a push.",
        change: "The same call, from cron. A conversation does not care what opened it."
      }
    ]
  end
end
