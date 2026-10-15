defmodule Managoat.Runtimes do
  @moduledoc """
  Behaviour every runtime (claude/codex/gemini) implements,
  plus a small dispatcher.

  How a coding agent CLI gets into a sandbox and comes up speaking the Agent
  Client Protocol: which adapter to install and at what version
  (`Managoat.Runtimes.ACP`), where its files go (`Managoat.Runtimes.Layout`),
  the instructions file (`Managoat.Runtimes.Instructions`), the skills tree
  (`Managoat.Runtimes.Skills`), the credential env vars (each runtime's
  `default_env/2`), and the per-runtime workarounds with the condition for
  deleting each (`Managoat.Runtimes.Quirks`). The protocol session itself is
  `Managoat.ACP.Peer`; this library is the **provisioning** half that a peer
  needs to have happened first.

  `build_command/5` has **no implementation left** — gemini was the last
  runtime to build a CLI argv for a turn, and that went when every runtime
  moved onto ACP — so the callback stays optional and a host's legacy spawn
  path is unreachable for any runtime `for_runtime/1` will resolve. It is kept
  rather than deleted because a fifth runtime that cannot speak ACP would
  need it, and because the turn machinery a host builds around it (log
  budget, exit handling) is shared and still exercised through
  `Managoat.Runtimes.Testing.FakeRuntime`.

  What varies between runtimes here falls into three kinds, and only the last
  needs code:

    * **Layout** — where files go. Perfectly regular (`<home>/<config_dir>/…`)
      and now stated once, in `Managoat.Runtimes.Layout`. `skills_root/0`,
      `skills_sh_agent/0`, the instructions path and every workspace directory
      are derived from that table rather than restated per module.
    * **Workarounds** — a defect each runtime carries, with a deletion
      condition. Registered in `Managoat.Runtimes.Quirks`, which names the
      function implementing each one and is guarded by a test, so a workaround
      cannot outlive its defect unnoticed.
    * **Credential delivery** — genuinely irreducible, and two shapes rather
      than three: an env var (claude, gemini) or a login exec that consumes
      the key on stdin (codex, whose CLI ignores the process env). See
      `c:default_env/2` and `c:prepare_sandbox/3`.

  ## Calling the optional callbacks

  Six callbacks are optional and the implementation matrix is genuinely
  sparse, so a host has to guard the call — and the obvious guard is wrong:

      # WRONG: silently no-ops in an escript or a release
      if function_exported?(mod, :default_env, 2), do: mod.default_env(agent, creds), else: []

  `function_exported?/3` answers `false` for a module that is merely **not
  loaded yet**, which is the normal state of any module nobody has called
  under an escript or a release. It has already cost one host a provisioning
  run that reported every stage green and then failed on an authentication
  error, because `Managoat.Runtimes.Claude` was unloaded rather than because
  it was missing `default_env/2` — which it implements, as do all three
  runtimes.

  So dispatch through the functions here instead. They load the module first
  and fall back to the documented no-op:

      env = Managoat.Runtimes.default_env(mod, agent, credentials)   # or []
      :ok = Managoat.Runtimes.write_config(mod, handle, agent)       # or :ok
      :ok = Managoat.Runtimes.prepare_sandbox(mod, handle, agent, env)
      env = env ++ Managoat.Runtimes.model_env(mod, model)            # or []
      caps = Managoat.Runtimes.client_capabilities(mod)              # or the ACP default

  `c:build_command/5` has no default to fall back to; ask
  `implements?/3` and decide.
  """

  @type mode :: :run | :continue
  @type cmd :: {String.t(), [String.t()], keyword()}

  @typedoc """
  What a runtime reads from the agent it provisions for.

  A plain map, so the host's own record satisfies it whatever else it
  carries: an Ecto struct, a decoded JSON document, a literal in a test. The
  five keys are the whole surface the library reads, and each is optional
  because every reader treats a missing one as "none":

    * `model` — the canonical `provider/model_id` (`Managoat.Runtimes.Model`).
    * `mcp_servers` — the agent's MCP servers in Claude's own config shape
      (`%{name => %{"command" | "args" | "env" | "type" | "url" | "headers"}}`),
      read by `write_config/2` and `Managoat.Runtimes.ACP.mcp_servers/1`.
    * `system` and `name` — the instructions file
      (`Managoat.Runtimes.Instructions`).
    * `runtime` — `Managoat.Runtimes.ACP.enabled?/1` accepts the agent as well
      as the bare runtime string.
  """
  @type agent :: %{
          optional(:model) => String.t() | nil,
          optional(:mcp_servers) => map() | nil,
          optional(:system) => String.t() | nil,
          optional(:name) => String.t() | nil,
          optional(:runtime) => String.t() | nil,
          optional(atom()) => term()
        }

  @doc """
  Build the argv (and any extra spawn opts like `:env`) for a single turn on
  the **legacy** spawn path. Only runtimes excluded from
  `Managoat.Runtimes.ACP.supported_runtimes/0` need this; for everything else
  the turn travels over ACP and argv says nothing about it.

  - `mode == :run` for the first turn
  - `mode == :continue` for subsequent turns
  - `runtime_session_id` is the runtime CLI's own session id used for resume

  Optional, and the one optional callback with no dispatcher — there is no
  argv to fall back to. Guard it with `implements?/3` rather than
  `function_exported?/3`; see
  ["Calling the optional callbacks"](#module-calling-the-optional-callbacks).
  """
  @callback build_command(
              agent :: agent(),
              prompt :: String.t(),
              mode :: mode(),
              runtime_session_id :: String.t() | nil,
              opts :: keyword()
            ) :: cmd()

  @doc """
  Default env vars for the runtime — typically the inference credential
  for the chosen provider (e.g. `ANTHROPIC_API_KEY`).

  `inference_credentials` is a map of `%{provider_atom => plaintext_string}`
  the host decrypts for the tenant at conversation start. The keys a runtime
  reads are `:anthropic_api_key`, `:claude_code_oauth_token`,
  `:openai_api_key` and `:gemini_api_key`; providers the user hasn't set are
  simply absent from the map.

  ## Why this cannot be a table

  Three things happen here that layout cannot express, and they are the
  reason this stays a callback rather than another column:

    * **Which provider.** claude, codex and gemini each have one, so the
      variable is fixed per runtime today. A multi-provider runtime (the
      removed opencode was one) would need a function of `agent.model`.
    * **Which credential, for one provider.** claude takes either a
      `CLAUDE_CODE_OAUTH_TOKEN` (bills a Claude.ai subscription) or an
      `ANTHROPIC_API_KEY` (metered), never both — exporting both has picked
      the wrong one depending on CLI version. The precedence, and the
      mid-conversation fall back to the API key when an org refuses the OAuth
      token (#655), are provider policy with no analogue on the others.
    * **Whether an env var works at all.** codex 0.118+ does not read
      `OPENAI_API_KEY` at exec time. It reads `~/.codex/auth.json`, the file
      `codex login --with-api-key` writes, so its credential is delivered by
      `prepare_sandbox/3` writing that file instead — see there.

  So the shape is two-of-three, not three-of-three: an env var, or a file.
  Worth restating whenever another runtime arrives, because "just add a column
  for the variable name" is right up until it is codex.

  Optional, so call it through `default_env/3`, which is the loaded-first
  dispatcher — not through a `function_exported?/3` guard, which no-ops it
  in an escript or a release. See
  ["Calling the optional callbacks"](#module-calling-the-optional-callbacks).
  """
  @callback default_env(
              agent :: agent(),
              inference_credentials :: %{atom() => String.t()}
            ) :: [{String.t(), String.t()}]

  @doc """
  Optionally write runtime-specific config files into the sprite at
  provision time (e.g. claude's `~/.claude.json` for MCP servers).
  No-op by default.

  Optional, so call it through `write_config/3` — see
  ["Calling the optional callbacks"](#module-calling-the-optional-callbacks).
  """
  @callback write_config(handle :: Managoat.Sandbox.Handle.t(), agent :: agent() | nil) ::
              :ok | {:error, term()}

  @doc """
  Optionally run any sprite-side bootstrap that has to happen *before*
  the first turn — e.g. codex needs its credentials in
  `~/.codex/auth.json` since it doesn't read `OPENAI_API_KEY` from the live
  process env.

  Receives the same `sprite_env` pairs the spawn will use. Implementers
  pull whichever keys they need out of that list. No-op by default.

  ## This is the escape hatch, and it should stay one

  Three runtimes implement it and each does something genuinely imperative —
  a credential file written from the key, a `bun install`, a `git init`. None
  of those is expressible as data, and an abstraction that swallowed them
  would cost more than the duplication it removed. What *was* data (where the
  workspace lives, what HOME is) has already moved to
  `Managoat.Runtimes.Layout`; what is left here is the residue that has to be
  code.

  Runs after `Managoat.Runtimes.ACP.install/3` and after the host's whole
  provisioning pipeline, so it can assume the adapter is on PATH. Note the
  ordering costs something: if the host has already applied a network policy
  to the sandbox, an install here needs its registry on the allowlist of any
  restricted one.

  Optional, so call it through `prepare_sandbox/4` — see
  ["Calling the optional callbacks"](#module-calling-the-optional-callbacks).
  """
  @callback prepare_sandbox(
              handle :: Managoat.Sandbox.Handle.t(),
              agent :: agent() | nil,
              sprite_env :: [{String.t(), String.t()}]
            ) :: :ok | {:error, term()}

  @doc """
  Optionally name env pairs the adapter process needs for a turn on `model`,
  on top of `c:default_env/2`. `model` is the id the host will select, bare
  or with its provider prefix. `[]` by default.

  This is for a model the pinned adapter selects only through its process
  environment: claude's `opus` alias names one Opus per process, and
  `claude-opus-5` needs `ANTHROPIC_DEFAULT_OPUS_MODEL` to be that one (see
  `Managoat.Runtimes.Claude`). The pairs belong to the spawn, not the sandbox,
  so a host that keeps an adapter running across turns respawns it when the
  answer for the next turn's model differs from the one it was spawned with.

  Optional, so call it through `model_env/2` — see
  ["Calling the optional callbacks"](#module-calling-the-optional-callbacks).
  """
  @callback model_env(model :: String.t() | nil) :: [{String.t(), String.t()}]

  @doc """
  Optionally name the ACP client capabilities the host declares on
  `initialize` for this runtime's adapter, in place of
  `Managoat.ACP.Protocol.default_client_capabilities/0`.

  A capability is a promise the host keeps for the adapter, and it changes
  what the adapter does: claude-agent-acp removes its `AskUserQuestion` tool
  unless form elicitation is declared (`Managoat.Runtimes.Claude`). The peer
  services only what was declared.

  Optional, so call it through `client_capabilities/1` — see
  ["Calling the optional callbacks"](#module-calling-the-optional-callbacks).
  """
  @callback client_capabilities() :: map()

  @doc """
  Absolute path on the sprite where inline skills are written as
  `<skills_root>/<name>/SKILL.md`. Each runtime points this at whatever
  directory its CLI scans for skills.

  Answered from `Managoat.Runtimes.Layout` by every implementation — it stays
  a callback because `Managoat.Runtimes.Skills` reaches it through the module,
  not because any runtime has ever needed to depart from the table.
  """
  @callback skills_root() :: String.t()

  @doc """
  Identifier passed to `npx skills add ... --agent <id>` when installing
  a github-source skill. The skills.sh CLI uses this to choose the
  on-disk layout for the target runtime (claude-code, codex, gemini-cli). Also from `Managoat.Runtimes.Layout`.
  """
  @callback skills_sh_agent() :: String.t()

  @optional_callbacks build_command: 5,
                      default_env: 2,
                      write_config: 2,
                      prepare_sandbox: 3,
                      model_env: 1,
                      client_capabilities: 0

  @runtime_modules %{
    "claude" => Managoat.Runtimes.Claude,
    "codex" => Managoat.Runtimes.Codex,
    "gemini" => Managoat.Runtimes.Gemini
  }

  @doc "Look up the runtime module for an agent's runtime string."
  def for_runtime(name) when is_binary(name) do
    case Map.fetch(@runtime_modules, name) do
      {:ok, mod} -> {:ok, mod}
      :error -> {:error, "unsupported runtime: #{name}"}
    end
  end

  @doc """
  Dispatch `c:default_env/2`, or `[]` when the runtime does not implement it.

  Use this rather than guarding the call yourself — see
  ["Calling the optional callbacks"](#module-calling-the-optional-callbacks).
  """
  @spec default_env(module(), agent(), %{atom() => String.t()}) :: [{String.t(), String.t()}]
  def default_env(mod, agent, inference_credentials) when is_atom(mod),
    do: dispatch(mod, :default_env, [agent, inference_credentials], [])

  @doc """
  Dispatch `c:write_config/2`, or `:ok` when the runtime does not implement it.

  Use this rather than guarding the call yourself — see
  ["Calling the optional callbacks"](#module-calling-the-optional-callbacks).
  """
  @spec write_config(module(), Managoat.Sandbox.Handle.t(), agent() | nil) ::
          :ok | {:error, term()}
  def write_config(mod, handle, agent) when is_atom(mod),
    do: dispatch(mod, :write_config, [handle, agent], :ok)

  @doc """
  Dispatch `c:prepare_sandbox/3`, or `:ok` when the runtime does not
  implement it.

  Use this rather than guarding the call yourself — see
  ["Calling the optional callbacks"](#module-calling-the-optional-callbacks).
  """
  @spec prepare_sandbox(module(), Managoat.Sandbox.Handle.t(), agent() | nil, [
          {String.t(), String.t()}
        ]) :: :ok | {:error, term()}
  def prepare_sandbox(mod, handle, agent, sprite_env) when is_atom(mod),
    do: dispatch(mod, :prepare_sandbox, [handle, agent, sprite_env], :ok)

  @doc """
  Dispatch `c:model_env/1`, or `[]` when the runtime does not implement it.

  Use this rather than guarding the call yourself — see
  ["Calling the optional callbacks"](#module-calling-the-optional-callbacks).
  """
  @spec model_env(module(), String.t() | nil) :: [{String.t(), String.t()}]
  def model_env(mod, model) when is_atom(mod),
    do: dispatch(mod, :model_env, [model], [])

  @doc """
  Dispatch `c:client_capabilities/0`, or
  `Managoat.ACP.Protocol.default_client_capabilities/0` when the runtime does
  not implement it (and for a custom `acp` runtime, which has no module).

  Use this rather than guarding the call yourself — see
  ["Calling the optional callbacks"](#module-calling-the-optional-callbacks).
  """
  @spec client_capabilities(module() | nil) :: map()
  def client_capabilities(mod) when is_atom(mod),
    do:
      dispatch(mod, :client_capabilities, [], Managoat.ACP.Protocol.default_client_capabilities())

  @doc """
  Whether `mod` implements the optional callback `fun/arity`, loading it
  first if it has not been loaded yet.

  The five callbacks with a sensible default have a dispatcher above;
  `c:build_command/5` has none — there is no argv to fall back to — so a host
  on the legacy spawn path asks this before calling it, and decides for
  itself what an unimplemented runtime means.

      if Managoat.Runtimes.implements?(mod, :build_command, 5) do
        mod.build_command(agent, prompt, :run, session_id, opts)
      else
        {:error, :acp_only_runtime}
      end

  `Code.ensure_loaded?/1` is the whole point: `function_exported?/3` alone
  answers `false` for a module that is merely not loaded yet, which in an
  escript or a release is the normal state of a module nobody has called.
  """
  @spec implements?(module(), atom(), arity()) :: boolean()
  def implements?(mod, fun, arity) when is_atom(mod) and is_atom(fun) and is_integer(arity),
    do: Code.ensure_loaded?(mod) and function_exported?(mod, fun, arity)

  defp dispatch(mod, fun, args, default) do
    if implements?(mod, fun, length(args)) do
      apply(mod, fun, args)
    else
      default
    end
  end
end
