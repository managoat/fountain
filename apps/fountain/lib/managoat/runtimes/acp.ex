defmodule Managoat.Runtimes.ACP do
  @moduledoc """
  Whether a turn speaks the Agent Client Protocol, and what to spawn if it does.

  This module is the *provisioning* side of the ACP path — which adapter,
  which version, how it gets into the sprite — and it deliberately holds no
  protocol state. The session lives in `Managoat.ACP.Peer`, which outlives the
  turn and is closed by its owner when the sandbox wake ends. The issue
  numbers in this file are Fountain's, where the path was built (ADR 0014
  there is the decision record).

  ## The only path

  Every supported runtime speaks ACP, unconditionally. The per-agent
  `metadata["acp"]` flag is dead: it began as gate 2's opt-in, flipped to an
  opt-out when ACP became the default, and was removed when the legacy spawn
  path for these runtimes was deleted — there is nothing left to opt out
  into. `build_command/5` survives on no runtime that is here: all three are
  on the ACP path since #659.

  ## Which runtimes

  All three have adapter entries and all three are shippable — gemini since #659,
  behind the workaround described below. The two ends of the resumption story
  gate 1 mapped are claude and gemini:

  Claude advertises `sessionCapabilities.resume`, so a turn costs a handshake
  and nothing else. Gemini advertises only `loadSession`, and `session/load`
  replays the entire conversation before responding — under one connection per
  turn that is the whole history re-streamed on every turn after the first.
  `Peer`'s replay-discard exists for exactly this, and Gemini is the runtime
  that actually exercises it.

  Converting Gemini was worth it despite the replay, because its legacy resume
  was the worst thing we shipped: `gemini --resume` re-entered "the most recent
  conversation in the workspace", correct only while one conversation ever ran
  per workspace — an invariant held by accident and asserted by no test. ACP
  names the session. That argv is deleted (#941), and with it the last vendor
  permission-bypass flag Fountain passed.

  **Gemini was held back for eleven days** (#659) by a defect in its own
  session store, and now ships behind a workaround for it. The mechanism is
  worth keeping on record because the workaround is shaped by it, and because
  it is the thing to delete when upstream lands.

  Diagnosed against a live 0.53.0 on 2026-08-11 (#658). Turn 1 does write a
  session, to `$HOME/.gemini/tmp/<project>/chats/session-<ISO minute>-<first 8
  of the id>.jsonl`, and gemini's own `--list-sessions` finds it. **Loading it
  is what destroys it.** `session/load` builds a fresh config on the same
  session id *before* looking the session up, and that config's chat recorder
  takes its new-session branch: it computes the same file name — the id's first
  8 characters plus the current wall-clock minute — and appends a header and a
  `$set` carrying a `messages` array holding only its `<session_context>`
  bootstrap. Gemini's own reader treats a `$set.messages` as a **replacement**,
  and a user message beginning `<session_context>` is ignored content, so the
  file it just appended to now has no resumable content. It drops out of
  `listSessions()`, and `findSession` reports `-32603` / "No previous sessions
  found for this project" — about a session whose transcript is still sitting
  in the same file, above the line that erased it.

  That is why it looked random. The collision is bucketed by **minute**: a
  resume in the same minute as the previous turn poisons the session's own file
  and always fails; a minute later the poison lands in a sibling file and the
  load succeeds. The "2 successes to 4 failures" was a wall clock, not a race.
  Verified in both directions on live sprites.

  Waiting is not a workaround: a *second* consecutive resume failed even with a
  minute between every turn, and afterwards every older session file for that
  project was gone. One resume is not a conversation.

  It is also destructive rather than merely unreliable — a failed load leaves
  the session unloadable forever, so a user would lose the conversation, not
  just a turn.

  **Resolved by reaching into that store on purpose** (#659, 2026-08-22).
  `Managoat.Runtimes.Gemini.SessionStore` consolidates the chats directory at
  the end of every turn: keep the file with real content, delete the poisoned
  duplicates a load leaves behind, and park the survivor under a timestamp the
  recorder cannot produce. An earlier draft of this paragraph said Fountain
  could not do this without reaching into another product's private store —
  which is exactly what it does, deliberately and behind a comment naming
  google-gemini/gemini-cli#28775 so it is deleted when that lands.

  Renaming once is not enough, and this is why the "wait out the minute"
  suggestion above also fails: after every load *two* files carry the same
  session id, and gemini dedupes by id keeping the later `lastUpdated`, which
  is the poisoned one. Verified live on 0.56.0 — five consecutive turns inside
  one wall-clock minute, history growing 3 → 5 → 7 → 9 → 11, content planted
  before the first reload recalled every turn.

  Codex advertises `loadSession` *and* `sessionCapabilities.resume`, so it
  resumes as cheaply as Claude does, through an adapter package we install
  and pin.

  ## The adapter is pinned, and that is load-bearing

  Nothing about the runtime CLIs is version-pinned today: claude, codex and
  gemini arrive with the sprite base image. That is survivable for a CLI whose argv changes slowly. It
  is not survivable for an adapter whose `initialize` response decides whether
  the feature works at all — an unpinned adapter can silently stop advertising
  `sessionCapabilities.resume` and downgrade every conversation to a full
  history replay per turn, with no error anywhere.

  So the version is pinned here, the install is idempotent, and the pin moves
  in a PR that says why.
  """

  # Per runtime: how ACP is reached. Where the agent *runs* is not here —
  # that is layout, and it lives in `Managoat.Runtimes.Layout` alongside the
  # workspace each runtime's `prepare_sandbox/3` git-inits. This table used
  # to carry its own `cwd` copy, with a comment admitting the mirror.
  #
  # `package` nil means native support — the runtime speaks ACP itself and
  # arrives with the sprite base image, so there is nothing to install and
  # nothing we can pin. That is a real difference in exposure, not a
  # convenience: an adapter we install is a supply-chain surface we version,
  # and a native flag is a surface the image owner versions for us.
  @adapters %{
    # Verified at gate 1 (2026-08-09) and live on 2026-08-10: advertises
    # `loadSession: true` and `sessionCapabilities.resume`; `resumeSession`
    # reattaches without replaying while `loadSession` calls
    # `replaySessionHistory`.
    #
    # 0.66.0 → 0.75.1 on 2026-09-07, for Fable 5.1. The adapter's model list
    # is whatever the Claude Code binary bundled in its SDK dependency reports,
    # and that binary refuses `claude-fable-5-1` below 2.1.255 ("Fable 5.1
    # (disabled) — Update to 2.1.255+"): 0.66.0 bundles SDK 0.3.220 = CLI
    # 2.1.220, 0.75.1 bundles SDK 0.3.257 = CLI 2.1.257. 0.75.1's
    # `session/set_config_option` also resolves a full model id onto the
    # alias row the CLI advertises (`claude-fable-5-1` → `claude-fable-5-1[1m]`),
    # which 0.66.0's exact match did not. Measured with real turns on haiku
    # and claude-fable-5-1: the prompt result's `usage` keeps the protocol
    # shape `Managoat.ACP.Usage.from_prompt_result/1` reads, and the two new
    # notifications (`_auth/status_update`, `usage_update`) fall through
    # `Managoat.ACP.Peer`'s unknown-notification clause. Re-probed
    # `:claude_mcp_via_files` at the same time; see `Managoat.Runtimes.Quirks`.
    #
    # 0.75.1 → 0.81.2 on 2026-09-25 (CLI 2.1.257 → 2.1.280), which lists the
    # org's additional models on a cold `session/new`, so the model-list
    # warm-up went. Measured against 0.75.1 with the same scenarios and real
    # turns, on an API key and on an OAuth token: `initialize` capabilities
    # (`loadSession`, `sessionCapabilities.resume`) are unchanged; resume keeps
    # context without replay; MCP over `.mcp.json` and over `session/new` both
    # reach the model; `_meta.claudeCode.options.maxTurns` still ends the turn;
    # the prompt result's `usage` keeps its fields. Additive only: `tool_call`
    # gains `name`, `usage_update` gains `_meta._claude/model`. Two changes
    # needed code: the `opus` alias now means Opus 5.5 (`:claude_opus_alias`)
    # and thinking needs `showThinkingSummaries` (`:claude_thinking_summaries`).
    # 0.77.0 stopped forwarding `claudeCode.options.agent`, which nothing here
    # sends.
    "claude" => %{
      bin: "claude-agent-acp",
      args: [],
      package: "@agentclientprotocol/claude-agent-acp",
      version: "0.81.2",
      entry: "dist/index.js"
    },
    # Native: `gemini --acp`. Advertises `loadSession: true` and **no**
    # `sessionCapabilities`, so every turn after the first pays a full replay
    # that `Peer` discards. Its cwd matters more than the others' — gemini
    # walks up from it looking for a `.git` — and both that path and the
    # `git init` that satisfies it now come from `Managoat.Runtimes.Layout`.
    # Shippable since #659. Gemini's own session store erases a session in the
    # act of loading it (google-gemini/gemini-cli#28775, still open on 0.56.0 —
    # the moduledoc has the mechanism), which held this entry back for eleven
    # days. `Managoat.Runtimes.Gemini.SessionStore` consolidates the store at
    # the end of every turn so the load cannot collide with what it is loading.
    # Delete that module and this comment when upstream lands — the
    # condition, and the procedure for checking it, are recorded as
    # `:gemini_session_store_consolidation` in `Managoat.Runtimes.Quirks`.
    "gemini" => %{
      bin: "gemini",
      args: ["--acp"],
      package: nil,
      version: nil
    },
    # Adapter, on the Codex App Server. The `zed-industries/codex-acp` that
    # earlier drafts named is archived; this is its successor under the
    # protocol org. Auth: `Codex.prepare_sandbox/3` writes the `auth.json`
    # that `codex login --with-api-key` would, and OPENAI_API_KEY is still
    # exported, so the adapter inherits whichever the CLI would have used.
    #
    # 1.10.0 → 2.2.2 on 2026-10-15, for turn usage (#1731): 1.10.0 answered
    # `session/prompt` with the usage of the turn's *last* model request, so a
    # turn that called tools was undercounted. 2.2.0 added `PromptTokenUsage`
    # (src/TokenCount.ts): the thread total at the end of the prompt minus the
    # total at its start, or the sum of each request's `last` when no start
    # total is known or the total went back. Codex arrives bundled, as before
    # (`@openai/codex` ^0.160.1 against ^0.153.3; nothing sets `CODEX_PATH`, so
    # the image's own `codex` is not the one that runs). Measured locally
    # against a mock Responses endpoint with Fountain's `CODEX_CONFIG` provider
    # and `MODEL_PROVIDER`: three requests in one prompt reported as their sum
    # (1.10.0: the last one); the same after `session/resume` and
    # `session/load` in a fresh process; a cancelled prompt and a prompt whose
    # stream failed report the requests that completed; `usage` is null when
    # none did. `initialize` is unchanged where Fountain reads it
    # (`loadSession`, `sessionCapabilities.resume`, `additionalDirectories`,
    # the `api-key` method), as are `reasoning_effort`, the boolean
    # `fast-mode`, `_meta.codex.error` and `_meta.codex.threadStatus`.
    # One change needed code: 2.0.0 made `read-only` mode really read-only and
    # moved the mode Fountain asks through to `workspace-write`
    # (`Fountain.Conversations.CodexApproval`). 2.2.2 reports no
    # `_meta.usageAccounting`, so codex turns carry no accounting claim.
    #
    # Installed from a manifest since 2026-10-15, like claude: npm took
    # ~12.6 s of a codex provision. The tree's weight is the platform package
    # (`@openai/codex-linux-x64`, an npm alias of `@openai/codex@<ver>-linux-x64`,
    # 163 MB packed), which the bundled `codex.js` resolves by its alias name
    # and starts on `process.execPath`, the Node the launcher picked.
    "codex" => %{
      bin: "codex-acp",
      args: [],
      package: "@agentclientprotocol/codex-acp",
      version: "2.2.2",
      entry: "dist/index.js"
    }
  }

  # The manifest for each adapter Managoat installs, read at compile time. Its
  # name carries the version, so a pin bumped without running
  # `scripts/acp-lock.exs` fails to compile rather than installing a stale tree.
  @manifests (for {runtime, %{package: package, version: version}} <- @adapters,
                  is_binary(package),
                  into: %{} do
                path =
                  Path.expand(
                    "../../../priv/runtimes/acp/#{package |> String.split("/") |> List.last()}@#{version}.tsv",
                    __DIR__
                  )

                @external_resource path
                {runtime, File.read!(path)}
              end)

  @doc """
  Runtimes that may actually be switched on.

  Distinct from having an adapter entry. A runtime is listed here only when a
  full turn *and* a resume have been observed against a live agent — a
  conversion that resumes unreliably is worse than the legacy path it replaces,
  because the user gets a working first turn and an agent with no memory on
  every turn after.
  """
  @spec supported_runtimes() :: [String.t()]
  def supported_runtimes do
    Map.keys(@adapters)
  end

  @doc """
  Where the agent runs.

  ACP carries `cwd` in `session/new`, and it is the *agent's* working
  directory rather than ours — a runtime that walks up from it looking for a
  repo (gemini does) behaves differently depending on what we say here.
  """
  @spec cwd(String.t()) :: String.t()
  def cwd(runtime), do: Managoat.Runtimes.Layout.cwd(runtime) || "/home/sprite"

  @doc """
  Whether this turn speaks ACP.

  A property of the runtime alone: supported runtimes always do, and for them
  the legacy spawn path no longer exists. Since #964 that is all three, so the
  false branch has no runtime left — it answers for a conversation row naming
  a runtime with no adapter entry.

  Takes the runtime string, not the agent, because a conversation outlives
  its agent (deleting one nilifies its reference) and the conversation row
  carries its own `runtime`. An agent map (`t:Managoat.Runtimes.agent/0`) is
  accepted for call sites that have one.
  """
  @spec enabled?(String.t() | Managoat.Runtimes.agent() | nil) :: boolean()
  def enabled?(%{runtime: runtime}), do: enabled?(runtime)
  def enabled?(runtime) when is_binary(runtime), do: runtime in supported_runtimes()
  def enabled?(_), do: false

  @doc """
  Argv for the adapter.

  No prompt, no session id, no mode: unlike `build_command/5` this says nothing
  about the turn, because under ACP the turn is carried by `session/prompt`
  over the connection rather than by the process's arguments. That difference
  is the entire architectural change, and it is why this does not implement the
  `Managoat.Runtimes` behaviour.
  """
  @spec command(String.t()) :: {String.t(), [String.t()]}
  def command(runtime) do
    case @adapters[runtime] do
      %{bin: bin, args: args} -> {bin, args}
      _ -> raise ArgumentError, "runtime #{inspect(runtime)} has no ACP adapter"
    end
  end

  @doc """
  Install the pinned adapter into a sprite.

  Runs at provision time rather than at spawn: by the time a turn spawns the
  sandbox may be suspended-and-resumed or policy-restricted, and an install
  failing there reads as a protocol bug rather than a missing package.

  In Fountain it starts as soon as the broker CA is installed and the network
  floor applied, and runs concurrently with the environment's packages, clone
  and setup script (`Fountain.Conversations.FreshProvision`'s
  `run_provisioning_pipeline/6`); the provision awaits it after the setup
  script. So it always runs *after* the network policy, through the broker. On
  an unrestricted sandbox that costs nothing. On a restricted one the
  allowlist has to include the npm registry, or the adapter install fails
  here.

  Idempotent on the exact pinned version: an image that already carries a
  different version is corrected rather than accepted, since "some adapter is
  installed" is precisely the state the pin exists to prevent.

  ## Where it lands, and how an install is recognised

  Each pinned version installs into its own directory,
  `/home/sprite/.local/share/managoat/acp/<name>@<version>`, which gets an
  `.installed` marker only once complete; `/home/sprite/.local/bin/<bin>`
  (on the sprite's PATH) is then pointed at its `launch` script by an atomic
  rename. The launcher starts the entry on the Node binary the install
  recorded, not on `node` from PATH: a sprite's is an nvm shim that added
  ~0.8 s to every adapter start. So the
  check that runs before every spawn is two file tests and no process start:
  the old one started the adapter twice to read `--version`, ~3.6 s on a
  fresh sprite (managoat/fountain, measured 2026-09-26). And an upgrade never
  rewrites files under a running adapter: the new version is a new directory,
  and only the link moves (the hazard managoat/fountain#2402 was about).

  ## Without npm, from a manifest

  Every installed adapter has a manifest in `priv/runtimes/acp/<name>@<version>.tsv`
  (written by `scripts/acp-lock.exs` from npm's own resolution) and installs without npm on
  the sandbox: `install/3` writes the manifest to the sandbox, then every
  package in it is downloaded in parallel, checked against its sha512
  integrity and unpacked into place. Sixteen workers share the manifest, and a
  worker takes a *shard* of packages rather than one: it fetches them over a
  single connection, so the install pays one handshake per shard instead of
  one per package. Large native packages are the exception and keep a
  connection each, streaming rather than landing on disk. Fetches have a
  5-second connect timeout, a 5-second low-speed timeout and a 30-second total
  timeout, with up to three fresh attempts; the first retry of a sharded
  package leaves its shard and fetches on its own. Failed attempts identify the package, step and elapsed time
  without exposing registry URLs or proxy credentials. npm spent most of a claude install's
  ~12 s in its own CPU; the manifest install measured 3.0 s. Platform
  packages are kept only when their os/cpu/libc match the sandbox, as npm
  would choose them. Nothing in these trees has an install script (the
  generator refuses one), so skipping npm skips nothing that runs. It also
  pins the whole tree, not only the adapter: npm resolved ranges at install
  time. On Sprites, a working image Claude >= 2.1.280 replaces the SDK's
  native optional package through `CLAUDE_CODE_EXECUTABLE`; the adapter and
  JavaScript dependencies stay pinned. Missing, older or unrecognised image
  binaries use the bundled CLI. E2B continues to use the bundled CLI.
  Image reuse accepts the image's model aliases, including removal of older
  model IDs. A removed recorded executable invalidates the installation so
  provisioning can select another image binary or install the bundled one.

  Any failure (no `curl`/`openssl`, a registry the sandbox cannot reach, an
  integrity mismatch, a manifest that could not be written) falls back to
  `npm install --prefix` into the same directory. The entire install, including
  this fallback, remains subject to the sandbox exec's 180-second deadline.
  """
  @spec install(sprite :: any(), String.t(), [{String.t(), String.t()}]) :: :ok | {:error, term()}
  def install(sprite, runtime, sprite_env)

  # Native ACP: the runtime speaks the protocol itself, and is already on the
  # sprite — gemini from the base image. Nothing to install, and nothing we
  # can pin either: the version floor is whatever the image carries, which
  # gate 1 recorded as an open exposure.
  def install(_handle, "gemini", _sprite_env), do: :ok

  def install(handle, runtime, sprite_env) do
    metadata = %{runtime: runtime, provider: handle.provider}

    Fountain.Telemetry.span([:adapter_install], metadata, fn ->
      with :ok <-
             Fountain.Telemetry.span(
               [:provision_step],
               Map.put(metadata, :step, "adapter_manifest"),
               fn ->
                 {write_manifest(handle, runtime), %{}}
               end
             ) do
        result =
          Managoat.Sandbox.exec(
            handle,
            "bash",
            ["-lc", install_script(runtime, handle.provider)],
            env: sprite_env,
            stderr_to_stdout: true,
            timeout: 180_000
          )

        case result do
          {:ok, out, 0} ->
            {:ok, Map.put(Managoat.Runtimes.InstallTiming.attributes(out), :outcome, :ok)}

          {:ok, out, code} ->
            error =
              {:error,
               {:acp_adapter_install_exit, code, String.slice(to_string(out), -2_000, 2_000)}}

            {error, Map.put(Managoat.Runtimes.InstallTiming.attributes(out), :outcome, :failed)}

          {:error, reason} ->
            {{:error, {:acp_adapter_install, reason}}, %{outcome: :failed}}
        end
      end
    end)
  end

  # A failed write is not fatal: the script finds no manifest and installs
  # with npm instead, which is slower and otherwise the same.
  defp write_manifest(handle, runtime) do
    case @manifests[runtime] do
      nil ->
        :ok

      manifest ->
        case Managoat.Sandbox.write_file(handle, manifest_path(runtime), manifest) do
          :ok -> :ok
          {:error, _} -> :ok
        end
    end
  end

  defp install_dir(runtime) do
    %{package: package, version: version} = @adapters[runtime]
    "/home/sprite/.local/share/managoat/acp/#{package_name(package)}@#{version}"
  end

  defp manifest_path(runtime), do: install_dir(runtime) <> ".tsv"

  defp package_name(package), do: package |> String.split("/") |> List.last()

  defp install_script(runtime, provider) do
    %{bin: bin, package: package, version: version, entry: entry} = @adapters[runtime]
    dir = install_dir(runtime)

    ~s"""
    set -e
    install_started=$SECONDS
    # A boundary reads two clocks, neither of which spawns a process: bash's
    # microsecond wall clock, and /proc/uptime's monotonic seconds. `date
    # +%s%3N` is deliberately absent. uutils coreutils truncates the *unpadded*
    # nanoseconds for %3N, so a reading taken in the first 100 ms of a second
    # keeps its leading digits and comes out up to 10x high: 9.7% of readings,
    # always high, by as much as 978 ms. That is how a phase came to outlast
    # the span enclosing it (#2908). Bare %N is zero-padded and correct, which
    # is why the per-package timings in manifest_install still use it.
    clock_mark() {
      local up='' wall=${EPOCHREALTIME//[!0-9]/}
      [ -n "$wall" ] || wall=$(( $(date +%s%N) / 1000 ))
      read -r up _ </proc/uptime 2>/dev/null || up=
      printf '%s %s' "$wall" "${up//[!0-9]/}"
    }
    # The phase in wall milliseconds, then the monotonic elapsed the host
    # checks it against. A monotonic clock cannot step, but /proc/uptime
    # resolves only 10 ms, too coarse for phases that finish in two, so the
    # wall figure stays the measurement and the monotonic one makes a clock
    # step visible as disagreement instead of silently wrong. `-` where the
    # sandbox has no /proc/uptime and there is no cross-check to report.
    report_phase() {
      local s=$2 n wall mono=-
      n=$(clock_mark)
      wall=$(( (${n%% *} - ${s%% *}) / 1000 ))
      if [ -n "${s##* }" ] && [ -n "${n##* }" ]; then
        mono=$(( (10#${n##* } - 10#${s##* }) * 10 ))
      fi
      printf '__MANAGOAT_INSTALL__ %s %s %s\\n' "$1" "$wall" "$mono"
    }
    printf '__MANAGOAT_INSTALL__ cache_hit 1\\n'
    step=setup
    trap 'rc=$?; printf "adapter install failed: step=%s exit=%s elapsed_s=%s\\n" "$step" "$rc" "$((SECONDS - install_started))" >&2' ERR
    want=#{version}
    dir=#{dir}
    link=/home/sprite/.local/bin/#{bin}
    entry="$dir/node_modules/#{package}/#{entry}"
    target="$dir/launch"
    installed() {
      [ -f "$dir/.installed" ] && [ "$(cat "$dir/.installed")" = "$want" ] &&
        { [ ! -f "$dir/.claude-executable" ] || [ -x "$(cat "$dir/.claude-executable")" ]; }
    }
    claude_executable=
    #{image_claude_fn(runtime, provider)}
    # Seconds.milliseconds for the install's own record, from the same
    # microsecond mark rather than the %3N that misreports it.
    now() { local m; m=$(clock_mark); m=${m%% *}; printf '%s.%s' "${m%??????}" "${m: -6:3}"; }
    #{manifest_install_fn()}
    #{launcher_fn()}
    # No `exit` at the top level: this runs under `bash -lc`, where the builtin
    # runs ~/.bash_logout, and the sprite's ends in `clear_console -q`, which
    # fails outside a console and turned a successful check into exit 1.
    if ! { installed && [ -x "$target" ] && [ "$(readlink "$link" 2>/dev/null)" = "$target" ]; }; then
      mkdir -p "$(dirname "$dir")"
      exec 9>"$dir.lock"
      t_lock=$(clock_mark)
      flock 9
      report_phase lock_wait "$t_lock"
      if ! installed; then
        printf '__MANAGOAT_INSTALL__ cache_hit 0\\n'
        t_probe=$(clock_mark)
        #{if runtime == "claude" and provider == :sprites, do: "select_image_claude", else: ""}
        report_phase image_probe "$t_probe"
        t_start=$(now)
        rm -rf "$dir.tmp"
        mkdir -p "$dir.tmp"
        # Which Node the launcher will run, resolved while the packages
        # download: through a PATH shim this takes as long as the shim does.
        rm -f "$dir.node"
        node -p process.execPath >"$dir.node" 2>/dev/null &
        node_pid=$!
        how=manifest
        t_manifest=$(clock_mark)
        if ! { [ -f "$dir.tsv" ] && manifest_install "$dir.tsv" "$dir.tmp"; }; then
          report_phase manifest "$t_manifest"
          if [ -f "$dir.tsv" ]; then echo "manifest install failed; installing #{package}@#{version} with npm" >&2; fi
          how=npm
          rm -rf "$dir.tmp"
          mkdir -p "$dir.tmp"
          npm_optional=()
          [ -z "$claude_executable" ] || npm_optional=(--omit=optional)
          step=npm
          t_npm=$(clock_mark)
          # npm may include proxy or registry credentials in error output.
          # The ERR trap reports only its step, exit status and elapsed time.
          npm install --prefix "$dir.tmp" --no-progress --silent --no-audit --no-fund "${npm_optional[@]}" #{package}@#{version} >/dev/null 2>&1
          report_phase npm "$t_npm"
        else
          report_phase manifest "$t_manifest"
        fi
        t_finalize=$(clock_mark)
        step=finalize
        t_fetched=$(now)
        chmod +x "$dir.tmp/node_modules/#{package}/#{entry}"
        if wait "$node_pid"; then mv -f "$dir.node" "$dir.tmp/.node"; else rm -f "$dir.node"; fi
        if [ -n "$claude_executable" ]; then
          printf '%s\n' "$claude_executable" >"$dir.tmp/.claude-executable"
        fi
        write_launcher "$dir.tmp"
        # When the install happened, and where its time went, for the next
        # slow one to explain itself: the phases, then the slowest packages.
        {
          printf 'method %s\nstart %s\nfetched %s\ninstalled %s\n' "$how" "$t_start" "$t_fetched" "$(now)"
          sort -k2 -rn "$dir.tmp/.timing" 2>/dev/null | head -5 | sed 's/^/package /'
        } >"$dir.tmp/.install-timing"
        rm -f "$dir.tmp/.timing"
        printf '%s' "$want" >"$dir.tmp/.installed"
        rm -rf "$dir"
        mv "$dir.tmp" "$dir"
        report_phase finalize "$t_finalize"
      fi
      # An install from before the launcher existed: add it, don't reinstall.
      if [ ! -x "$target" ]; then
        node -p process.execPath >"$dir/.node" 2>/dev/null || rm -f "$dir/.node"
        write_launcher "$dir"
      fi
      step=link
      t_link=$(clock_mark)
      mkdir -p "$(dirname "$link")"
      ln -sfn "$target" "$link.new"
      mv -Tf "$link.new" "$link"
      report_phase link "$t_link"
    fi
    """
  end

  # Keep the adapter/JS tree pinned, but avoid downloading a second native
  # Claude on Sprites. Resolve the image symlink once so auto-updates do not
  # silently change the executable used by this installation. The floor is
  # the CLI paired with our SDK; it is not a promise of old model aliases.
  defp image_claude_fn("claude", :sprites) do
    ~S"""
    select_image_claude() {
      local candidate version
      candidate=$(command -v claude) || return 0
      candidate=$(readlink -f "$candidate") || return 0
      case "$candidate" in /*) ;; *) return 0 ;; esac
      [ -x "$candidate" ] || return 0
      version=$(DISABLE_AUTOUPDATER=1 timeout 5 "$candidate" --version 2>/dev/null) || return 0
      if [[ "$version" =~ ^([0-9]+\.[0-9]+\.[0-9]+)\ \(Claude\ Code\)$ ]]; then
        version=${BASH_REMATCH[1]}
        if [ "$(printf '%s\n' 2.1.280 "$version" | sort -V | head -1)" = 2.1.280 ]; then
          claude_executable=$candidate
        fi
      fi
    }
    """
  end

  defp image_claude_fn(_runtime, _provider), do: ""

  # `write_launcher DIR` writes DIR/launch, which the PATH link points at: it
  # execs the entry on the Node recorded in `.node` at install. The entry's own
  # `#!/usr/bin/env node` finds `node` on PATH, and a sprite's is an nvm shim,
  # a bash script that took ~0.8 s to start where the binary it wraps took
  # 0.04 s -- paid on every adapter start (managoat/fountain, measured
  # 2026-09-26). A `.node` that is missing, not absolute or no longer
  # executable (the image moved Node) falls back to `node` on PATH, which is
  # only slower. The launcher names the final directory, not DIR, since an
  # install writes it into staging.
  defp launcher_fn do
    ~S"""
    write_launcher() {
      printf '%s\n' '#!/bin/sh' \
        "d='$dir'" \
        '[ ! -f "$d/.claude-executable" ] || { read -r CLAUDE_CODE_EXECUTABLE <"$d/.claude-executable"; export CLAUDE_CODE_EXECUTABLE; }' \
        'n=' \
        '[ -f "$d/.node" ] && read -r n <"$d/.node"' \
        'case $n in /*) [ -x "$n" ] || n=node ;; *) n=node ;; esac' \
        "exec \"\$n\" '$entry' \"\$@\"" >"$1/launch.new"
      chmod +x "$1/launch.new"
      mv -f "$1/launch.new" "$1/launch"
    }
    """
  end

  # 16 workers, as before, but a worker no longer means a connection. One
  # worker per package meant one TLS handshake per package: 104 of them for
  # claude at a concurrency of 16, so the install paid ~6.5 serialized waves of
  # setup to move 6.93 MiB whose median package is 6 KB, and time-to-first-byte
  # was 0.42 s cold against 0.11 s warm (managoat/managoat#2905). Portable
  # packages therefore travel in *shards*: one curl process per shard fetches
  # its packages in sequence over a single connection, so a shard pays one
  # handshake and the rest of its packages ride it. The worker count is
  # deliberately unchanged, so connection reuse is the only variable.
  #
  # A package carrying an os/cpu/libc constraint is a native binary -- the
  # claude-agent-sdk and codex platform tarballs are 95-220 MB -- and keeps the
  # streaming path: it goes through a FIFO into tar while the same bytes are
  # hashed, so no tarball is written to disk. The 223 MB claude binary used to
  # wait for its 105 MB tarball to land and then unpack (~1.4 s, most of it
  # gzip), and a sprite's disk absorbs writes slowly (managoat/fountain,
  # measured 2026-09-26). Shards only ever carry the portable JavaScript
  # packages, 7.2 MB of them in total for claude, so what lands on disk is
  # bounded by that and deleted as each package is staged.
  #
  # The two lanes run concurrently and share the 16 workers between them, so a
  # native tarball still streams alongside the small packages rather than after
  # them. `manifest_install` returns only once both lanes have finished: the
  # npm fallback clears the staging directory, and a worker still writing into
  # it would race that.
  #
  # Integrity, retries and filters are unchanged in substance. A sharded
  # package is verified against its own sha512 *before* it is extracted, which
  # is stricter than the streaming lane, where the hash necessarily arrives
  # after the bytes have been unpacked -- into the install's staging directory,
  # so a mismatch fails the install, which never gets its `.installed` marker
  # or the PATH link, and nothing unverified runs either way. Each package
  # still gets three fresh attempts, and the first retry leaves the shard to
  # fetch that package on its own. The os/cpu/libc filter and the image-Claude
  # skip now run once over the manifest rather than once per worker, because
  # the lanes and their widths have to be known before the first worker starts.
  # `--strip-components=1` because a tarball's top directory is named by its
  # author, usually but not always `package/`. Each worker records its
  # package's time in `.timing`, and a shard records its shared fetch there
  # too. Retried downloads unpack into a fresh worker directory; verified files
  # are hard-linked into the shared staging tree so retry cleanup cannot remove
  # a concurrently installed nested dependency.
  defp manifest_install_fn do
    ~S"""
    manifest_install() {
      command -v curl >/dev/null && command -v openssl >/dev/null &&
        command -v mkfifo >/dev/null && command -v awk >/dev/null || return 1
      local arch libc stream batch stream_n batch_n stream_par batch_par chunk sharded rc pid
      arch=$(uname -m)
      case "$arch" in x86_64|amd64) arch=x64 ;; aarch64|arm64) arch=arm64 ;; esac
      libc=glibc
      if ldd --version 2>&1 | grep -qi musl; then libc=musl; fi
      mkdir -p "$2/.dl" || return 1
      stream="$2/.dl/stream.rows"
      batch="$2/.dl/batch.rows"
      : >"$stream" && : >"$batch" || return 1
      # Whether the output file exists is how a shard tells a finished tarball
      # from a partial one, because curl reports only its *last* transfer in
      # its exit status: a middle package can 404 and curl still exits 0.
      # A curl too old for --remove-on-error streams every package instead,
      # which is exactly what this installer did before shards existed.
      sharded=1
      curl --help all 2>/dev/null | grep -q -- --remove-on-error || sharded=0
      # The platform filter and the image-Claude skip, over the manifest once.
      # A row with any os/cpu/libc constraint is a native binary and streams.
      awk -F'\t' -v cpu_want="$arch" -v libc_want="$libc" -v reuse="$claude_executable" \
        -v sharded="$sharded" -v stream="$stream" -v batch="$batch" '
        NF < 6 { next }
        !($4 == "-" || index("," $4 ",", ",linux,")) { next }
        !($5 == "-" || index("," $5 ",", "," cpu_want ",")) { next }
        !($6 == "-" || index("," $6 ",", "," libc_want ",")) { next }
        reuse != "" && index($1, "node_modules/@anthropic-ai/claude-agent-sdk-") == 1 { next }
        {
          if (sharded == 1 && $4 == "-" && $5 == "-" && $6 == "-") print $1 "\t" $2 "\t" $3 > (batch)
          else print $1 "\t" $2 "\t" $3 > (stream)
        }
      ' "$1" || return 1
      stream_n=$(wc -l <"$stream")
      batch_n=$(wc -l <"$batch")
      # 16 workers in total across both lanes, as before shards existed.
      stream_par=$stream_n
      [ "$stream_par" -le 16 ] || stream_par=16
      if [ "$batch_n" -gt 0 ] && [ "$stream_par" -gt 15 ]; then stream_par=15; fi
      batch_par=$((16 - stream_par))
      [ "$batch_par" -ge 1 ] || batch_par=1
      chunk=$(((batch_n + batch_par - 1) / batch_par))
      [ "$chunk" -ge 1 ] || chunk=1
      rc=0
      pid=
      if [ "$stream_n" -gt 0 ]; then
        ACP_DEST=$2 xargs -d '\n' -n1 -P"$stream_par" bash -c '
        set -o pipefail
        IFS=$'"'"'\t'"'"' read -r path url sri <<<"$1"
        s=$(date +%s%N)
        work="$ACP_DEST/.dl/$(printf "%s" "$path" | tr "/@" "__")"
        mkdir -p "$work" || exit 1
        for attempt in 1 2 3; do
          # Never ask curl to retry a stream: it would append a second gzip
          # archive to the first hash/extractor. Each attempt starts afresh.
          rm -rf "$work/unpacked" "$work/pipe"
          mkdir -p "$work/unpacked" && mkfifo "$work/pipe" || exit 1
          tar xzf - -C "$work/unpacked" --strip-components=1 <"$work/pipe" 2>/dev/null &
          untar=$!
          got=$(curl -fsS --connect-timeout 5 --max-time 30 --speed-limit 1024 --speed-time 5 --write-out "%{stderr}__MANAGOAT_DOWNLOAD__ %{time_namelookup} %{time_connect} %{time_appconnect} %{time_starttransfer} %{time_total} %{size_download} %{num_connects}\n" "$url" 2>"$work/curl-metrics" |
            tee "$work/pipe" | openssl dgst -sha512 -binary | base64 -w0)
          fetched=$?
          sed -n "/^__MANAGOAT_DOWNLOAD__ /p" "$work/curl-metrics"
          wait "$untar"
          extracted=$?
          elapsed=$(( ($(date +%s%N) - s) / 1000000 ))
          if [ "$fetched" -ne 0 ]; then
            # Do not echo URLs, proxy credentials or arbitrary command output.
            printf "adapter package failed: package=%s step=fetch attempt=%s/3 exit=%s elapsed_ms=%s\n" "$path" "$attempt" "$fetched" "$elapsed" >&2
            [ "$attempt" -eq 3 ] && exit 1
            continue
          fi
          if [ "$extracted" -ne 0 ]; then
            printf "adapter package failed: package=%s step=extract exit=%s elapsed_ms=%s\n" "$path" "$extracted" "$elapsed" >&2
            exit 1
          fi
          if [ "sha512-$got" != "$sri" ]; then
            printf "adapter package failed: package=%s step=verify integrity mismatch elapsed_ms=%s\n" "$path" "$elapsed" >&2
            exit 1
          fi
          # Hard-link verified files into the install tree, merging directories
          # for nested dependencies without copying large native binaries.
          mkdir -p "$ACP_DEST/$path" && cp -al "$work/unpacked/." "$ACP_DEST/$path" || exit 1
          break
        done
        printf "%s %s\n" "$path" "$(( ($(date +%s%N) - s) / 1000000 ))" >>"$ACP_DEST/.timing"
      ' _ <"$stream" &
        pid=$!
      fi
      if [ "$batch_n" -gt 0 ]; then
        ACP_DEST=$2 xargs -d '\n' -n"$chunk" -P"$batch_par" bash -c '
        set -o pipefail
        shard="$ACP_DEST/.dl/shard-$$"
        mkdir -p "$shard" || exit 1
        n=0
        args=()
        for row in "$@"; do
          n=$((n + 1))
          IFS=$'"'"'\t'"'"' read -r path url sri <<<"$row"
          printf "%s\t%s\t%s\t%s\n" "$n" "$path" "$url" "$sri" >>"$shard/rows"
          args+=(--output "$shard/$n.tgz" --url "$url")
        done
        s=$(date +%s%N)
        # One process for the whole shard, so only its first package pays a
        # handshake. Never ask curl to retry: a retried transfer would append
        # a second gzip archive to the first. %{exitcode} is per transfer, so
        # a package is judged on its own status rather than on curls.
        curl -fsS --connect-timeout 5 --max-time 30 --speed-limit 1024 --speed-time 5 --remove-on-error --write-out "%{stderr}__MANAGOAT_DOWNLOAD__ %{time_namelookup} %{time_connect} %{time_appconnect} %{time_starttransfer} %{time_total} %{size_download} %{num_connects}\n__MANAGOAT_STATUS__ %{exitcode}\n" "${args[@]}" 2>"$shard/curl-metrics"
        # Only fixed numeric marker lines leave a worker: curl writes URLs and
        # proxy hosts into its own diagnostics.
        sed -n "/^__MANAGOAT_DOWNLOAD__ /p" "$shard/curl-metrics"
        sed -n "s/^__MANAGOAT_STATUS__ //p" "$shard/curl-metrics" >"$shard/status"
        printf "fetch:shard-%s %s\n" "$$" "$(( ($(date +%s%N) - s) / 1000000 ))" >>"$ACP_DEST/.timing"
        while IFS=$'"'"'\t'"'"' read -r n path url sri; do
          p=$(date +%s%N)
          fetched=$(sed -n "${n}p" "$shard/status")
          [ -n "$fetched" ] || fetched=1
          for attempt in 1 2 3; do
            # Measured from the shard, since its fetch is the part the packages
            # in it share. The per-package stage time goes to .timing below.
            # No apostrophes in here: this body is a single-quoted argument.
            elapsed=$(( ($(date +%s%N) - s) / 1000000 ))
            if [ ! -s "$shard/$n.tgz" ]; then
              # Do not echo URLs, proxy credentials or arbitrary command output.
              printf "adapter package failed: package=%s step=fetch attempt=%s/3 exit=%s elapsed_ms=%s\n" "$path" "$attempt" "$fetched" "$elapsed" >&2
              [ "$attempt" -eq 3 ] && exit 1
              # A fresh attempt of its own: one missing package does not
              # re-fetch its shard.
              curl -fsS --connect-timeout 5 --max-time 30 --speed-limit 1024 --speed-time 5 --remove-on-error --write-out "%{stderr}__MANAGOAT_DOWNLOAD__ %{time_namelookup} %{time_connect} %{time_appconnect} %{time_starttransfer} %{time_total} %{size_download} %{num_connects}\n" --output "$shard/$n.tgz" --url "$url" 2>"$shard/retry-metrics" </dev/null
              fetched=$?
              sed -n "/^__MANAGOAT_DOWNLOAD__ /p" "$shard/retry-metrics"
              continue
            fi
            # Verified before it is extracted, so nothing unverified is ever
            # written under the staging tree.
            got=$(openssl dgst -sha512 -binary "$shard/$n.tgz" | base64 -w0)
            if [ "sha512-$got" != "$sri" ]; then
              printf "adapter package failed: package=%s step=verify integrity mismatch elapsed_ms=%s\n" "$path" "$elapsed" >&2
              exit 1
            fi
            rm -rf "$shard/$n.work"
            mkdir -p "$shard/$n.work" || exit 1
            tar xzf "$shard/$n.tgz" -C "$shard/$n.work" --strip-components=1 2>/dev/null
            extracted=$?
            if [ "$extracted" -ne 0 ]; then
              printf "adapter package failed: package=%s step=extract exit=%s elapsed_ms=%s\n" "$path" "$extracted" "$elapsed" >&2
              exit 1
            fi
            # Hard-link verified files into the install tree, merging directories
            # for nested dependencies without copying large native binaries.
            mkdir -p "$ACP_DEST/$path" && cp -al "$shard/$n.work/." "$ACP_DEST/$path" || exit 1
            rm -rf "$shard/$n.work" "$shard/$n.tgz"
            break
          done
          printf "%s %s\n" "$path" "$(( ($(date +%s%N) - p) / 1000000 ))" >>"$ACP_DEST/.timing"
        done <"$shard/rows"
        rm -rf "$shard"
      ' _ <"$batch" || rc=1
      fi
      # Both lanes have to finish before the npm fallback clears the staging
      # directory a worker may still be writing into.
      [ -z "$pid" ] || wait "$pid" || rc=1
      [ "$rc" -eq 0 ] || return 1
      rm -rf "$2/.dl"
    }
    """
  end

  @doc """
  An agent's MCP servers, in the shape `session/new` takes.

  The agent carries them as Claude's own config map — `%{name => %{"command"
  => …, "args" => […], "env" => %{…}}}`, or a `type`/`url` entry for HTTP and
  SSE.
  ACP takes an *array*, each entry carrying its own `name`, and — the detail
  that is easy to get silently wrong — **`env` and `headers` as arrays of
  `%{name, value}` rather than maps.** Passing a map there is accepted as JSON
  and then read as nothing: the server starts with no environment, which
  surfaces much later as a tool that cannot authenticate.

  Verified against the pinned adapter's own parser, which does
  `Object.fromEntries(server.env.map((e) => [e.name, e.value]))`.

  This is the *only* delivery path since #636 — the out-of-band per-runtime
  config writers (claude's `mcp add-json` loop, codex's `config.toml`,
  opencode's `opencode.json`) are gone. Gate 2 verified the protocol path
  live: server started, listed, called, env delivered.
  """
  @spec mcp_servers(Managoat.Runtimes.agent() | nil) :: [map()]
  def mcp_servers(%{mcp_servers: servers}) when is_map(servers) and map_size(servers) > 0 do
    servers
    |> Enum.sort_by(fn {name, _} -> to_string(name) end)
    |> Enum.map(fn {name, entry} -> mcp_server(to_string(name), entry) end)
  end

  def mcp_servers(_), do: []

  defp mcp_server(name, %{"type" => type} = entry) when type in ["http", "sse"] do
    %{name: name, type: type, url: entry["url"]}
    |> put_if_present(:headers, name_value_list(entry["headers"]))
  end

  defp mcp_server(name, entry) when is_map(entry) do
    # No `type` key at all: the adapter treats an entry without one as stdio,
    # and sending `type: "stdio"` puts it down the http/sse branch of its
    # parser, where it looks for a `url` that is not there.
    %{name: name, command: entry["command"], args: entry["args"] || []}
    |> put_if_present(:env, name_value_list(entry["env"]))
  end

  defp mcp_server(name, _), do: %{name: name, args: []}

  defp name_value_list(map) when is_map(map) and map_size(map) > 0 do
    map
    |> Enum.sort_by(fn {k, _} -> to_string(k) end)
    |> Enum.map(fn {k, v} -> %{name: to_string(k), value: to_string(v)} end)
  end

  defp name_value_list(list) when is_list(list) and list != [], do: list
  defp name_value_list(_), do: nil

  defp put_if_present(map, _key, nil), do: map
  defp put_if_present(map, key, value), do: Map.put(map, key, value)

  @doc """
  The `initialize` params to send, for the client capabilities given.

  **The default declares no client filesystem or terminal capabilities.**
  `fs/*` and `terminal/*` are client-implemented, and a platform's would have
  to service them against the sandbox rather than the server — Fountain's
  ADR 0014 names that as the likeliest source of a security finding and 0016
  makes it its own gate. Declaring nothing means a well-behaved adapter never
  asks; the peer still answers anything that arrives, because an unanswered
  request blocks the agent and a blocked agent bills.

  `Managoat.ACP.Protocol.default_client_capabilities/0` is exactly that
  default, so a host that declares nothing passes the peer nothing and this
  function exists for the callers that read the params directly. A host that
  does service `fs/*` passes its own capabilities map instead.
  """
  @spec initialize_params(map()) :: map()
  def initialize_params(
        client_capabilities \\ Managoat.ACP.Protocol.default_client_capabilities()
      ) do
    Managoat.ACP.Protocol.initialize_params(client_capabilities)
  end
end
