defmodule Managoat.Runtimes.Layout do
  @moduledoc """
  Where a runtime keeps its files inside a sandbox — one table, derived
  everywhere else.

  Every path Fountain writes for a runtime has the same shape:

      <home>/<config_dir>/<leaf>

  and each runtime module used to restate its own half of that from memory.
  `skills_root/0` derived it correctly; `Managoat.Runtimes.Instructions`
  derived it again with `/home/sprite` hardcoded; `Managoat.Runtimes.Gemini`
  (and the opencode runtime, since removed) each named a workspace directory that
  `Managoat.Runtimes.ACP`'s adapter table then named a second time — with a
  comment admitting the mirror.

  That duplication was not merely untidy, it was wrong: opencode and gemini
  run with `HOME=/tmp` (see `home/1`), so their system prompts were being
  written to `/home/sprite/...`, where neither CLI looks. The agent ran on its
  CLI's default persona and nothing reported it. Deriving both the HOME export
  and the instructions path from the same row makes that class of drift
  unrepresentable.

  ## The table

  | runtime  | home           | config_dir        | instructions   |
  |----------|----------------|-------------------|----------------|
  | claude   | `/home/sprite` | `.claude`         | `CLAUDE.md`    |
  | codex    | `/home/sprite` | `.codex`          | `AGENTS.md`    |
  | gemini   | `/tmp`         | `.gemini`         | `GEMINI.md`    |

  This is layout only — where files go, and which on-disk dialect writes
  them. What goes *in* those files (credentials, MCP servers, the agent's
  prompt) stays with the runtime modules, and the imperative bootstrap each
  runtime needs stays in its `prepare_sandbox/3`. See `Managoat.Runtimes`.
  """

  # The sandbox image's own home directory. `/home/sprite` is the convention
  # `Managoat.Sandbox` documents (its `host_path/2` is the identity on the
  # hosted providers and maps this directory on a self-hosted runner), not a
  # host application's setting, so it is fixed here rather than taken as an
  # argument. A runtime whose `home` matches inherits it and exports nothing;
  # one that differs gets an explicit HOME (see `home_env/1`).
  @image_home "/home/sprite"

  @layouts %{
    "claude" => %{
      home: @image_home,
      config_dir: ".claude",
      instructions_file: "CLAUDE.md",
      cwd: @image_home
    },
    "codex" => %{
      home: @image_home,
      config_dir: ".codex",
      instructions_file: "AGENTS.md",
      cwd: @image_home
    },
    # HOME=/tmp: gemini-cli aborts during init if it cannot rename
    # `~/.gemini/projects.json.tmp` onto `projects.json`, and that rename
    # errors across /home/sprite's ACL boundary even though plain writes
    # succeed. The workspace is separate again because gemini walks up from
    # cwd looking for a `.git` and trips the same perms on /home/sprite;
    # `Managoat.Runtimes.Gemini.prepare_sandbox/3` git-inits exactly this
    # directory.
    "gemini" => %{
      home: "/tmp",
      config_dir: ".gemini",
      instructions_file: "GEMINI.md",
      cwd: "/tmp/gemini-workspace"
    }
  }

  @type runtime :: String.t()

  @doc "Every runtime with a layout. Sorted, so callers get a stable order."
  @spec runtimes() :: [runtime()]
  def runtimes, do: @layouts |> Map.keys() |> Enum.sort()

  @doc """
  The runtime's HOME inside the sandbox.

  Not always the image's own: two runtimes are moved to `/tmp` to dodge a
  rename that fails across `/home/sprite`'s ACL boundary. Returns nil for a
  runtime we do not know.
  """
  @spec home(runtime()) :: String.t() | nil
  def home(runtime), do: get_in(@layouts, [runtime, :home])

  @doc """
  The `HOME` pair to export for this runtime, or `[]` when the image's own
  home is already right.

  Meant to be appended to a runtime's `default_env/2`, so the HOME the
  process gets and the HOME the provisioning paths are built from cannot
  disagree.
  """
  @spec home_env(runtime()) :: [{String.t(), String.t()}]
  def home_env(runtime) do
    case home(runtime) do
      nil -> []
      @image_home -> []
      other -> [{"HOME", other}]
    end
  end

  @doc "The runtime's config directory, absolute: `<home>/<config_dir>`."
  @spec config_root(runtime()) :: String.t() | nil
  def config_root(runtime) do
    with home when is_binary(home) <- home(runtime),
         dir when is_binary(dir) <- get_in(@layouts, [runtime, :config_dir]) do
      Path.join(home, dir)
    else
      _ -> nil
    end
  end

  @doc """
  Absolute path the runtime's CLI scans for skills, written as
  `<skills_root>/<name>/SKILL.md` by `Managoat.Runtimes.Skills`.

  Every runtime puts this directly under its config root; none of them has
  ever needed to differ, which is why it is derived rather than listed.
  """
  @spec skills_root(runtime()) :: String.t() | nil
  def skills_root(runtime) do
    case config_root(runtime) do
      nil -> nil
      root -> Path.join(root, "skills")
    end
  end

  @doc """
  The user-level instructions file the runtime reads at session start — where
  the agent's `system` prompt is delivered. See
  `Managoat.Runtimes.Instructions`.
  """
  @spec instructions_path(runtime()) :: String.t() | nil
  def instructions_path(runtime) do
    with root when is_binary(root) <- config_root(runtime),
         file when is_binary(file) <- get_in(@layouts, [runtime, :instructions_file]) do
      Path.join(root, file)
    else
      _ -> nil
    end
  end

  @doc """
  Working directory the agent runs in — the cwd handed to the ACP session,
  and the workspace a runtime's `prepare_sandbox/3` git-inits when it needs
  one. Returns nil for a runtime we do not know; `Managoat.Runtimes.ACP.cwd/1`
  is where the fallback for that lives.
  """
  @spec cwd(runtime()) :: String.t() | nil
  def cwd(runtime), do: get_in(@layouts, [runtime, :cwd])
end
