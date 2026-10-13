defmodule Fountain.CommandRuntime do
  @moduledoc """
  The `acp` runtime: launch the command the agent names and speak ACP to it.

  Every other runtime Fountain has is a coding agent driven by a model.
  `Managoat.Runtimes` knows four of them by name, installs a pinned adapter
  for each and hands each one an inference credential. This one knows
  nothing. The agent carries a `runtime_command`, Fountain runs it inside the
  sandbox, and whatever comes back over stdio is the Agent Client Protocol
  (ADR 0014) exactly as it is for claude or codex. That is the whole runtime.

  It exists for a deterministic program that wants what Fountain gives an
  agent and not what a model gives one. A convergent operation on a schedule,
  inside a persistent sandbox that holds the repo and the toolchain, with the
  run readable as a turn in a teammate's thread (#1634).

  ## The name

  Named for what varies, which is the command. It is the one runtime that is
  Fountain's rather than the library's. `Managoat.Runtimes.ACP` was not available and
  would have been wrong anyway, since that is the provisioning table saying
  which adapter each of the four LLM runtimes reaches the protocol through.
  `Command` alone would have read against `Managoat.Sandbox.Command`, which is
  a struct the same call sites hold.

  It lives in Fountain rather than in the library because the registry there
  is a closed map and the field it reads (`agents.runtime_command`) is
  Fountain's own column. `Fountain.RuntimeDispatch` is the host dispatch that
  resolves this module for `"acp"` and delegates everything else.

  ## What it does not do

  There is no adapter to install, no config file to write, no bootstrap to
  run and no credential to export. The command owns its own configuration,
  which is the point of naming a command rather than a runtime.

    * `write_config/2` and `prepare_sandbox/3` are not implemented at all, so
      `Fountain.Conversations.Provisioning`'s `function_exported?` guards skip
      them.
    * `build_command/5` is not implemented either. The legacy spawn path is
      dead for every runtime that speaks ACP, and this one always does.
    * `default_env/2` ignores the credentials it is handed. It exports one
      variable, `FOUNTAIN_SKILLS_DIR`, so the command can read the agent's
      skills without knowing the layout convention below.

  ## Skills still mount

  A deterministic agent may read a skill the same way a model does, so the
  ordinary skills pipeline runs. There is no CLI here with a directory of its
  own, so the layout borrows claude-code's: inline skills are written under
  `/home/sprite/.claude/skills`, and a github-source skill is installed by
  skills.sh with `--agent claude-code`, which puts it in the same tree. One
  location rather than two, and the path is exported so the command need not
  know which one was chosen.
  """

  @behaviour Managoat.Runtimes

  # claude-code's tree, borrowed. skills.sh has no agent id for a command it
  # has never heard of, and this is the layout the others copy. `skills_root/0`
  # and `skills_sh_agent/0` have to agree or a github skill and an inline one
  # land in different directories.
  @skills_root "/home/sprite/.claude/skills"
  @skills_sh_agent "claude-code"

  @doc """
  Where the command's argv comes from.

  A shell line rather than a parsed argv, and always run through
  `bash -lc`. Three reasons, all of them about the sandbox rather than about
  us: the command is resolved against the sandbox's own PATH (a login shell
  is what puts `~/.local/bin` and the language shims on it), an operator can
  write `cd /srv/app && bin/agent acp` without Fountain inventing a
  chdir field, and quoting is the shell's rule, which is the rule whoever
  wrote the string already knows.

  Returns `:error` when there is no command to run. The changeset requires
  one for this runtime, so that means an agent deleted out from under a live
  conversation. `Fountain.Conversations.TurnMachine.open/4` refuses the turn
  there rather than opening one with nothing to spawn, which is what makes
  `Fountain.RuntimeDispatch.command/2`'s match total.
  """
  @spec argv(map() | nil) :: {:ok, {String.t(), [String.t()]}} | :error
  def argv(%{runtime_command: cmd}) when is_binary(cmd) do
    case String.trim(cmd) do
      "" -> :error
      line -> {:ok, {"bash", ["-lc", line]}}
    end
  end

  def argv(_agent), do: :error

  @impl true
  def skills_root, do: @skills_root

  @impl true
  def skills_sh_agent, do: @skills_sh_agent

  # No inference credential, on purpose: a turn on this runtime resolves
  # none, so an account that holds no key at all runs one. The skills path is
  # here because the command has no convention to fall back on.
  @impl true
  def default_env(_agent, _inference_credentials), do: [{"FOUNTAIN_SKILLS_DIR", @skills_root}]
end
