defmodule Managoat.Runtimes.Instructions do
  @moduledoc """
  Deliver the agent's `system` prompt to the runtime (#848).

  `agents.system` was stored, edited, exported and rendered in every form —
  and never reached a sandbox: the ACP `session/new` / `session/prompt`
  carry `cwd`, `mcpServers` and the user's text, nothing else, and no
  runtime module wrote it anywhere. Every agent ran on its CLI's default
  persona.

  Each runtime reads a user-level instructions file at session start; that
  file is the one place all of them honour without flags, and it survives
  suspend/resume on the sandbox disk. Written at provision and rewritten at
  every reattach, so an edit to the agent's prompt lands on its existing
  computer the next time it wakes. An empty/blank prompt removes nothing and
  writes nothing — the CLI's default stands, as before.

  | runtime  | file                                 |
  |----------|--------------------------------------|
  | claude   | `~/.claude/CLAUDE.md`                |
  | codex    | `~/.codex/AGENTS.md`                 |
  | gemini   | `~/.gemini/GEMINI.md`                |

  `~` is the runtime's own HOME, which is **not** `/home/sprite` for all of
  them — gemini runs with `HOME=/tmp` (as did the removed opencode). This
  module used to expand the table above against a hardcoded `/home/sprite`,
  so for those two the
  prompt was written where their CLI never looks: they ran on the default
  persona, silently, and the test pinned the wrong path alongside. The paths
  now come from `Managoat.Runtimes.Layout`, which is also where the `HOME`
  export is derived from, so the two cannot disagree again.

  The file carries a short header so a human (or the agent) reading it knows
  where it came from, then the prompt verbatim.
  """

  alias Managoat.Runtimes.Layout

  @doc "The user-level instructions file the runtime reads, or nil for a runtime we do not know."
  @spec path(String.t() | nil) :: String.t() | nil
  def path(runtime) when is_binary(runtime), do: Layout.instructions_path(runtime)
  def path(_runtime), do: nil

  @doc """
  Write the agent's system prompt for the runtime into the sandbox. Returns
  `:ok` when written or when there was nothing to write; `{:error, reason}`
  when the sandbox refused the write (the caller logs and carries on — a
  missing persona is not a reason to fail a provision).
  """
  @spec write(Managoat.Sandbox.Handle.t(), String.t() | nil, map() | nil) ::
          :ok | {:error, term()}
  def write(_handle, _runtime, nil), do: :ok

  def write(handle, runtime, %{system: system} = agent) do
    with path when is_binary(path) <- path(runtime),
         prompt when is_binary(prompt) <- blank_to_nil(system) do
      Managoat.Sandbox.write_file(handle, path, render(agent, prompt))
    else
      _ -> :ok
    end
  end

  def write(_handle, _runtime, _agent), do: :ok

  @doc false
  def render(agent, prompt) do
    name = Map.get(agent, :name) || "agent"

    """
    <!-- Written by Managoat from the agent "#{name}" (its `system` prompt). Edit the agent in Managoat, not this file: it is rewritten when the computer is provisioned or reattached. -->

    #{String.trim_trailing(prompt)}
    """
  end

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(s) when is_binary(s) do
    if String.trim(s) == "", do: nil, else: s
  end
end
