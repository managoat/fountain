defmodule Site.Llms do
  @moduledoc """
  The machine-readable side of the manual, following the llms.txt convention
  (https://llmstxt.org/), plus a `SKILL.md` for Claude Code and similar tools:

    * `/llms.txt`: a short index of the pages an agent needs;
    * `/llms-full.txt`: the index, every page it links inlined, then the skill;
    * `/skill` and `/skills/fountain/SKILL.md`: the skill alone
      (`priv/llms/SKILL.md`).

  Rendered to files by `Site.Build`, from the same preprocessed pages the HTML
  manual is, so a link and its inlined body cannot disagree. The Fountain
  server served these until 2026-10-15, with its own `PUBLIC_URL` as the base;
  they are published once now, at `Site.Brand.site_url/0`, and an instance's
  own `/llms.txt` redirects here (decisions/0081).
  """

  # The pages `/llms.txt` links and `/llms-full.txt` inlines, in reading order.
  # `{slug, blurb}`, or `{slug, title, blurb}` where the nav title does not read
  # well out of the sidebar. Slug `""` is the manual's home page.
  #
  # Deliberately not the whole manual: over half of it is operator runbooks
  # (Kubernetes, backups) that an agent calling the API has no use for. The
  # rest is linked under "More on /docs", labelled as not inlined. The site's
  # tests fail if a slug here is not a page of the nav.
  @corpus [
    {"Get started",
     [
       {"", "What Fountain is",
        "the problem it solves, what it does about it, and `brew install` + `fountain auth login`"},
       {"tour",
        "forty lines of SDK that build an agent which clones a repo and opens a real pull request, then revise it on the same live sandbox"},
       {"tutorials/first-app",
        "a terminal chat on the TypeScript SDK: start a conversation, stream the reply, send follow-ups to the same sandbox"},
       {"cli",
        "`fountain auth|apply|run`, the `fountain.yml` manifest, and 1Password/Bitwarden/Infisical resolution at apply time"}
     ]},
    {"Concepts",
     [
       {"primitives", "how the four objects compose, and which one owns what"},
       {"concepts/environment",
        "apt packages, repos to clone, env vars, networking allowlist, setup script"},
       {"concepts/vault",
        "encrypted overrides picked per conversation; vault values win on key collision"},
       {"concepts/agent",
        "runtime, model, system prompt, skills, MCP servers, and a default environment"},
       {"concepts/conversation",
        "one run in a fresh sandbox: turns, suspend and resume, SSE streams"},
       {"concepts/secrets",
        "the layering order, and why a value never reaches the prompt or the transcript"},
       {"concepts/sandboxes",
        "provisioning, suspend and resume, reclamation, and what one costs while it runs"},
       {"concepts/permissions", "what happens before a tool runs inside the sandbox"},
       {"concepts/surfaces",
        "which surface you are talking to, and where a conversation-facing feature belongs"}
     ]},
    {"API and SDK",
     [
       {"api",
        "endpoints, the response envelope, SSE streaming, and calling back from inside a sandbox to spawn more"},
       {"sdk",
        "TypeScript: `fountain.run(prompt, {agent, vault})`, awaitable, streamable, resumable"},
       {"reference/conversation-states", "the lifecycle, and every terminal state"}
     ]},
    {"Catalog",
     [
       {"catalog", "Catalog", "everything you can name in an agent spec"},
       {"catalog/runtimes", "the three agent CLIs side by side"},
       {"catalog/runtimes/claude",
        "Anthropic's Claude Code, headless: transport, skills root, which credential it uses"},
       {"catalog/runtimes/codex", "OpenAI's Codex CLI, headless"},
       {"catalog/runtimes/gemini", "Google's Gemini CLI, headless"},
       {"catalog/skills", "how skills mount per runtime, and the injection order"},
       {"catalog/skills/fountain",
        "the bundled skill that lets an agent inside a sandbox spawn more"},
       {"catalog/mcp-servers", "what you can attach, and `${VAR}` substitution in the config"}
     ]},
    {"Build on it",
     [
       {"build", "Build a chat app", "the shape everyone clones, and why"},
       {"integrations/clients", "editors over ACP, plugin hosts, relays, or your own code"},
       {"llm-integration", "this file, `/llms-full.txt`, and `/skill`, explained"}
     ]},
    {"Reference",
     [
       {"cli/commands", "every CLI command and flag"},
       {"reference/glossary", "the vocabulary, defined once"}
     ]},
    {"Run your own instance",
     [
       {"self-hosting", "what you are signing up to operate"},
       {"guides/operate/deploy",
        "a Docker Compose instance from first boot to a first conversation"},
       {"configuration", "every environment variable the server reads"},
       {"troubleshooting", "Troubleshooting", "start from the symptom you can see"}
     ]}
  ]

  # Linked but not inlined. Real pages, off the path of "use Fountain".
  @more [
    {"architecture", "how the server and the sandboxes fit together"},
    {"build/pieces", "what each piece of it does"},
    {"changelog", "release notes"}
  ]

  @skill Path.expand("../../priv/llms/SKILL.md", __DIR__)
  @external_resource @skill

  @doc "Every slug the index links, inlined or not."
  def slugs do
    (Enum.flat_map(@corpus, fn {_section, pages} -> pages end) ++ @more)
    |> Enum.map(&elem(&1, 0))
  end

  @doc "Every slug `/llms-full.txt` inlines."
  def inlined_slugs,
    do: @corpus |> Enum.flat_map(fn {_section, pages} -> pages end) |> Enum.map(&elem(&1, 0))

  @doc "The files to write, as `{path under the output directory, body}`."
  def files(base \\ Site.Brand.site_url()) do
    skill = skill()

    [
      {"llms.txt", index(base)},
      {"llms-full.txt", full(base)},
      {"skill.txt", skill},
      {"skills/fountain/SKILL.md", skill}
    ]
  end

  @doc "The `SKILL.md` for a tool that drives Fountain from outside a sandbox."
  def skill, do: File.read!(@skill)

  @doc "`/llms.txt`."
  def index(base) do
    [
      """
      # Fountain

      > Fountain is a self-hosted server for running sandboxed coding agents. It provisions an isolated sandbox per conversation, mounts a preconfigured environment (packages, repos, env vars, MCP servers, skills), and runs the agent CLI — claude, codex, or gemini — inside. Use it to delegate, fan out, or parallelize coding agents from your own scripts, CI, or IDE.

      The four primitives:

      - **Environment** — sandbox shape (apt packages, env vars, repos to clone, networking allowlist, setup script)
      - **Vault** — free-floating bag of encrypted secret overrides, picked per-conversation; layered over the env's secrets
      - **Agent** — named runtime config (runtime + model + system prompt + skills + MCP servers + an environment)
      - **Conversation** — one running instance of an agent inside a freshly provisioned sandbox, streamable over SSE

      Reach for it instead of your agent's own sub-agents when you need isolation from your machine, a different set of credentials per run, or a runtime that isn't the one you're sitting in. It is the same delegation, on a machine that is not yours and does not hold your keys.

      Source: <https://github.com/managoat/fountain>. Fountain is self-hosted: you run an instance, and the API, the CLI and the SDK talk to it at its own URL — see "Run your own instance" below. This manual describes the current `main` branch, published at <#{base}/docs>.

      ## Read this first if you are an agent

      - [/llms-full.txt](#{base}/llms-full.txt): every page linked below, inlined as one document (~230 KB). One fetch instead of #{length(inlined_slugs())}.
      - [/skill](#{base}/skill): a `SKILL.md` to drop into `~/.claude/skills/fountain/` so Claude Code (or anything that loads SKILL.md) can drive Fountain without reading the manual first.

      ```sh
      mkdir -p ~/.claude/skills/fountain
      curl -fsSL #{base}/skill > ~/.claude/skills/fountain/SKILL.md
      ```

      ## API contract

      Every instance serves its own contract; replace the host with yours.

      - OpenAPI 3 spec, at `/api/openapi.json` on an instance: machine-readable, the authority on request and response shapes
      - Swagger UI, at `/api/docs` on an instance: interactive try-it, click "Authorize" to set your bearer token
      - [TypeScript SDK](https://www.npmjs.com/package/@managoat/fountain-sdk): `npm install @managoat/fountain-sdk`
      - [CLI (Homebrew)](https://github.com/managoat/homebrew-tap): `brew install managoat/tap/fountain`
      - [Example agent specs](https://github.com/jhgaylor/agent-specs): public manifest tree you can `fountain apply`
      """,
      Enum.map(@corpus, fn {section, pages} ->
        ["\n## ", section, "\n\n", Enum.map(pages, &link_line(&1, base))]
      end),
      """

      ## More on /docs

      Real pages, not inlined in `/llms-full.txt`.

      """,
      Enum.map(@more, &link_line(&1, base)),
      """

      ## Optional

      - [GitHub repo](https://github.com/managoat/fountain): source, releases, issues
      - [llms.txt spec](https://llmstxt.org/): the convention this file follows
      """
    ]
    |> IO.iodata_to_binary()
  end

  @doc "`/llms-full.txt`."
  def full(base) do
    [
      index(base),
      "\n\n---\n\n# Full documentation\n\n",
      "Every page linked above, inlined for agents that would rather take one fetch than crawl #{length(inlined_slugs())} links. Source of truth is the same markdown published at `#{base}/docs`.\n",
      Enum.map(@corpus, fn {section, pages} ->
        ["\n\n---\n\n# ", section, "\n", Enum.map(pages, &inlined_page(&1, base))]
      end),
      "\n\n---\n\n# SKILL.md (external)\n\n",
      "The block below is also published at `#{base}/skill`. Drop it into `~/.claude/skills/fountain/SKILL.md` (or the equivalent for your agent) so the agent has the operational knowledge loaded as a skill.\n\n",
      "```markdown\n",
      skill(),
      "\n```\n"
    ]
    |> IO.iodata_to_binary()
  end

  defp link_line(entry, base) do
    {slug, title, blurb} = normalize(entry)
    ["- [", title, "](", base, Site.Manual.path_for_slug(slug), "): ", blurb, "\n"]
  end

  defp inlined_page(entry, base) do
    {slug, title, _blurb} = normalize(entry)
    {:ok, %{body: body}} = Site.Manual.get(slug)

    [
      "\n\n## ",
      title,
      " (`",
      Site.Manual.path_for_slug(slug),
      "`)\n\n",
      absolutize(body, base),
      "\n"
    ]
  end

  # The preprocessing rewrites a page's relative `.md` links to root-relative
  # `/docs/...` paths, which is right for the browser and wrong here: these
  # files are read detached, with no page for a link to be relative to.
  defp absolutize(body, base), do: String.replace(body, "](/", "](" <> base <> "/")

  defp normalize({slug, title, blurb}), do: {slug, title, blurb}

  defp normalize({slug, blurb}) do
    {:ok, %{title: title}} = Site.Manual.get(slug)
    {slug, title, blurb}
  end
end
