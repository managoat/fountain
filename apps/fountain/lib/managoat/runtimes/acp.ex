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
    # `@openai/codex` ^0.160.1 (against ^0.153.3); on Sprites a working image
    # `codex` at or above that floor runs instead, through `CODEX_PATH`
    # (`@image_reuse`), and everywhere else the bundled copy does. Measured locally
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

  # Reusing the image's own CLI instead of installing the adapter's bundled
  # copy of it, where the adapter has a seam for one. Per runtime, because
  # every field differs: the binary probed on PATH, what its `--version`
  # prints, the env that probe needs, the floor paired with our pin, the
  # variable the adapter reads, and the manifest rows the bundled copy holds.
  #
  # The marker is `.<runtime>-executable` in the install directory, which is
  # also what the script's `installed` revalidates and what the launcher
  # exports: an
  # install that recorded an executable the image later removed is not
  # installed, so provisioning picks another one or installs the bundled copy.
  #
  # `floor` is the CLI version the adapter was measured against, not a promise
  # about model aliases: the image's catalog is accepted as it is, including a
  # removed older model id. Anything below it, unparseable, or failing its
  # `--version` leaves the bundled copy in place.
  #
  # `bundled` has to stay a single `prefix*`: the manifest installer filters
  # rows in one awk pass before its lanes start, and matches that prefix.
  #
  # Which providers emit the selector for which runtime is `image_reuse?/2`:
  # Sprites for both, E2B for codex only.
  @image_reuse %{
    "claude" => %{
      probe: "claude",
      # A sprite's claude checks for an update on start; the probe is a
      # version read, not an upgrade.
      probe_env: "DISABLE_AUTOUPDATER=1 ",
      env: "CLAUDE_CODE_EXECUTABLE",
      floor: "2.1.280",
      version_pattern: ~S{^([0-9]+\.[0-9]+\.[0-9]+)\ \(Claude\ Code\)$},
      bundled: "node_modules/@anthropic-ai/claude-agent-sdk-*"
    },
    # `codex-acp`'s `startCodexConnection` spawns `$CODEX_PATH app-server`
    # when the variable is set and `@openai/codex/bin/codex.js` on
    # `process.execPath` when it is not (checked in 2.2.2's `dist/index.js`),
    # so the seam is the exact counterpart of Claude's. The bundled rows are
    # the platform packages — `@openai/codex-<platform>`, npm aliases of
    # `@openai/codex@<ver>-<platform>` and optional dependencies of
    # `@openai/codex`, which is kept. One is eligible per sandbox
    # (`linux-x64`), and it is 163 MB of the codex tree's 166 MB.
    "codex" => %{
      probe: "codex",
      probe_env: "",
      env: "CODEX_PATH",
      floor: "0.160.1",
      version_pattern: ~S{^codex-cli\ ([0-9]+\.[0-9]+\.[0-9]+)$},
      bundled: "node_modules/@openai/codex-*"
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

  # Optional transport artifacts; the TSV remains the dependency lock. A new
  # adapter pin without a published bundle keeps using the package installer.
  @bundles (for {runtime, %{package: package, version: version}} <- @adapters,
                is_binary(package),
                into: %{} do
              pin = "#{package |> String.split("/") |> List.last()}@#{version}"
              path = Path.expand("../../../priv/runtimes/acp/#{pin}.bundle.json", __DIR__)
              @external_resource path

              bundle =
                if File.regular?(path) do
                  bundle = path |> File.read!() |> Jason.decode!()

                  manifest_hash =
                    :crypto.hash(:sha256, @manifests[runtime]) |> Base.encode16(case: :lower)

                  unless bundle["pin"] == pin and bundle["runtime"] == runtime and
                           bundle["profile"] == "linux-x64-glibc-image" and
                           bundle["manifest_sha256"] == manifest_hash do
                    raise "ACP bundle does not match its dependency lock: #{pin}"
                  end

                  for {encoding, suffix} <- [{"gzip", "gz"}, {"zstd", "zst"}] do
                    artifact = bundle["artifacts"][encoding]
                    expected = "#{pin}.linux-x64-glibc-image.tar.#{suffix}"
                    "sha512-" <> encoded = artifact["integrity"]
                    decoded = Base.decode64!(encoded)

                    unless artifact["file"] == expected and byte_size(decoded) == 64 do
                      raise "invalid ACP bundle artifact: #{pin}"
                    end
                  end

                  bundle
                end

              {runtime, bundle}
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

  Before a new process starts on an existing sandbox, `ensure_installed/3`
  runs the same pin, image-executable and launcher checks without writing the
  manifest. A miss takes the ordinary locked install/repair path. Fresh
  provisioning uses `install/3` directly, avoiding an extra check round trip.

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
  timeout, with up to three fresh attempts. A shard's fetch shares that 30
  seconds across its packages, and counts as the first attempt of any package
  it did not deliver; those retry on connections of their own, in parallel.
  Failed attempts identify the package, step and elapsed time
  without exposing registry URLs or proxy credentials. npm spent most of a claude install's
  ~12 s in its own CPU; the manifest install measured 3.0 s. Platform
  packages are kept only when their os/cpu/libc match the sandbox, as npm
  would choose them. Nothing in these trees has an install script (the
  generator refuses one), so skipping npm skips nothing that runs. It also
  pins the whole tree, not only the adapter: npm resolved ranges at install
  time. On Sprites, a working image CLI at or above the floor paired with our
  pin replaces the bundled platform package through the variable the adapter
  reads — Claude >= 2.1.280 through `CLAUDE_CODE_EXECUTABLE`, codex >= 0.160.1
  through `CODEX_PATH` (`@image_reuse`); the adapter and JavaScript
  dependencies stay pinned. Missing, older or unrecognised image
  binaries use the bundled CLI. On E2B the same reuse applies to codex
  only; Claude there keeps the bundled CLI.
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
      install_with_manifest(handle, runtime, sprite_env, metadata)
    end)
  end

  @doc "Check an existing pin before spawn; write its manifest only if repair is needed."
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
          install_with_manifest(handle, runtime, env, metadata)

        {:ok, out, code} ->
          {{:error,
            {:acp_adapter_install_exit, code, String.slice(to_string(out), -2_000, 2_000)}},
           %{outcome: :failed}}

        {:error, reason} ->
          {{:error, {:acp_adapter_install, reason}}, %{outcome: :failed}}
      end
    end)
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

  defp install_with_manifest(handle, runtime, sprite_env, metadata) do
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

  # Shared by the pre-spawn check and the locked install/repair path.
  defp installed_fn do
    ~S"""
    installed() {
      [ -f "$dir/.installed" ] && [ "$(cat "$dir/.installed")" = "$want" ] &&
        { [ ! -f "$dir/$marker" ] || [ -x "$(cat "$dir/$marker")" ]; }
    }
    """
  end

  defp install_script(runtime, provider) do
    %{bin: bin, package: package, version: version, entry: entry} = @adapters[runtime]
    dir = install_dir(runtime)
    marker = image_marker(runtime)

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
    marker=#{marker}
    #{installed_fn()}
    image_executable=
    image_bundled='#{image_bundled(runtime)}'
    #{image_select_fn(runtime, provider)}
    # Seconds.milliseconds for the install's own record, from the same
    # microsecond mark rather than the %3N that misreports it.
    now() { local m; m=$(clock_mark); m=${m%% *}; printf '%s.%s' "${m%??????}" "${m: -6:3}"; }
    #{manifest_install_fn()}
    #{bundle_install_fn(runtime)}
    #{launcher_fn(runtime)}
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
        #{if image_reuse?(runtime, provider), do: "select_image_executable", else: ""}
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
        if bundle_install "$dir.tmp"; then
          how=bundle
        else
          t_manifest=$(clock_mark)
          if ! { [ -f "$dir.tsv" ] && manifest_install "$dir.tsv" "$dir.tmp"; }; then
            report_phase manifest "$t_manifest"
            if [ -f "$dir.tsv" ]; then echo "manifest install failed; installing #{package}@#{version} with npm" >&2; fi
            how=npm
            rm -rf "$dir.tmp"
            mkdir -p "$dir.tmp"
            npm_optional=()
            [ -z "$image_executable" ] || npm_optional=(--omit=optional)
            step=npm
            t_npm=$(clock_mark)
            # npm may include proxy or registry credentials in error output.
            # The ERR trap reports only its step, exit status and elapsed time.
            npm install --prefix "$dir.tmp" --no-progress --silent --no-audit --no-fund "${npm_optional[@]}" #{package}@#{version} >/dev/null 2>&1
            report_phase npm "$t_npm"
          else
            report_phase manifest "$t_manifest"
          fi
        fi
        t_finalize=$(clock_mark)
        step=finalize
        t_fetched=$(now)
        chmod +x "$dir.tmp/node_modules/#{package}/#{entry}"
        t_node_wait=$(clock_mark)
        if wait "$node_pid"; then mv -f "$dir.node" "$dir.tmp/.node"; else rm -f "$dir.node"; fi
        report_phase node_wait "$t_node_wait"
        if [ -n "$image_executable" ]; then
          printf '%s\n' "$image_executable" >"$dir.tmp/$marker"
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

  # These immutable transport artifacts contain exactly the selected TSV tree.
  # They omit the native CLI only when the image selector has accepted one.
  # Any failure leaves a clean staging directory for the package installer.
  defp bundle_install_fn(runtime) do
    case @bundles[runtime] do
      nil ->
        "bundle_install() { return 1; }"

      bundle ->
        base =
          "https://github.com/managoat/managoat/releases/download/acp-bundle-#{runtime}-#{@adapters[runtime].version}"

        bindings =
          for encoding <- ~w(gzip zstd), into: "" do
            artifact = bundle["artifacts"][encoding]

            "bundle_#{encoding}_url='#{base}/#{artifact["file"]}'\n" <>
              "bundle_#{encoding}_integrity='#{artifact["integrity"]}'\n"
          end

        bindings <> bundle_install_shell()
    end
  end

  defp bundle_install_shell do
    ~S"""
    bundle_extract() {
      local dest=$1 encoding=$2 url=$3 expected=$4 started got rc=0
      mkdir -p "$dest" || return 1
      started=$(clock_mark)
      curl -fsSL --retry 0 --connect-timeout 2 --max-time 5 \
        --output "$dest.bundle" \
        --write-out '__MANAGOAT_DOWNLOAD__ %{time_namelookup} %{time_connect} %{time_appconnect} %{time_starttransfer} %{time_total} %{size_download} %{num_connects}\n__MANAGOAT_DOWNLOAD_RESULT__ %{response_code} %{http_connect} %{exitcode} %{http_version}\n' \
        "$url" 2>/dev/null </dev/null || rc=$?
      report_phase bundle_download "$started"
      [ "$rc" -eq 0 ] || return 1
      started=$(clock_mark)
      got=$(openssl dgst -sha512 -binary <"$dest.bundle" | base64 -w0) || return 1
      report_phase bundle_verify "$started"
      [ "sha512-$got" = "$expected" ] || return 1
      started=$(clock_mark)
      if [ "$encoding" = zstd ]; then
        tar --zstd -xf "$dest.bundle" -C "$dest" 2>/dev/null || rc=$?
      else
        tar -xzf "$dest.bundle" -C "$dest" 2>/dev/null || rc=$?
      fi
      report_phase bundle_extract "$started"
      [ "$rc" -eq 0 ]
    }
    bundle_install() {
      [ -n "$image_executable" ] || return 1
      [ "$(uname -s)" = Linux ] || return 1
      case "$(uname -m)" in x86_64|amd64) ;; *) return 1 ;; esac
      ldd --version 2>&1 | grep -qi musl && return 1
      command -v curl >/dev/null && command -v openssl >/dev/null || return 1
      local encoding=gzip url=$bundle_gzip_url expected=$bundle_gzip_integrity started rc=0
      if command -v zstd >/dev/null; then
        encoding=zstd; url=$bundle_zstd_url; expected=$bundle_zstd_integrity
      fi
      [ -n "$url" ] || return 1
      started=$(clock_mark)
      bundle_extract "$1" "$encoding" "$url" "$expected" || rc=$?
      rm -f "$1.bundle"
      report_phase bundle "$started"
      if [ "$rc" -eq 0 ]; then
        printf '__MANAGOAT_INSTALL__ bundle_hit 1\n'
        return 0
      fi
      printf '__MANAGOAT_INSTALL__ bundle_hit 0\n'
      rm -rf "$1"
      mkdir -p "$1"
      return 1
    }
    """
  end

  # Whether this install reuses the image's CLI: the runtime has a seam
  # (`@image_reuse`) and the provider's image has been checked against it.
  # Sprites, for both. E2B, for codex only: its platform package is the 163 MB
  # that otherwise crosses the broker on every cold codex provision (#2886),
  # and the `fountain` template's image ships a codex at or above the floor
  # (codex-cli 0.162.1 in loam-e2b-fountain@sha256:8e47934b, checked
  # 2026-10-17), installed by npm, so `readlink -f` lands on the JS wrapper
  # #2914 already handles. A template without codex, or with one below the
  # floor, selects nothing and installs the bundled CLI as before. Claude on
  # E2B is unchanged: its bundled copy is small. Anywhere else the selector is
  # not emitted at all.
  defp image_reuse?(runtime, :sprites), do: Map.has_key?(@image_reuse, runtime)
  defp image_reuse?("codex", :e2b), do: true
  defp image_reuse?(_runtime, _provider), do: false

  # Where a selected executable is recorded, inside the versioned install
  # directory. Named after the runtime so the two adapters cannot read each
  # other's, and so claude's keeps the name installs already on disk wrote.
  defp image_marker(runtime), do: ".#{runtime}-executable"

  # The manifest rows a selected image executable replaces, as one glob. Emitted
  # for every provider but only consulted when an executable was selected, so a
  # provider without reuse installs the whole pinned tree.
  defp image_bundled(runtime) do
    case @image_reuse[runtime] do
      %{bundled: bundled} -> bundled
      nil -> ""
    end
  end

  # Keep the adapter/JS tree pinned, but avoid downloading a second copy of a
  # CLI the Sprite image already carries. Resolve the image symlink once so an
  # auto-update does not silently change the executable this installation
  # recorded. The floor is the CLI paired with our pin; it is not a promise of
  # old model aliases. Anything that fails a step here leaves
  # `image_executable` empty, which is the bundled install.
  defp image_select_fn(runtime, provider) do
    if image_reuse?(runtime, provider) do
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
    else
      ""
    end
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
  # It also exports the recorded image executable, when there is one, in the
  # variable this runtime's adapter reads. The line is written for every
  # provider: the marker only exists where reuse was selected, so on E2B it
  # reads a file that is not there and exports nothing.
  defp launcher_fn(runtime) do
    reuse_line =
      case @image_reuse[runtime] do
        %{env: env} ->
          marker = image_marker(runtime)

          ~s(  '[ ! -f "$d/#{marker}" ] || ) <>
            ~s({ read -r #{env} <"$d/#{marker}"; export #{env}; }' \\\n)

        nil ->
          ""
      end

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

  # 16 workers, as before, but a worker no longer means a connection. One
  # worker per package meant one TLS handshake per package: 104 of them for
  # claude at a concurrency of 16, so the install paid ~6.5 serialized waves of
  # setup to move 6.93 MiB whose median package is 6 KB, and time-to-first-byte
  # was 0.42 s cold against 0.11 s warm (managoat/managoat#2905). Portable
  # packages therefore travel in *shards*: one curl process per shard fetches
  # its packages in sequence over a single connection, so a shard pays one
  # handshake and the rest of its packages ride it. No more than 16 fetches
  # run at once, as before.
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
  # Sequence is what a shard pays for its one handshake: a slow package delays
  # the packages after it in the same shard. Two bounds keep a degraded network
  # from turning that into a slow install. A shard's whole fetch gets the 30
  # seconds one package's first attempt had, not 30 per package, so a shard of
  # seven cannot take 210 s against the exec's 180 s deadline. And packages a
  # shard did not deliver -- failed, cut off by that budget, or never reached --
  # are not retried one after another inside their shard: they go to a retry
  # lane where each gets its own worker and connection, as every package did
  # before shards. The shard's fetch counts as each such package's first
  # attempt, whether or not the shard reached it, so no package is fetched more
  # than three times. The retry lane starts once every shard has finished, so a
  # retry can wait up to one shard budget for its turn.
  #
  # A tarball from a shard is accepted only when curl reported *that* transfer
  # as finished. curl's own exit status describes only its last transfer: a
  # middle package can 404, or stall past its time limit, and curl still exits
  # 0. Each transfer writes its own exit code next to its own file name, and a
  # file without a 0 against it is discarded unread, so a partial tarball left
  # behind by the shard budget is retried rather than mistaken for an integrity
  # failure. A curl too old for --remove-on-error, or a sandbox without
  # `timeout`, streams every package instead, which is exactly what this
  # installer did before shards existed.
  #
  # A sharded package is verified against its own sha512 *before* it is
  # extracted, which is stricter than the streaming lane, where the hash
  # necessarily arrives after the bytes have been unpacked -- into the
  # install's staging directory, so a mismatch fails the install, which never
  # gets its `.installed` marker or the PATH link, and nothing unverified runs
  # either way. An integrity mismatch is never retried. The os/cpu/libc filter
  # and the image-executable skip run once over the manifest rather than once
  # per worker, because the lanes and their widths have to be known before the
  # first worker starts. The skip takes a `prefix*` pattern and the selected
  # executable as data, so a selector for another runtime only has to supply
  # its own. `--strip-components=1` because a tarball's top directory is named
  # by its author, usually but not always `package/`. Each package's time goes
  # to `.timing`, and a shard records its shared fetch there too. Retried
  # downloads unpack into a fresh worker directory; verified files are
  # hard-linked into the shared staging tree so retry cleanup cannot remove a
  # concurrently installed nested dependency.
  defp manifest_install_fn do
    ~S"""
    manifest_install() {
      command -v curl >/dev/null && command -v openssl >/dev/null &&
        command -v mkfifo >/dev/null && command -v awk >/dev/null || return 1
      local arch libc shard_budget stream batch retry one stream_n batch_n stream_par batch_par chunk sharded rc pid
      arch=$(uname -m)
      case "$arch" in x86_64|amd64) arch=x64 ;; aarch64|arm64) arch=arm64 ;; esac
      libc=glibc
      if ldd --version 2>&1 | grep -qi musl; then libc=musl; fi
      mkdir -p "$2/.dl" || return 1
      stream="$2/.dl/stream.rows"
      batch="$2/.dl/batch.rows"
      retry="$2/.dl/retry.rows"
      : >"$stream" && : >"$batch" && : >"$retry" || return 1
      sharded=1
      curl --help all 2>/dev/null | grep -q -- --remove-on-error || sharded=0
      command -v timeout >/dev/null || sharded=0
      # Seconds for a shard's whole fetch: one package's first attempt.
      shard_budget=30
      # The platform filter and the image-executable skip, over the manifest
      # once. A row with any os/cpu/libc constraint is a native binary and
      # streams. `$image_bundled` is the runtime's `prefix*` pattern for the
      # rows a selected image executable replaces; awk matches its prefix, and
      # nothing is skipped when no executable was selected.
      awk -F'\t' -v cpu_want="$arch" -v libc_want="$libc" -v reuse="$image_executable" \
        -v bundled="$image_bundled" -v sharded="$sharded" -v stream="$stream" -v batch="$batch" '
        BEGIN { sub(/\*$/, "", bundled) }
        NF < 6 { next }
        !($4 == "-" || index("," $4 ",", ",linux,")) { next }
        !($5 == "-" || index("," $5 ",", "," cpu_want ",")) { next }
        !($6 == "-" || index("," $6 ",", "," libc_want ",")) { next }
        reuse != "" && bundled != "" && index($1, bundled) == 1 { next }
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
      # One package over a connection of its own, streamed through a FIFO into
      # tar, from attempt $ACP_FIRST to the third: the native lane, and the
      # retries of packages a shard did not deliver.
      one='
        set -o pipefail
        IFS=$'"'"'\t'"'"' read -r path url sri <<<"$1"
        s=$(date +%s%N)
        work="$ACP_DEST/.dl/$(printf "%s" "$path" | tr "/@" "__")"
        mkdir -p "$work" || exit 1
        for attempt in 1 2 3; do
          [ "$attempt" -ge "$ACP_FIRST" ] || continue
          # Never ask curl to retry a stream: it would append a second gzip
          # archive to the first hash/extractor. Each attempt starts afresh.
          rm -rf "$work/unpacked" "$work/pipe"
          mkdir -p "$work/unpacked" && mkfifo "$work/pipe" || exit 1
          tar xzf - -C "$work/unpacked" --strip-components=1 <"$work/pipe" 2>/dev/null &
          untar=$!
          got=$(curl -fsS --connect-timeout 5 --max-time 30 --speed-limit 1024 --speed-time 5 --write-out "%{stderr}__MANAGOAT_DOWNLOAD__ %{time_namelookup} %{time_connect} %{time_appconnect} %{time_starttransfer} %{time_total} %{size_download} %{num_connects}\n__MANAGOAT_DOWNLOAD_RESULT__ %{response_code} %{http_connect} %{exitcode} %{http_version}\n" "$url" 2>"$work/curl-metrics" </dev/null |
            tee "$work/pipe" | openssl dgst -sha512 -binary | base64 -w0)
          fetched=$?
          sed -n "/^__MANAGOAT_DOWNLOAD__ /p; /^__MANAGOAT_DOWNLOAD_RESULT__ /p" "$work/curl-metrics"
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
      '
      rc=0
      pid=
      if [ "$stream_n" -gt 0 ]; then
        ACP_FIRST=1 ACP_DEST=$2 xargs -d '\n' -n1 -P"$stream_par" bash -c "$one" _ <"$stream" &
        pid=$!
      fi
      if [ "$batch_n" -gt 0 ]; then
        ACP_BUDGET=$shard_budget ACP_DEST=$2 xargs -d '\n' -n"$chunk" -P"$batch_par" bash -c '
        set -o pipefail
        shard="$ACP_DEST/.dl/shard-$$"
        rm -rf "$shard" && mkdir -p "$shard" || exit 1
        n=0
        args=()
        for row in "$@"; do
          n=$((n + 1))
          IFS=$'"'"'\t'"'"' read -r path url sri <<<"$row"
          printf "%s\t%s\t%s\t%s\n" "$n" "$path" "$url" "$sri" >>"$shard/rows"
          args+=(--output "$n.tgz" --url "$url")
        done
        s=$(date +%s%N)
        # One process for the whole shard, so only its first package pays a
        # handshake, and the whole of it inside one package budget. Never ask
        # curl to retry: a retried transfer would append a second gzip archive
        # to the first. %{exitcode} is per transfer, and %{filename_effective}
        # says which, so a package is judged on its own status.
        (cd "$shard" && exec timeout -k 2 "$ACP_BUDGET" curl -fsS --connect-timeout 5 --max-time 30 --speed-limit 1024 --speed-time 5 --remove-on-error --write-out "%{stderr}__MANAGOAT_DOWNLOAD__ %{time_namelookup} %{time_connect} %{time_appconnect} %{time_starttransfer} %{time_total} %{size_download} %{num_connects}\n__MANAGOAT_DOWNLOAD_RESULT__ %{response_code} %{http_connect} %{exitcode} %{http_version}\n__MANAGOAT_FETCHED__ %{exitcode} %{filename_effective}\n" "${args[@]}") 2>"$shard/curl-metrics" </dev/null
        whole=$?
        # Only fixed numeric marker lines leave a worker: curl writes URLs and
        # proxy hosts into its own diagnostics.
        sed -n "/^__MANAGOAT_DOWNLOAD__ /p; /^__MANAGOAT_DOWNLOAD_RESULT__ /p" "$shard/curl-metrics"
        printf "fetch:shard-%s %s\n" "$$" "$(( ($(date +%s%N) - s) / 1000000 ))" >>"$ACP_DEST/.timing"
        while IFS=$'"'"'\t'"'"' read -r n path url sri; do
          p=$(date +%s%N)
          # Measured from the shard, since its fetch is the part the packages
          # in it share. The per-package stage time goes to .timing below.
          # No apostrophes in here: this body is a single-quoted argument.
          elapsed=$(( (p - s) / 1000000 ))
          fetched=$(sed -n "s/^__MANAGOAT_FETCHED__ \([0-9]*\) $n\.tgz\$/\1/p" "$shard/curl-metrics")
          # No status at all: the shard budget (124) stopped curl before this
          # transfer finished, or before it began.
          [ -n "$fetched" ] || fetched=$whole
          if [ "$fetched" != 0 ] || [ ! -f "$shard/$n.tgz" ]; then
            # Do not echo URLs, proxy credentials or arbitrary command output.
            printf "adapter package failed: package=%s step=fetch attempt=1/3 exit=%s elapsed_ms=%s\n" "$path" "$fetched" "$elapsed" >&2
            # Whatever is on disk is unconfirmed, possibly partial: discard it
            # unread, and fetch the package again on a connection of its own.
            rm -f "$shard/$n.tgz"
            printf "%s\t%s\t%s\n" "$path" "$url" "$sri" >>"$shard.retry"
            continue
          fi
          # Verified before it is extracted, so nothing unverified is ever
          # written under the staging tree.
          got=$(openssl dgst -sha512 -binary "$shard/$n.tgz" | base64 -w0)
          if [ "sha512-$got" != "$sri" ]; then
            printf "adapter package failed: package=%s step=verify integrity mismatch elapsed_ms=%s\n" "$path" "$elapsed" >&2
            exit 1
          fi
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
          printf "%s %s\n" "$path" "$(( ($(date +%s%N) - p) / 1000000 ))" >>"$ACP_DEST/.timing"
        done <"$shard/rows"
        rm -rf "$shard"
      ' _ <"$batch" || rc=1
        # Attempts two and three, a worker each, once the shards are done. A
        # failed lane fails the install anyway, so it retries nothing.
        if [ "$rc" -eq 0 ]; then
          cat "$2"/.dl/shard-*.retry >"$retry" 2>/dev/null || :
          if [ -s "$retry" ]; then
            ACP_FIRST=2 ACP_DEST=$2 xargs -d '\n' -n1 -P"$batch_par" bash -c "$one" _ <"$retry" || rc=1
          fi
        fi
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
