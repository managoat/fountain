defmodule Managoat.Runtimes.Gemini do
  @moduledoc """
  Google Gemini CLI runtime.

  Provisioning only. Gemini speaks ACP since #659, so a turn spawns
  `gemini --acp` (`Managoat.Runtimes.ACP`) and the prompt, the model, the
  session id and the MCP servers all travel over the protocol rather than in
  argv. This module is what remains: the workspace, the skills paths, the
  settings file and `GEMINI_API_KEY`.

  `build_command/5` is gone with #941. It was the last implementation of that
  callback and the last place Fountain passed a vendor permission-bypass flag
  (`--approval-mode yolo`, matching the `--dangerously-*` flags claude, codex
  and opencode lost when their legacy spawn paths were deleted). Permissions
  are now a policy (#939) answered per tool over `session/request_permission`,
  with `ask` reaching a human (#940).

  Two things that lived in that argv and did not disappear with it:

  * **the model.** `--model` took the bare id, stripped from the canonical
    `google/` prefix. ACP pins it per session instead — gemini advertises
    `models`, so `Peer` sends `session/set_model` (see "model selection" in
    `acp/peer_test.exs`). The #553 regression it guarded against is still
    guarded, one layer down.
  * **`--resume`.** It re-entered "the most recent conversation in the
    workspace", correct only while one conversation ever ran per workspace.
    ACP names the session, which is the whole reason the conversion was worth
    doing.

  Auth: `GEMINI_API_KEY` exported into the sprite.
  """

  @behaviour Managoat.Runtimes

  alias Managoat.Runtimes.Layout

  @runtime "gemini"

  # Run gemini from a workspace dir we own and have git-init'd; avoids
  # the noisy `[WARN] [MemoryDiscovery] EACCES at /home/sprite/.git`
  # message (gemini walks up from cwd looking for .git, and /home/sprite's
  # perms trip it).  Also gives MemoryDiscovery a real workspace root
  # to anchor on instead of crawling /home. `Managoat.Runtimes.Layout` owns
  # the path, and the ACP session runs in the same place because it reads
  # the same row.
  @workdir Layout.cwd(@runtime)

  @impl true
  def skills_root, do: Layout.skills_root(@runtime)

  @impl true
  def skills_sh_agent, do: Layout.skills_sh_agent(@runtime)

  @impl true
  def default_env(_agent, inference_credentials) do
    base =
      case Map.get(inference_credentials, :gemini_api_key) do
        nil -> []
        "" -> []
        key -> [{"GEMINI_API_KEY", key}]
      end

    # gemini-cli aborts during init if it can't rename
    # `~/.gemini/projects.json.tmp` → `projects.json`. The sprite user
    # can write into /home/sprite/.gemini at first glance (ACLs let `ls`
    # and most writes through), but rename across that boundary errors
    # out. /tmp side-steps it cleanly. Mirrors the same fix we needed
    # for opencode's `~/.opencode` access path. The path itself lives in
    # `Managoat.Runtimes.Layout`, so the HOME gemini gets and the HOME
    # Fountain writes its config under are the same one by construction.
    base ++ Layout.home_env(@runtime)
  end

  # Gemini reads user-scope MCP servers from `$HOME/.gemini/settings.json`,
  # under `mcpServers` (camelCase, same shape as Claude). Because we run
  # with HOME=/tmp, write there only — duplicating into /home/sprite
  # was making gemini register every MCP tool twice on startup and
  # spam the log with `Tool ... already registered. Overwriting.` lines.
  @settings Path.join(Layout.config_root(@runtime), "settings.json")

  @impl true
  def write_config(_handle, nil), do: :ok
  def write_config(_handle, %{mcp_servers: m}) when m == %{} or is_nil(m), do: :ok

  def write_config(handle, %{mcp_servers: mcp_servers}) do
    payload = Jason.encode!(%{"mcpServers" => mcp_servers}, pretty: true)

    # Idempotent, so a transport blip on a fresh sprite is retried; a write
    # that still fails is reported, not swallowed — the agent would otherwise
    # start with none of its servers and no record of why.
    case Managoat.Sandbox.Retry.with_backoff(
           fn -> Managoat.Sandbox.write_file(handle, @settings, payload) end,
           label: "gemini config write"
         ) do
      :ok -> :ok
      {:error, reason} -> {:error, {:runtime_config, @settings, reason}}
    end
  end

  # The CLI the image would carry, for a sandbox that has none. Gemini speaks
  # ACP natively, so there is no adapter install to bring it; the Sprites and
  # E2B images ship it, and a self-hosted runner does not, where every turn
  # exited 127 (`gemini: No such file or directory`, 2026-10-06). Pinned
  # because this install is ours: 0.59.0 is the newest release the quirks in
  # `Managoat.Runtimes.Quirks` were measured against. An image's own copy wins.
  @cli_package "@google/gemini-cli@0.59.0"

  # Install the CLI when it is missing, then make sure the workspace exists
  # and is a git repo; gemini's MemoryDiscovery is happy as long as it finds
  # *some* .git when it walks up from cwd.
  @impl true
  def prepare_sandbox(handle, _agent, sprite_env) do
    script = """
    set -e
    if ! command -v gemini >/dev/null; then
      npm install -g --no-progress --silent #{@cli_package}
    fi
    if [ ! -d #{@workdir}/.git ]; then
      mkdir -p #{@workdir}
      cd #{@workdir}
      git init -q
      git config user.email aod@local
      git config user.name AoD
    fi
    """

    # The session-store workaround travels with the workspace (#659): it has to
    # be on disk before the first turn ends, since that is when it first runs.
    _ = Managoat.Runtimes.Gemini.SessionStore.install(handle)

    # Long enough for the ~120 MB install on a sandbox without the CLI; a
    # sandbox with it skips the install and returns in well under a second.
    case Managoat.Sandbox.exec(handle, "bash", ["-lc", script],
           env: sprite_env,
           timeout: 180_000
         ) do
      {:ok, _out, 0} -> :ok
      {:ok, _out, code} -> {:error, {:gemini_workspace_init_exit, code}}
      {:error, reason} -> {:error, {:gemini_workspace_init, reason}}
    end
  end
end
