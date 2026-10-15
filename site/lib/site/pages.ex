defmodule Site.Pages do
  @moduledoc """
  The pages, and the data they render.

  Moved out of `FountainWeb.MarketingHTML`, where the same templates were
  rendered per request, then into the managoat/site repo, and back into
  `site/` in the fountain repo on 2026-10-15 (ADR 0034). Everything the app
  read at request time is a constant here (`Site.Brand`); the rest of the
  module was literal data already.
  """
  use Phoenix.Component

  embed_templates("pages/*")

  @doc """
  The homepage's section mark: a short accent rule and a one-word label.

  The page is ten sections of argument and every one of them used to open with
  the same centred `text-2xl` heading, so nothing told a reader which section
  they had landed in or how far through they were. The label is navigational
  rather than a claim, which is why it is one word wherever one word will do.

  The rule is the page's only repeated ornament. It carries `--color-accent`,
  which appears nowhere clickable, so it reads as a mark rather than a link.

  `tone` picks the palette: `:page` on the light sections and `:ink` on the
  dark ones.
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

  The Agent is named `reviewer` and the Vault `ci-bot` because those are the
  names the SDK call in the last beat passes. Renaming one here means renaming
  it there.

  The last beat is the whole builder pitch in nine lines, so every identifier
  in it has to be one the published SDK exports: `channelId` binds the
  conversation to an id the caller already has (`RunConfig.channelId`), and
  `text` is the answer with the tool noise removed (`RunResult.text`). An earlier
  draft printed `run.output`, which is not a field, and a reader who pasted it
  got `undefined`.

  The Vault beat says what the record is, when to attach it, and that it is
  optional. The collision with HashiCorp is stated once on the page, in the
  "Change a credential without a redeploy" card, where the longer distinction
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
        code: """
        import { Fountain } from "@managoat/fountain-sdk";

        const fountain = new Fountain(); // MANAGOAT_API_KEY

        const run = await fountain.run(
          "Fix the failing test and open a PR",
          { agent: "reviewer", vault: "ci-bot", channelId: ticket.id }
        );

        console.log(run.text);\
        """
      }
    ]
  end

  @doc "The three manifest documents, joined as the one file `apply` reads."
  def apply_example do
    build_steps()
    |> Enum.filter(&(&1.code =~ "kind: "))
    |> Enum.map_join("\n---\n", & &1.code)
  end

  ## /built-with
  #
  # The example apps this project built on the API, grouped by product shape,
  # all from managoat/demos. Every one is a real deployment against
  # managoat.com, the maintainer's instance, and every one is open source, so a
  # card carries two links and the page carries no claim that cannot be
  # clicked. `test/site_test.exs` asserts both are absolute and that no app is
  # listed twice.
  #
  # Two apps in managoat/demos are left out on purpose. `fountain-demos` is the
  # suite's own index. `drydock` is a real app, but its terminal is a PTY over
  # the Sprites exec WebSocket on a Sprites token its server holds: it reaches
  # past Managoat's API into one provider, so it shows neither "an ordinary web
  # app on the public API" nor anything that works on an E2B instance.
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
          "Managoat's own console covers your account, API keys, audit and admin. These two apps are where the work with agents happens, built on the same public API available to your product.",
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
              "Start a run and watch the agent work turn by turn. Switch among chat, timeline and raw views of the same conversation, and inspect the sandbox it runs on.",
            shows: "event streams rendered as blocks, and a sandbox's provisioning stages",
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
              who:
                "Use it when several people work on the same projects, on one owner's agents and account."
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
        id: "together",
        title: "Shared chat",
        blurb:
          "Several people in one thread with an agent. One person's account runs it, and nobody else holds the key.",
        apps: [
          %{
            id: "salon",
            glyph: "\u{1F4AC}",
            name: "Salon",
            host: "salon.demo.managoat.com",
            url: "https://salon.demo.managoat.com",
            source: "https://github.com/managoat/demos/tree/main/apps/salon",
            blurb:
              "Multiplayer chat. Start a chat on your account and invite people by email or by link; everyone reads and writes the same thread, and every turn runs on your account and your model credential.",
            shows: "a proxy that admits a guest to one conversation on the host's key"
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

  @doc "The project's repository. The self-hosted page links it from four places."
  def repo_url, do: Site.Brand.repo_url()

  @doc "How many applications the roster holds. Both marketing pages quote it."
  def built_app_count, do: length(built_apps_flat())
end
