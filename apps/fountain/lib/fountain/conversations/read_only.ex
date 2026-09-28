defmodule Fountain.Conversations.ReadOnly do
  @moduledoc """
  A turn that runs without write access (#2533).

  A prompt may ask for `read_only: true`. The turn it opens runs in the same
  conversation, on the same runtime session, so the agent answers from the
  whole thread's context, but the agent cannot change the checkout. That is a
  permission, not an instruction: nothing here puts a word in the prompt. The
  runtime enforces it, or the prompt is refused.

  The flag is stored on the turn (`turns.read_only`), and every launch of that
  turn reads the row: the first spawn, a relaunch after a native crash
  (`TurnLaunch.relaunch_crashed/3`) or a locked Codex state, a session
  restarted after a failed resume, and a peer reattached after a deploy
  (`Reattachment.acp_peer/3`). The flag never lives only in a message.

  ## Claude: a fresh adapter under a managed policy

  The pinned `claude-agent-acp` reads its permission mode and tool lists at
  session creation, from `_meta.claudeCode.options`, and `Managoat.ACP.Peer`
  sends only the two execution-limit options there. The per-process lever it
  does have is the Claude Code CLI's managed-settings directory,
  `CLAUDE_CODE_MANAGED_SETTINGS_PATH`: the highest-precedence settings source,
  read by the adapter's own settings resolution and by the CLI it spawns.

  So a read-only turn never rides an idle connection. It gets its own adapter
  process, spawned through `command/3`, which writes `managed_settings/0` to a
  directory under `$HOME` and points that variable at it. The session is
  resumed by id, so the context is the conversation's. The policy:

    * denies `Bash`, `Edit`, `MultiEdit`, `NotebookEdit` and `Write`, which
      is every built-in tool that writes. A deny rule wins over any allow rule
      in any source.
    * sets `allowManagedPermissionRulesOnly`, so every allow rule a normal turn
      stored earlier is ignored. Fountain's default answer to a permission
      request is `allow_always`, and on claude that writes rules into the
      checkout's `.claude/settings.local.json`; without this flag a command
      allowed that way would run without asking.
    * pins the default permission mode and disables bypass and auto mode, so
      nothing in the checkout can widen the mode.

  With stored allow rules ignored, every other tool that is not read-only asks
  before it runs, and `permission_policy/2` answers: it clamps the turn's
  policy to deny everything except ACP's `read`, `search`, `think` and `fetch`
  kinds. That covers MCP tools and a `switch_mode` out of plan mode.

  A write attempt therefore fails inside Claude Code, the model sees the
  refusal as the tool's result, and the turn completes with its answer.

  The adapter's spawn env carries `FOUNTAIN_READ_ONLY=1` (`spawn_env/2`),
  recorded with the peer like the model env, so `Connection.stale_reason/5`
  closes an idle peer whose mode differs from the next turn's: a normal turn
  after a read-only one gets a writable adapter again, and the other way round.

  ## Codex, Gemini, OpenCode: refused

  codex-acp 1.10.0 sends `sandboxPolicy` on every `turn/start`, from one of
  its three modes, and none of them is read-only: its `read-only` mode is a
  `workspaceWrite` sandbox with on-request approval, whose writes inside the
  workspace are never asked about. That per-turn override also wins over any
  `sandbox_mode` in Codex's config. There is no way to run a Codex turn
  read-only through the pinned adapter, so the prompt is refused
  (`{:read_only_unsupported, runtime}`, a 422 at the door) rather than run
  writable. Gemini and OpenCode have no lever either; OpenCode never asks
  before running a tool at all.
  """

  alias Fountain.Conversations
  alias Fountain.Conversations.{Output, Turn}

  @supported ~w(claude)

  @env_key "FOUNTAIN_READ_ONLY"

  # Every built-in Claude Code tool that writes. `MultiEdit` is gone from
  # recent CLIs and harmless to name; a CLI that still has it must not escape.
  @denied_tools ~w(Bash Edit MultiEdit NotebookEdit Write)

  # ACP's read-only tool kinds. Everything else, including `other` (MCP tools)
  # and `switch_mode`, falls to the default.
  @read_only_policy %{
    "default" => "auto_deny",
    "read" => "auto_allow",
    "search" => "auto_allow",
    "think" => "auto_allow",
    "fetch" => "auto_allow"
  }

  @doc "Runtimes that can run a read-only turn."
  @spec supported_runtimes() :: [String.t()]
  def supported_runtimes, do: @supported

  @doc "Whether `runtime` enforces a read-only turn."
  @spec supported?(String.t() | nil) :: boolean()
  def supported?(runtime), do: runtime in @supported

  @doc """
  `:ok` when a prompt may run with `read_only` on `runtime`: always for a
  normal prompt, and for a read-only one only where the runtime enforces it.
  """
  @spec check(boolean() | nil, String.t() | nil) ::
          :ok | {:error, {:read_only_unsupported, String.t() | nil}}
  def check(true, runtime) do
    if supported?(runtime), do: :ok, else: {:error, {:read_only_unsupported, runtime}}
  end

  def check(_read_only, _runtime), do: :ok

  @doc """
  The refusal when the server is asked to open a read-only turn its runtime
  cannot enforce. The door refuses first; this is the backstop for a caller
  that is not the door. Nothing is written, and the stream says why.
  """
  @spec refuse_unsupported(Conversations.Conversation.t(), keyword()) ::
          :ok | {:error, {:read_only_unsupported, String.t() | nil}}
  def refuse_unsupported(conv, opts) do
    case check(opts[:read_only], conv.runtime) do
      :ok ->
        :ok

      {:error, _} = error ->
        Output.publish_stage(conv.id, "turn", "failed", %{
          reason: "read_only_unsupported",
          runtime: conv.runtime,
          message: unsupported_message(conv.runtime)
        })

        error
    end
  end

  @doc "What the door and the stream say when `runtime` cannot run a read-only turn."
  @spec unsupported_message(String.t() | nil) :: String.t()
  def unsupported_message(runtime) do
    "the #{runtime} runtime cannot enforce a read-only turn, so the prompt was not run. " <>
      "Read-only turns run on: #{Enum.join(@supported, ", ")}."
  end

  @doc """
  The admitted turn, or a refusal when it was asked for read-only and the row
  says otherwise.

  Admission runs in the machine's owner, which during a rollout can be a node
  of the release before this one: its changeset does not cast `read_only`, so
  the turn it inserts is a normal one. Running that turn would run a
  read-only prompt writable. It is ended failed instead, before anything is
  spawned.
  """
  @spec confirm_admitted(Conversations.Conversation.t(), Turn.t(), keyword()) ::
          {:ok, Conversations.Conversation.t(), Turn.t()} | {:error, :read_only_unavailable}
  def confirm_admitted(conv, %Turn{} = turn, opts) do
    if opts[:read_only] == true and turn.read_only != true do
      # ownership: the actor's own turn, admitted for it a moment ago.
      {:ok, _} = Conversations._unsafe_update_turn(turn, %{status: "failed"})
      {:ok, _} = Conversations._unsafe_idle_after_turn(turn)

      Output.publish_stage(conv.id, "turn", "failed", %{
        turn_id: turn.id,
        reason: "read_only_unavailable",
        message:
          "This turn was asked to run read-only and could not be started that way " <>
            "during a deploy. Nothing ran. Send the prompt again."
      })

      {:error, :read_only_unavailable}
    else
      {:ok, conv, turn}
    end
  end

  @doc """
  The permission policy a turn's peer answers with: `policy` as it is for a
  normal turn, clamped to deny every tool kind but the read-only ones for a
  read-only turn. The clamp only ever narrows (`Managoat.ACP.Permissions.effective/2`).
  """
  @spec permission_policy(map(), Turn.t()) :: map()
  def permission_policy(policy, %Turn{read_only: true}),
    do: Managoat.ACP.Permissions.effective(policy, @read_only_policy)

  def permission_policy(policy, %Turn{}), do: policy

  @doc """
  The adapter's spawn env for this turn: the model env `TurnMachine.model_env/3`
  gives, marked when the turn is read-only. Recorded with the peer, so an idle
  peer spawned in the other mode is not reused.
  """
  @spec spawn_env([{String.t(), String.t()}], Turn.t()) :: [{String.t(), String.t()}]
  def spawn_env(model_env, %Turn{read_only: true}), do: model_env ++ [{@env_key, "1"}]
  def spawn_env(model_env, %Turn{}), do: model_env

  @doc "Whether a recorded spawn env is a read-only adapter's."
  @spec spawned_read_only?([{String.t(), String.t()}] | nil) :: boolean()
  def spawned_read_only?(env) when is_list(env), do: {@env_key, "1"} in env
  def spawned_read_only?(_env), do: false

  # Positional arguments to a fixed script, as `TurnLaunch`'s relaunch delay
  # is: `$1` is the policy, the rest is the adapter's argv. The policy is
  # written to a temporary name and moved into place, so two read-only turns
  # starting at once on one machine never read a half-written file, and `exec`
  # keeps the process the provider names its session for.
  @wrapper ~S"""
  umask 077
  d="$HOME/.fountain/read-only/claude"
  mkdir -p "$d" || exit 70
  printf '%s' "$1" > "$d/managed-settings.json.$$" || exit 70
  mv -f "$d/managed-settings.json.$$" "$d/managed-settings.json" || exit 70
  shift
  export CLAUDE_CODE_MANAGED_SETTINGS_PATH="$d"
  exec "$@"
  """

  @doc """
  The adapter's argv for this turn. A normal turn's is unchanged; a read-only
  turn's installs `managed_settings/0` in front of the adapter. A runtime
  without the lever never gets here: `TurnLaunch` fails such a turn first.
  """
  @spec command(Turn.t(), String.t(), [String.t()]) :: {String.t(), [String.t()]}
  def command(%Turn{read_only: true}, cmd, args),
    do: {"sh", ["-c", @wrapper, "fountain-read-only", managed_settings(), cmd | args]}

  def command(%Turn{}, cmd, args), do: {cmd, args}

  @doc "The Claude Code managed settings a read-only turn's adapter runs under."
  @spec managed_settings() :: String.t()
  def managed_settings do
    Jason.encode!(%{
      "allowManagedPermissionRulesOnly" => true,
      "disableAutoMode" => "disable",
      "permissions" => %{
        "defaultMode" => "default",
        "deny" => @denied_tools,
        "disableBypassPermissionsMode" => "disable"
      }
    })
  end

  @doc "The built-in tools the managed policy denies."
  @spec denied_tools() :: [String.t()]
  def denied_tools, do: @denied_tools
end
