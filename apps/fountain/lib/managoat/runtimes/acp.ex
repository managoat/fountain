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
    # total is known or the total went back. Codex is pinned at
    # `@openai/codex` ^0.160.1 (against ^0.153.3); the image's `codex`, at or
    # above that floor, runs instead, through `CODEX_PATH` (`@image_reuse`).
    # Measured locally
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
    # Installed from its verified bundle, like claude (ADR 0092). The full
    # tree's weight is the platform package (`@openai/codex-linux-x64`, an npm
    # alias of `@openai/codex@<ver>-linux-x64`, 163 MB packed), which the
    # bundle leaves out because the image's `codex` runs in its place.
    "codex" => %{
      bin: "codex-acp",
      args: [],
      package: "@agentclientprotocol/codex-acp",
      version: "2.2.2",
      entry: "dist/index.js"
    }
  }

  # The image's own CLI, which every install runs instead of a bundled copy:
  # the adapter's transport bundle (`@bundles`) deliberately carries none, so
  # an install without a usable image CLI fails rather than fetching one.
  # Per runtime, because every field differs: the binary probed on PATH, what
  # its `--version` prints, the env that probe needs, the floor paired with
  # our pin and the variable the adapter reads.
  #
  # The marker is `.<runtime>-executable` in the install directory, which is
  # also what the script's `installed` revalidates and what the launcher
  # exports: an install that recorded an executable the image later removed
  # is not installed, so the next check reinstalls against whatever the image
  # carries now.
  #
  # `floor` is the CLI version the adapter was measured against, not a promise
  # about model aliases: the image's catalog is accepted as it is, including a
  # removed older model id. Anything below it, unparseable, or failing its
  # `--version` fails the install, naming the floor.
  #
  # Every provider. Sprites since #2853 (claude) and #2914 (codex); E2B for
  # codex since #2940 (codex-cli 0.162.1 in loam-e2b-fountain@sha256:8e47934b,
  # checked 2026-10-17) and for claude since bundles became the only install
  # (ADR 0092): the reference template and loam's `fountain` template both
  # install current claude and codex from npm, so `readlink -f` lands on the
  # npm package's entry, which #2914 already handles.
  @image_reuse %{
    "claude" => %{
      probe: "claude",
      # A sprite's claude checks for an update on start; the probe is a
      # version read, not an upgrade.
      probe_env: "DISABLE_AUTOUPDATER=1 ",
      env: "CLAUDE_CODE_EXECUTABLE",
      floor: "2.1.280",
      version_pattern: ~S{^([0-9]+\.[0-9]+\.[0-9]+)\ \(Claude\ Code\)$}
    },
    # `codex-acp`'s `startCodexConnection` spawns `$CODEX_PATH app-server`
    # when the variable is set and `@openai/codex/bin/codex.js` on
    # `process.execPath` when it is not (checked in 2.2.2's `dist/index.js`),
    # so the seam is the exact counterpart of Claude's. The bundle keeps the
    # JavaScript `@openai/codex` and leaves out its platform packages, 163 MB
    # of the codex tree's 166 MB.
    "codex" => %{
      probe: "codex",
      probe_env: "",
      env: "CODEX_PATH",
      floor: "0.160.1",
      version_pattern: ~S{^codex-cli\ ([0-9]+\.[0-9]+\.[0-9]+)$}
    }
  }

  # The one way an adapter gets into a sandbox (ADR 0092): the tree its TSV
  # lock resolves, minus the CLI the image supplies, as one gzip archive
  # published at an immutable release tag. Every pinned adapter must have one:
  # a pin without its reviewed `.bundle.json`, or one that no longer matches
  # its lock, fails to compile. The host fetches and verifies it
  # (`Managoat.Runtimes.BundleCache`) and uploads it for the sandbox
  # installer, which verifies it again before extraction and publishes nothing
  # that does not match. Gzip, not the zstd encoding also published: the
  # sandbox images carry no `zstd`.
  @bundles (for {runtime, %{package: package, version: version}} <- @adapters,
                is_binary(package),
                into: %{} do
              pin = "#{package |> String.split("/") |> List.last()}@#{version}"
              dir = Path.expand("../../../priv/runtimes/acp", __DIR__)
              lock = Path.join(dir, "#{pin}.tsv")
              path = Path.join(dir, "#{pin}.bundle.json")
              @external_resource lock
              @external_resource path

              unless File.regular?(path) do
                raise "#{pin} has no ACP bundle: build and review #{Path.basename(path)} " <>
                        "(contributing/acp-bundles.md)"
              end

              bundle = path |> File.read!() |> Jason.decode!()
              lock_hash = :crypto.hash(:sha256, File.read!(lock)) |> Base.encode16(case: :lower)

              unless bundle["pin"] == pin and bundle["runtime"] == runtime and
                       bundle["profile"] == "linux-x64-glibc-image" and
                       bundle["manifest_sha256"] == lock_hash do
                raise "ACP bundle does not match its dependency lock: #{pin}"
              end

              %{"file" => file, "bytes" => bytes, "integrity" => "sha512-" <> encoded = integrity} =
                bundle["artifacts"]["gzip"]

              digest = Base.decode64!(encoded)

              unless file == "#{pin}.linux-x64-glibc-image.tar.gz" and byte_size(digest) == 64 and
                       is_integer(bytes) and bytes > 0 do
                raise "invalid ACP bundle artifact: #{pin}"
              end

              {runtime,
               %{
                 url:
                   "https://github.com/managoat/managoat/releases/download/" <>
                     "acp-bundle-#{runtime}-#{version}/#{file}",
                 integrity: integrity,
                 bytes: bytes,
                 sha512: Base.encode16(digest, case: :lower)
               }}
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

  @preload_timeout 60_000
  @install_timeout 180_000

  @doc """
  Install the pinned adapter into a sprite.

  Runs at provision time rather than at spawn: by the time a turn spawns the
  sandbox may be suspended-and-resumed or policy-restricted, and an install
  failing there reads as a protocol bug rather than a missing package.

  A fresh provision normally installs before the network floor, beside the
  CA install (`preload/2`), and calls this only when that did not install
  the pin. Every other path (a reattach, a repair before spawn) comes here.
  Neither downloads anything in the sandbox: the host uploads the verified
  bundle for the installer, so a restricted allowlist needs no entry for the
  adapter.

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

  This and `ensure_installed/3` run that check first and send nothing; only
  a miss uploads the bundle and takes the locked install path.

  ## From a verified bundle, and nothing else

  The bundle holds the tree the adapter's TSV lock resolves (written by
  `scripts/acp-lock.exs` from npm's own resolution, every package checked
  against its sha512 when the bundle is built) less the CLI the image
  supplies: the image's `claude` (>= 2.1.280, through
  `CLAUDE_CODE_EXECUTABLE`) and `codex` (>= 0.160.1, through `CODEX_PATH`)
  run instead (`@image_reuse`); the adapter and its JavaScript dependencies
  stay pinned. Image reuse accepts the image's model aliases, including
  removal of older model IDs.

  Every failure fails the install, and with it the provision, with a line
  naming the step and no URL or credential: a bundle the host cannot fetch
  or verify, a file upload the sandbox refuses, no usable image CLI, a sandbox
  that is not Linux x64 glibc, bytes whose SHA-512 is not the pinned one, an
  archive that does not extract. There is no package-by-package or npm
  fallback: each ignored the reviewed lock in some failure, and the npm one
  installed whatever npm resolved that day.
  """
  @spec install(sprite :: any(), String.t(), [{String.t(), String.t()}]) :: :ok | {:error, term()}
  def install(sprite, runtime, sprite_env)

  # Native ACP: the runtime speaks the protocol itself, and is already on the
  # sprite — gemini from the base image. Nothing to install, and nothing we
  # can pin either: the version floor is whatever the image carries, which
  # gate 1 recorded as an open exposure.
  def install(_handle, "gemini", _sprite_env), do: :ok
  def install(handle, runtime, sprite_env), do: ensure_installed(handle, runtime, sprite_env)

  @doc "Check an existing pin before spawn; upload its bundle and install only on a miss."
  def ensure_installed(_handle, "gemini", _env), do: :ok

  def ensure_installed(handle, runtime, env) do
    metadata = %{runtime: runtime, provider: handle.provider}

    Fountain.Telemetry.span([:adapter_install], metadata, fn ->
      case Managoat.Sandbox.exec(handle, "bash", ["-lc", cached_check_script(runtime)],
             env: env,
             stderr_to_stdout: true,
             timeout: 30_000
           ) do
        {:ok, _, 0} ->
          {:ok, %{"install_cache_hit" => 1, outcome: :ok}}

        {:ok, _, 75} ->
          install_from_bundle(handle, runtime, env)

        {:ok, out, code} ->
          {{:error,
            {:acp_adapter_install_exit, code, String.slice(to_string(out), -2_000, 2_000)}},
           %{outcome: :failed}}

        {:error, reason} ->
          {{:error, {:acp_adapter_install, reason}}, %{outcome: :failed}}
      end
    end)
  end

  defp install_from_bundle(handle, runtime, env) do
    case file_install(handle, runtime, env, @install_timeout) do
      {:ok, out, 0} ->
        {:ok, Map.put(Managoat.Runtimes.InstallTiming.attributes(out), :outcome, :ok)}

      {:ok, out, code} ->
        error =
          {:error, {:acp_adapter_install_exit, code, String.slice(to_string(out), -2_000, 2_000)}}

        {error, Map.put(Managoat.Runtimes.InstallTiming.attributes(out), :outcome, :failed)}

      {:error, {:acp_adapter_bundle, _} = reason} ->
        {{:error, reason}, %{outcome: :failed}}

      {:error, reason} ->
        {{:error, {:acp_adapter_install, reason}}, %{outcome: :failed}}
    end
  end

  @doc """
  Install a pinned adapter from its bundle before the sandbox may dial out.

  The host fetches the bundle (`Managoat.Runtimes.BundleCache`), uploads it
  through `write_file`, and runs the installer offline: it verifies and
  extracts the file and runs nothing that reaches the network, so it can run
  beside the CA install and before the network policy (ADR 0019) instead of
  after them. The download it replaced waited for both and ended every cold
  provision: the adapter step was 2.2 s at p50 on prod, 1.0 s of it the
  download through the broker (2026-10-17).

  `:ok` when the pin is installed, `:skip` for a runtime with no bundle
  (gemini), `{:error, reason}` when it did not install; `install/3` then
  tries once more after the floor, and its failure is the provision's.
  """
  def preload(handle, runtime) do
    if Map.has_key?(@bundles, runtime) do
      metadata = %{runtime: runtime, provider: handle.provider, preload: true}

      Fountain.Telemetry.span([:adapter_install], metadata, fn ->
        do_preload(handle, runtime)
      end)
    else
      :skip
    end
  end

  defp do_preload(handle, runtime) do
    case file_install(handle, runtime, [{"MANAGOAT_ACP_OFFLINE", "1"}], @preload_timeout) do
      {:ok, out, 0} ->
        {:ok, Map.put(Managoat.Runtimes.InstallTiming.attributes(out), :outcome, :ok)}

      {:ok, out, 75} ->
        {{:error, :acp_adapter_not_preloaded},
         Map.put(Managoat.Runtimes.InstallTiming.attributes(out), :outcome, :missed)}

      {:ok, out, code} ->
        {{:error, {:acp_adapter_preload_exit, code}},
         Map.put(Managoat.Runtimes.InstallTiming.attributes(out), :outcome, :failed)}

      {:error, reason} ->
        {{:error, {:acp_adapter_preload, reason}}, %{outcome: :failed}}
    end
  end

  # Keep the host-verified bundle delivery separate from the install exec.
  defp file_install(handle, runtime, env, timeout) do
    %{url: url, integrity: integrity, bytes: size} = @bundles[runtime]
    %{package: package, version: version} = @adapters[runtime]
    path = "/tmp/managoat-#{package_name(package)}@#{version}.tar.gz"

    with {:ok, bytes} <- fetch_bundle(url, integrity, size),
         :ok <- Managoat.Sandbox.write_file(handle, path, bytes) do
      Managoat.Sandbox.exec(handle, "bash", ["-lc", install_script(runtime)],
        env: [{"MANAGOAT_ACP_BUNDLE_FILE", path} | env],
        stderr_to_stdout: true,
        timeout: timeout
      )
    end
  end

  defp fetch_bundle(url, integrity, size) do
    case Managoat.Runtimes.BundleCache.fetch(url, integrity, size) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, reason} -> {:error, {:acp_adapter_bundle, reason}}
    end
  end

  defp cached_check_script(runtime) do
    %{bin: bin, version: version} = @adapters[runtime]

    ~s"""
    want=#{version}
    dir=#{install_dir(runtime)}
    target="$dir/launch"
    link=/home/sprite/.local/bin/#{bin}
    marker=#{image_marker(runtime)}
    #{installed_fn()}
    if installed && [ -x "$target" ] && [ "$(readlink "$link" 2>/dev/null)" = "$target" ]; then
      printf '__MANAGOAT_INSTALL__ cache_hit 1\\n'
    else
      # A subshell avoids the login shell's logout hook, just like the installer.
      (exit 75)
    fi
    """
  end

  defp install_dir(runtime) do
    %{package: package, version: version} = @adapters[runtime]
    "/home/sprite/.local/share/managoat/acp/#{package_name(package)}@#{version}"
  end

  defp package_name(package), do: package |> String.split("/") |> List.last()

  # Shared by the pre-spawn check and the locked install/repair path.
  defp installed_fn do
    ~S"""
    installed() {
      [ -f "$dir/.installed" ] && [ "$(cat "$dir/.installed")" = "$want" ] &&
        { [ ! -f "$dir/$marker" ] || [ -x "$(cat "$dir/$marker")" ]; }
    }
    """
  end

  defp install_script(runtime) do
    %{bin: bin, package: package, version: version, entry: entry} = @adapters[runtime]
    %{probe: probe, floor: floor} = @image_reuse[runtime]
    dir = install_dir(runtime)

    ~s"""
    set -e
    install_started=$SECONDS
    # A boundary reads two clocks, neither of which spawns a process: bash's
    # microsecond wall clock, and /proc/uptime's monotonic seconds. `date
    # +%s%3N` is deliberately absent. uutils coreutils truncates the *unpadded*
    # nanoseconds for %3N, so a reading taken in the first 100 ms of a second
    # keeps its leading digits and comes out up to 10x high (#2908).
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
    failed=
    trap 'rc=$?; [ -n "$failed" ] || printf "adapter install failed: step=%s exit=%s elapsed_s=%s\\n" "$step" "$rc" "$((SECONDS - install_started))" >&2' ERR
    # A reason the host can show, in place of the trap's line. `set -e` ends
    # the script on its status; the EXIT trap below still cleans up. Offline
    # (`preload/2`), a failure is 75 and says nothing: the host installs again
    # after the floor, and that run's failure is the one reported.
    fail() {
      failed=1
      [ -z "${MANAGOAT_ACP_OFFLINE:-}" ] || return 75
      printf 'adapter install failed: step=%s: %s\\n' "$step" "$1" >&2
      return 1
    }
    want=#{version}
    dir=#{dir}
    link=/home/sprite/.local/bin/#{bin}
    entry="$dir/node_modules/#{package}/#{entry}"
    target="$dir/launch"
    marker=#{image_marker(runtime)}
    integrity='#{@bundles[runtime].integrity}'
    locked=
    # Always remove the delivered archive, including on a cached install.
    # Only the run holding the install lock may clear staging.
    trap '[ -z "${MANAGOAT_ACP_BUNDLE_FILE:-}" ] || rm -f -- "$MANAGOAT_ACP_BUNDLE_FILE"; [ -z "$locked" ] || rm -rf "$dir.tmp"' EXIT
    #{installed_fn()}
    image_executable=
    #{image_select_fn(runtime)}
    # Seconds.milliseconds for the install's own record, from the same
    # microsecond mark rather than the %3N that misreports it.
    now() { local m; m=$(clock_mark); m=${m%% *}; printf '%s.%s' "${m%??????}" "${m: -6:3}"; }
    #{launcher_fn(runtime)}
    # No `exit` at the top level: this runs under `bash -lc`, where the builtin
    # runs ~/.bash_logout, and the sprite's ends in `clear_console -q`, which
    # fails outside a console and turned a successful check into exit 1.
    if ! { installed && [ -x "$target" ] && [ "$(readlink "$link" 2>/dev/null)" = "$target" ]; }; then
      mkdir -p "$(dirname "$dir")"
      exec 9>"$dir.lock"
      t_lock=$(clock_mark)
      flock 9
      locked=1
      report_phase lock_wait "$t_lock"
      if ! installed; then
        printf '__MANAGOAT_INSTALL__ cache_hit 0\\n'
        t_start=$(now)
        step=deliver
        [ -f "${MANAGOAT_ACP_BUNDLE_FILE:-}" ] || fail "no adapter bundle was delivered"
        step=platform
        [ "$(uname -s)" = Linux ] || fail "the adapter bundle is built for Linux"
        case "$(uname -m)" in x86_64|amd64) ;; *) fail "the adapter bundle is built for x64" ;; esac
        if ldd --version 2>&1 | grep -qi musl; then fail "the adapter bundle is built for glibc"; fi
        command -v openssl >/dev/null || fail "openssl is missing"
        step=image_probe
        t_probe=$(clock_mark)
        select_image_executable
        report_phase image_probe "$t_probe"
        [ -n "$image_executable" ] || fail "no working #{probe} >= #{floor} on PATH; the adapter bundle carries no #{probe} of its own"
        step=verify
        got=$(openssl dgst -sha512 -binary "$MANAGOAT_ACP_BUNDLE_FILE" | base64 -w0) || got=
        [ "sha512-$got" = "$integrity" ] || fail "the adapter bundle does not match its pinned SHA-512"
        # Resolve Node through the image's shim while extracting the verified file.
        rm -f "$dir.node"
        node -p process.execPath >"$dir.node" 2>/dev/null &
        node_pid=$!
        step=extract
        t_extract=$(clock_mark)
        rm -rf "$dir.tmp"
        mkdir -p "$dir.tmp"
        tar -xzf "$MANAGOAT_ACP_BUNDLE_FILE" -C "$dir.tmp" 2>/dev/null || fail "the adapter bundle did not extract"
        report_phase bundle_extract "$t_extract"
        t_finalize=$(clock_mark)
        step=finalize
        chmod +x "$dir.tmp/node_modules/#{package}/#{entry}"
        t_node_wait=$(clock_mark)
        if wait "$node_pid"; then mv -f "$dir.node" "$dir.tmp/.node"; else rm -f "$dir.node"; fi
        report_phase node_wait "$t_node_wait"
        printf '%s\\n' "$image_executable" >"$dir.tmp/$marker"
        write_launcher "$dir.tmp"
        # When the install happened, for the next slow one to explain itself.
        printf 'method bundle\\nstart %s\\ninstalled %s\\n' "$t_start" "$(now)" >"$dir.tmp/.install-timing"
        printf '%s' "$want" >"$dir.tmp/.installed"
        t_swap=$(clock_mark)
        rm -rf "$dir"
        mv "$dir.tmp" "$dir"
        report_phase swap "$t_swap"
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

  # Where a selected executable is recorded, inside the versioned install
  # directory. Named after the runtime so the two adapters cannot read each
  # other's, and so claude's keeps the name installs already on disk wrote.
  defp image_marker(runtime), do: ".#{runtime}-executable"

  # Resolve the image symlink once so an auto-update does not silently change
  # the executable this installation recorded. The floor is the CLI paired
  # with our pin; it is not a promise of old model aliases. Anything that
  # fails a step here leaves `image_executable` empty, which fails the install.
  defp image_select_fn(runtime) do
    %{probe: probe, probe_env: probe_env, floor: floor, version_pattern: pattern} =
      @image_reuse[runtime]

    ~s"""
    select_image_executable() {
      local candidate version
      candidate=$(command -v #{probe}) || return 0
      candidate=$(readlink -f "$candidate") || return 0
      case "$candidate" in /*) ;; *) return 0 ;; esac
      [ -x "$candidate" ] || return 0
      version=$(#{probe_env}timeout 5 "$candidate" --version 2>/dev/null) || return 0
      if [[ "$version" =~ #{pattern} ]]; then
        version=${BASH_REMATCH[1]}
        if [ "$(printf '%s\\n' #{floor} "$version" | sort -V | head -1)" = #{floor} ]; then
          image_executable=$candidate
        fi
      fi
    }
    """
  end

  # `write_launcher DIR` writes DIR/launch, which the PATH link points at: it
  # execs the entry on the Node recorded in `.node` at install. The entry's own
  # `#!/usr/bin/env node` finds `node` on PATH, and a sprite's is an nvm shim,
  # a bash script that took ~0.8 s to start where the binary it wraps took
  # 0.04 s -- paid on every adapter start (managoat/fountain, measured
  # 2026-09-26). A `.node` that is missing, not absolute or no longer
  # executable (the image moved Node) falls back to `node` on PATH, which is
  # only slower. The launcher names the final directory, not DIR, since an
  # install writes it into staging.
  #
  # It also exports the recorded image executable in the variable this
  # runtime's adapter reads. An install from before bundles were the only
  # path may have no marker, and then exports nothing: it runs the CLI it
  # installed.
  defp launcher_fn(runtime) do
    %{env: env} = @image_reuse[runtime]
    marker = image_marker(runtime)

    reuse_line =
      ~s(  '[ ! -f "$d/#{marker}" ] || ) <>
        ~s({ read -r #{env} <"$d/#{marker}"; export #{env}; }' \\\n)

    ~s"""
    write_launcher() {
      printf '%s\\n' '#!/bin/sh' \\
        "d='$dir'" \\
      #{reuse_line}    'n=' \\
        '[ -f "$d/.node" ] && read -r n <"$d/.node"' \\
        'case $n in /*) [ -x "$n" ] || n=node ;; *) n=node ;; esac' \\
        "exec \\"\\$n\\" '$entry' \\"\\$@\\"" >"$1/launch.new"
      chmod +x "$1/launch.new"
      mv -f "$1/launch.new" "$1/launch"
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
