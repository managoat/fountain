defmodule FountainWeb.LlmsController do
  @moduledoc """
  LLM-discovery surface. Implements the llms.txt convention
  (https://llmstxt.org/) plus an external `SKILL.md` for Claude Code and
  similar agentic IDEs.

  Three endpoints:

    * `GET /llms.txt`      — short index pointing at the bits an LLM needs
    * `GET /llms-full.txt` — every page the index links, inlined, plus the skill
    * `GET /skill`         — the external `SKILL.md` only, drop-in for `~/.claude/skills/fountain/`

  All three are public, plain-text, no auth. The base URL embedded in the
  output is `Application.get_env(:fountain, :public_url)` so a self-hosted
  instance points at itself.

  ## Why this points at `/docs` and not `/help`

  It used to link `/help/:topic`. Those routes live in `live_session
  :authenticated` — an unauthenticated fetch renders the app shell, whose only
  text is "Sign in". So every Concepts link in the index resolved to a login
  page for the one audience the file exists for, and nobody noticed because
  the content was *also* inlined into `/llms-full.txt`, which is the path most
  agents take. An agent that followed the index instead struck out seven times
  in a row.

  `/docs` is public, server-rendered, and the full manual. Everything here is
  built from `Fountain.Docs`, so a link and its inlined body cannot disagree,
  and `@corpus` is checked against the compiled page list at compile time — a
  page renamed in `docs/nav.yml` breaks the build rather than shipping a dead
  link in the file whose entire job is to be followed by a machine.
  """

  use FountainWeb, :controller

  # The pages `/llms.txt` links and `/llms-full.txt` inlines, in reading order.
  # `{slug, blurb}`, or `{slug, title, blurb}` where the nav title does not read
  # well out of the sidebar (three of them are just "Overview"). The default
  # title comes from `Fountain.Docs`, so it cannot drift from the nav.
  # Slug `""` is the docs home page (`/docs`).
  #
  # This is deliberately not all of `Fountain.Docs.nav()`. The full manual is
  # ~490 KB, over half of it operator runbooks (Kubernetes, Stripe, backups)
  # that an agent calling the API has no use for. What is inlined is the
  # "use Fountain" half, ~230 KB. The rest is linked under "More on /docs",
  # labelled as not inlined.
  @corpus [
    {"Get started",
     [
       {"", "What Fountain is",
        "the problem it solves, what it does about it, and `brew install` + `fountain auth login`"},
       {"tour",
        "forty lines of SDK that build an agent which clones a repo and opens a real pull request, then revise it on the same live sandbox"},
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
       {"concepts/teammates",
        "a conversation that continues, bound to the reserved `fountain:team` channel, and why it is not a fifth primitive"},
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
       {"python-sdk",
        "Python: `fountain.run(prompt, agent=agent, vault=vault)`, waitable, streamable, resumable"},
       {"reference/webhooks", "event payloads and delivery"},
       {"reference/conversation-states", "the lifecycle, and every terminal state"}
     ]},
    {"Catalog",
     [
       {"catalog", "Catalog", "everything you can name in an agent spec"},
       {"catalog/runtimes", "the four agent CLIs side by side"},
       {"catalog/runtimes/claude",
        "Anthropic's Claude Code, headless: transport, skills root, which credential it uses"},
       {"catalog/runtimes/codex", "OpenAI's Codex CLI, headless"},
       {"catalog/runtimes/opencode", "the only runtime that can reach more than one provider"},
       {"catalog/runtimes/gemini", "Google's Gemini CLI, headless"},
       {"catalog/skills", "how skills mount per runtime, and the injection order"},
       {"catalog/skills/fountain",
        "the bundled skill that lets an agent inside a sandbox spawn more"},
       {"catalog/skills/create-team", "the bundled skill that proposes a roster and creates it"},
       {"catalog/mcp-servers", "what you can attach, and `${VAR}` substitution in the config"},
       {"catalog/mcp-servers/fountain-team", "lets a teammate see the roster and message it"}
     ]},
    {"Build on it",
     [
       {"build", "Build a chat app", "the shape everyone clones, and why"},
       {"integrations/clients", "Plug into Fountain",
        "editors over ACP, AG-UI, plugin hosts, relays, or your own code"},
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
       {"configuration", "every environment variable the server reads"},
       {"troubleshooting", "Troubleshooting", "start from the symptom you can see"}
     ]}
  ]

  # Linked but not inlined. Real pages, off the path of "use Fountain".
  @more [
    {"architecture", "how the server, the sandboxes and the runners fit together"},
    {"build/team-chat", "that chat app, end to end"},
    {"build/pieces", "what each piece of it does"},
    {"setup", "Local setup", "the toolchain for hacking on Fountain itself, not for using it"},
    {"changelog", "release notes"}
  ]

  # A slug that no longer exists is a dead link in a machine-readable index.
  # Fail the compile instead — same bargain `Fountain.Docs` makes with its nav
  # parser, and the same reason: a silently missing page is the bug.
  #
  # `Fountain.Docs` and not `Fountain.Manual` throughout this module, on
  # purpose. llms.txt is a hand-curated index of the CORE manual, and this
  # check is what keeps the corpus below from naming a page an extension owns
  # — which would be a core file pointing at something a core distribution does
  # not serve. It also has to be answerable at compile time, and the installed
  # set is not (ADR 0043: build-time install, runtime enable).
  @known MapSet.new(Fountain.Docs.slugs())

  for {slug, _title, _blurb} <-
        Enum.map(
          Enum.flat_map(@corpus, fn {_s, pages} -> pages end) ++ @more,
          fn
            {slug, title, blurb} -> {slug, title, blurb}
            {slug, blurb} -> {slug, nil, blurb}
          end
        ) do
    unless MapSet.member?(@known, slug) do
      raise """
      FountainWeb.LlmsController lists docs page #{inspect(slug)}, which \
      Fountain.Docs does not have. Either it was renamed in docs/nav.yml or the \
      slug is wrong. Known slugs: #{@known |> Enum.sort() |> Enum.join(", ")}\
      """
    end
  end

  def index(conn, _params) do
    send_text(conn, render_index(base_url()))
  end

  def full(conn, _params) do
    send_text(conn, render_full(base_url()))
  end

  def skill(conn, _params) do
    send_text(conn, read_skill())
  end

  ## ─── Rendering ────────────────────────────────────────────────────────────

  defp render_index(base) do
    [
      """
      # Fountain

      > Fountain is a multi-tenant service for running sandboxed coding agents. It provisions an isolated sandbox per conversation, mounts a preconfigured environment (packages, repos, env vars, MCP servers, skills), and runs the agent CLI — claude, codex, gemini, or opencode — inside. Use it to delegate, fan out, or parallelize coding agents from your own scripts, CI, or IDE.

      The four primitives:

      - **Environment** — sandbox shape (apt packages, env vars, repos to clone, networking allowlist, setup script)
      - **Vault** — free-floating bag of encrypted secret overrides, picked per-conversation; layered over the env's secrets
      - **Agent** — named runtime config (runtime + model + system prompt + skills + MCP servers + an environment)
      - **Conversation** — one running instance of an agent inside a freshly provisioned sandbox, streamable over SSE

      Reach for it instead of your agent's own sub-agents when you need isolation from your machine, a different set of credentials per run, or a runtime that isn't the one you're sitting in. It is the same delegation, on a machine that is not yours and does not hold your keys.

      Public instance: <#{base}>. Source: <https://github.com/managoat/fountain>. Getting an account: sign in with GitHub at <#{base}>, then `fountain auth login`. Self-hosting is a supported first-class path — see "Run your own instance" below.

      ## Read this first if you are an agent

      - [/llms-full.txt](#{base}/llms-full.txt): every page linked below, inlined as one document (~230 KB). One fetch instead of #{corpus_count()}.
      - [/skill](#{base}/skill): a `SKILL.md` to drop into `~/.claude/skills/fountain/` so Claude Code (or anything that loads SKILL.md) can drive Fountain without reading the manual first.

      ```sh
      mkdir -p ~/.claude/skills/fountain
      curl -fsSL #{base}/skill > ~/.claude/skills/fountain/SKILL.md
      ```

      ## API contract

      - [OpenAPI 3 spec](#{base}/api/openapi.json): machine-readable, the authority on request and response shapes
      - [Swagger UI](#{base}/api/docs): interactive try-it, click "Authorize" to set your bearer token
      - [TypeScript SDK](https://www.npmjs.com/package/@managoat/fountain-sdk): `npm install @managoat/fountain-sdk`
      - [Python SDK](#{base}/docs/python-sdk): `pip install fountain-agent-sdk`
      - [CLI (Homebrew)](https://github.com/managoat/homebrew-tap): `brew install managoat/tap/fountain`
      - [Example agent specs](https://github.com/jhgaylor/agent-specs): public manifest tree you can `fountain apply`
      """,
      Enum.map(@corpus, fn {section, pages} ->
        ["\n## ", section, "\n\n", Enum.map(pages, &link_line(&1, base)), ""]
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

  defp link_line(entry, base) do
    {slug, title, blurb} = normalize(entry)

    [
      "- [",
      title,
      "](",
      base,
      Fountain.Docs.path_for_slug(slug),
      "): ",
      blurb,
      "\n"
    ]
  end

  defp render_full(base) do
    [
      render_index(base),
      "\n\n---\n\n# Full documentation\n\n",
      "Every page linked above, inlined for agents that would rather take one fetch than crawl #{corpus_count()} links. Source of truth is the same markdown served at `#{base}/docs`.\n",
      Enum.map(@corpus, fn {section, pages} ->
        ["\n\n---\n\n# ", section, "\n", Enum.map(pages, &inlined_page(&1, base))]
      end),
      "\n\n---\n\n# SKILL.md (external)\n\n",
      "The block below is also served at `#{base}/skill`. Drop it into `~/.claude/skills/fountain/SKILL.md` (or the equivalent for your agent) so the agent has the operational knowledge loaded as a skill.\n\n",
      "```markdown\n",
      read_skill(),
      "\n```\n"
    ]
    |> IO.iodata_to_binary()
  end

  defp inlined_page(entry, base) do
    {slug, title, _blurb} = normalize(entry)
    {:ok, %{body: body}} = Fountain.Docs.get(slug)

    [
      "\n\n## ",
      title,
      " (`",
      Fountain.Docs.path_for_slug(slug),
      "`)\n\n",
      absolutize(body, base),
      "\n"
    ]
  end

  # `Managoat.Docs.Compiler` rewrites a page's relative `.md` links to
  # root-relative `/docs/...` paths, which is right for the browser and wrong
  # here: `/llms-full.txt` is read as a detached string, with no page for a
  # relative link to be relative to. Give every in-page link the host back.
  defp absolutize(body, base), do: String.replace(body, "](/", "](" <> base <> "/")

  # `{slug, blurb}` takes its title from the nav; `{slug, title, blurb}` overrides
  # it, for the pages whose nav title only makes sense next to its siblings.
  defp normalize({slug, title, blurb}), do: {slug, title, blurb}

  defp normalize({slug, blurb}) do
    {:ok, %{title: title}} = Fountain.Docs.get(slug)
    {slug, title, blurb}
  end

  defp corpus_count, do: @corpus |> Enum.flat_map(fn {_s, pages} -> pages end) |> length()

  ## ─── File reads ───────────────────────────────────────────────────────────

  # sobelow_skip ["Traversal.FileModule"] — fixed priv path, no user input.
  defp read_skill do
    path = Path.join([priv_dir(), "external_skills", "fountain", "SKILL.md"])

    case File.read(path) do
      {:ok, body} ->
        body

      {:error, _} ->
        "# fountain skill\n\n_(missing — bundle did not include external_skills/fountain/SKILL.md)_\n"
    end
  end

  defp priv_dir, do: :fountain |> :code.priv_dir() |> to_string()

  ## ─── Helpers ──────────────────────────────────────────────────────────────

  defp base_url, do: Fountain.PublicUrl.base()

  defp send_text(conn, body) do
    conn
    |> put_resp_content_type("text/plain", "utf-8")
    |> send_resp(200, body)
  end
end
