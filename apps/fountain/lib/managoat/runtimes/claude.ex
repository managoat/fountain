defmodule Managoat.Runtimes.Claude do
  @moduledoc """
  Anthropic Claude runtime — provisioning only.

  Turns speak ACP through the pinned `claude-agent-acp` adapter
  (`Managoat.Runtimes.ACP`); the CLI argv builder that used to live here went
  with the legacy spawn path. What remains is the half ADR 0014 deliberately
  kept: how credentials, skills and MCP servers get into the sandbox.

  The adapter runs on the Claude Agent SDK, which reads the same skills tree
  as the CLI (`/home/sprite/.claude/skills`, verified live 2026-08-10) and
  honours the same credential env vars.

  ## MCP servers are provisioned, not delivered over ACP (#837)

  ACP defines a session-scoped channel for MCP servers (`session/new`'s
  `mcpServers`), and `Managoat.ACP.Peer` sends the agent's servers
  there correctly (pinned by `peer_mcp_test.exs`). But `claude-agent-acp`
  0.66–0.70 never launched stdio servers passed that way — reproduced
  standalone, upstream bug [agentclientprotocol/claude-agent-acp#883]. On
  the 0.75.1 pin (2026-09-07), and again on 0.81.2 (2026-09-25), a stdio
  server passed only over `session/new` *does* reach the model, and a server
  named on both paths is registered once; `http`/`sse` entries over the
  session-scoped path are not yet measured, which is why this provisioning
  stays until they are.

  So `write_config/2` provisions the servers into the sandbox instead, as a
  project `.mcp.json` plus `enableAllProjectMcpServers` in
  `~/.claude/settings.json` — which the CLI loads via its `settingSources`.
  This path is verified working end-to-end (2026-08-19): the model calls
  `mcp__<server>__*` tools and gets results. It works on every provider (all
  share `HOME=/home/sprite`), and the `${VAR}` refs are already resolved
  because the caller hands us the substituted agent.

  When the upstream bug is fixed, the session-scoped path will start working
  too; at that point drop this provisioning to avoid double-registration
  (cf. the same lesson in `Managoat.Runtimes.Gemini`). Registered as
  `:claude_mcp_via_files` in `Managoat.Runtimes.Quirks`, which carries the
  re-probe procedure and is guarded by a test that fails if this function
  disappears without the entry.

  ## Models: the pinned CLI lists them itself, with one alias to pin

  The adapter advertises whatever the Claude Code binary bundled in its SDK
  reports, and `session/set_config_option` accepts only those rows (a full
  model id resolves onto the alias row that serves it). On the 0.81.2 pin
  (CLI 2.1.280) the org's additional models, Fable among them, are listed
  on a cold `session/new`, on an API key and on a Claude.ai OAuth token
  alike. Measured 2026-09-25 with a fresh `CLAUDE_CONFIG_DIR` per run and a
  real turn on `claude-fable-5-1`. Before it (0.75.1, CLI 2.1.257) they
  arrived only after a first session had cached them, which is why this
  module used to warm that cache at provisioning.

  The same CLI moved its `opus` alias to Opus 5.5, so `claude-opus-5` is
  refused unless the alias is pointed back at it with
  `ANTHROPIC_DEFAULT_OPUS_MODEL`. `model_env/1` returns that pair for a turn
  that asks for Opus 5. It is per process: one adapter serves one Opus.
  Registered as `:claude_opus_alias` in `Managoat.Runtimes.Quirks`.

  ## Thinking is shown only when asked for

  The 0.81.2 CLI defaults `showThinkingSummaries` to false, and the API then
  returns thinking with its display omitted: the adapter has no text to send,
  so no `agent_thought_chunk` reaches the host. `write_config/2` therefore
  always writes `showThinkingSummaries: true` into `~/.claude/settings.json`.
  Registered as `:claude_thinking_summaries`.
  """

  @behaviour Managoat.Runtimes

  alias Managoat.Runtimes.Layout

  @runtime "claude"

  # The project-scope config sits at the repo root the agent runs in, not
  # under the config directory — that is what makes it *project* scope.
  @mcp_config Path.join(Layout.cwd(@runtime), ".mcp.json")
  @settings Path.join(Layout.config_root(@runtime), "settings.json")

  @impl true
  def skills_root, do: Layout.skills_root(@runtime)

  @impl true
  def skills_sh_agent, do: Layout.skills_sh_agent(@runtime)

  @impl true
  def default_env(_agent, inference_credentials) do
    # OAuth token takes precedence — it bills against a Claude.ai
    # subscription (Pro/Team) instead of metered API usage. When set, we
    # do NOT also export ANTHROPIC_API_KEY: claude prefers the oauth
    # path, but mixing the two has caused observable surprises (auth
    # picked from the wrong env var, depending on CLI version), so we
    # pick exactly one here.
    oauth = Map.get(inference_credentials, :claude_code_oauth_token)
    api_key = Map.get(inference_credentials, :anthropic_api_key)

    credential =
      cond do
        is_binary(oauth) and oauth != "" -> [{"CLAUDE_CODE_OAUTH_TOKEN", oauth}]
        is_binary(api_key) and api_key != "" -> [{"ANTHROPIC_API_KEY", api_key}]
        true -> []
      end

    # A fresh sandbox's first session otherwise waits on the CLI's
    # non-essential traffic (see `:claude_nonessential_traffic` in
    # `Managoat.Runtimes.Quirks`). It also stops the auto-updater, which the
    # pinned adapter wants off anyway.
    credential ++ [{"CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC", "1"}]
  end

  @doc """
  Write the CLI's settings, and the agent's MCP servers when it has any (see
  the moduledoc for why this, not the ACP session-scoped channel).

  `~/.claude/settings.json` is written on every call, agent or not, because
  it carries `showThinkingSummaries` (see the moduledoc). A host that calls
  this on every provision and wake keeps an existing sandbox current.
  """
  @impl true
  def write_config(handle, agent) do
    # Both writes are idempotent, so a transport blip on a sprite that has
    # only just booted is retried rather than failing the provision: the
    # first filesystem call into a fresh sprite timed out once in prod and
    # took the whole conversation with it.
    case mcp_servers(agent) do
      servers when servers == %{} ->
        write_retrying(handle, @settings, settings(false))

      servers ->
        # Project-scope config the CLI reads via settingSources; `servers` is
        # already the Claude-Code shape (`%{name => %{"command"/"args"/"env"...}}`)
        # with `${VAR}` refs resolved by the caller.
        mcp_json = Jason.encode!(%{"mcpServers" => servers}, pretty: true)

        with :ok <- write_retrying(handle, @mcp_config, mcp_json) do
          write_retrying(handle, @settings, settings(true))
        end
    end
  end

  defp mcp_servers(%{mcp_servers: servers}) when is_map(servers), do: servers
  defp mcp_servers(_agent), do: %{}

  # With MCP servers, pre-approve the project's servers so the first turn does
  # not stall on an approval the sandbox has no human to answer. (Fountain's
  # ACP peer also auto-allows `session/request_permission`, but that only
  # fires mid-turn; pre-approval keeps the server connected from session start.)
  defp settings(false), do: Jason.encode!(%{"showThinkingSummaries" => true}, pretty: true)

  defp settings(true) do
    Jason.encode!(%{"showThinkingSummaries" => true, "enableAllProjectMcpServers" => true},
      pretty: true
    )
  end

  @doc """
  The env a turn on `model` needs in the adapter's process, beyond
  `default_env/2` (see the moduledoc). `claude-opus-5` points the CLI's `opus`
  alias back at Opus 5; every other model needs nothing.

  Accepts the id bare or with its `anthropic/` provider prefix. The pairs
  belong to the spawn, not the sandbox: an adapter already running with them
  serves only that Opus, so a host that reuses a process across turns has to
  respawn it when this answer changes.
  """
  @impl true
  def model_env("anthropic/" <> model), do: model_env(model)
  def model_env("claude-opus-5"), do: [{"ANTHROPIC_DEFAULT_OPUS_MODEL", "claude-opus-5"}]
  def model_env(_model), do: []

  defp write_retrying(handle, path, body) do
    case Managoat.Sandbox.Retry.with_backoff(
           fn -> Managoat.Sandbox.write_file(handle, path, body) end,
           label: "claude config write #{path}"
         ) do
      :ok -> :ok
      {:error, reason} -> {:error, {:runtime_config, path, reason}}
    end
  end

  @doc """
  Swaps `CLAUDE_CODE_OAUTH_TOKEN` for `ANTHROPIC_API_KEY` in an already-built
  env list — what a live turn asks for after the org has refused the OAuth
  token (#655). Left as-is (still carrying the doomed OAuth token) when no
  API key is on file: the caller decides what to tell the tenant when there
  is nothing to fall back to.

  Deliberately not folded into `default_env/2` as a "skip oauth" flag: that
  function runs at provisioning, before any turn has been attempted, so it
  has no way to know the token is bad. This is reached only after the specific
  ACP failure that says so.
  """
  @spec fall_back_to_api_key([{String.t(), String.t()}], %{atom() => String.t()}) ::
          [{String.t(), String.t()}]
  def fall_back_to_api_key(env, inference_credentials) do
    case Map.get(inference_credentials, :anthropic_api_key) do
      key when is_binary(key) and key != "" ->
        env
        |> Enum.reject(fn {k, _v} -> k == "CLAUDE_CODE_OAUTH_TOKEN" end)
        |> List.keystore("ANTHROPIC_API_KEY", 0, {"ANTHROPIC_API_KEY", key})

      _ ->
        env
    end
  end
end
