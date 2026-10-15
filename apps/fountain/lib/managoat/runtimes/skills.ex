defmodule Managoat.Runtimes.Skills do
  @moduledoc """
  Materialize an agent's skills onto its sandbox at provision time.

  Each entry in `skills` is one of:

    * `%{"name" => name, "content" => skill_md}` — inline. Written
      directly to `<runtime.skills_root>/<name>/SKILL.md`.
    * `%{"source" => "owner/repo", "ref" => optional, "name" => optional}` —
      github. Installed via the [skills.sh](https://skills.sh) CLI on the
      sandbox: `npx -y skills@latest add <source>[@<ref>] --global --agent
      <runtime-agent> --yes [--skill <name>]`. A `ref` (tag, branch, or sha)
      pins the install; without one the repo's default branch is used at
      spawn time. Each runtime declares its own `skills_sh_agent` so the
      CLI writes to the right on-disk layout.

  Atom keys are accepted too and normalised to strings. The list is the
  host's to assemble: Fountain prepends the skills every sandbox gets (its
  own API skill, the team set-up skill) before the agent's own, and this
  module writes them in the order given.

  This must run before any network policy locks the sandbox down: github
  installs hit npm + GitHub. Inside `install/3` the github installs run
  before the inline writes — a blocking exec waits until the sandbox is
  fully ready, which is the readiness gate the file-write endpoints
  silently need too.
  """

  require Logger

  alias Managoat.Runtimes
  alias Managoat.Sandbox

  @typedoc """
  One skill: inline (`name` + `content`) or github (`source`, optional `ref`
  and `name`). String or atom keys.
  """
  @type skill :: %{optional(String.t() | atom()) => String.t() | nil}

  @doc """
  Install `skills` (a list of inline/github maps) on the sandbox behind
  `handle` for the runtime named in `opts`.

  Options:

    * `:runtime` (required) — the runtime string (`"claude"`, resolved
      through `Managoat.Runtimes.for_runtime/1`) or a module implementing the
      `Managoat.Runtimes` behaviour.

  Returns `:ok`, or `{:error, message}` for a runtime string the dispatcher
  does not know. A skill that fails to land is logged and skipped rather
  than failing the provision: a missing skill is a degraded agent, not a
  broken one.
  """
  @spec install(Sandbox.Handle.t(), [skill()], keyword()) :: :ok | {:error, String.t()}
  def install(handle, skills, opts) when is_list(skills) and is_list(opts) do
    case Keyword.fetch!(opts, :runtime) do
      runtime when is_binary(runtime) ->
        case Runtimes.for_runtime(runtime) do
          {:ok, mod} -> install_for(handle, mod, skills)
          {:error, _} = err -> err
        end

      mod when is_atom(mod) ->
        install_for(handle, mod, skills)
    end
  end

  defp install_for(handle, runtime_module, skills) do
    skills_root = runtime_module.skills_root()
    sh_agent = runtime_module.skills_sh_agent()

    {inline, github} =
      skills
      |> normalize()
      |> Enum.split_with(fn s -> is_binary(s["content"]) end)

    # Github installs first, inline writes second: a blocking exec waits for
    # the sandbox to be running, so by the time we touch the file-write
    # endpoints they're definitely up. (Not strictly required after the
    # SDK URL fix, but cheap defense against future readiness regressions.)
    install_github_skills(handle, sh_agent, github)
    write_inline_skills(handle, skills_root, inline)
    :ok
  end

  defp normalize(skills) do
    Enum.map(skills, fn entry ->
      Map.new(entry, fn
        {k, v} when is_atom(k) -> {Atom.to_string(k), v}
        {k, v} -> {k, v}
      end)
    end)
  end

  defp write_inline_skills(_handle, _root, []), do: :ok

  defp write_inline_skills(handle, root, inline) do
    Enum.each(inline, fn %{"name" => name, "content" => content} ->
      # write_file/4 creates the `<root>/<name>` directory atomically with
      # the file write, so we don't need a separate mkdir round-trip (each
      # one was another opportunity for the same readiness race).
      path = Path.join([root, name, "SKILL.md"])

      case Sandbox.write_file(handle, path, content) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning("inline skill write failed for #{name} at #{path}: #{inspect(reason)}")
      end
    end)
  end

  defp install_github_skills(_handle, _agent_id, []), do: :ok

  defp install_github_skills(handle, agent_id, github) do
    safe_agent = safe_token!(agent_id)

    Enum.each(github, fn entry ->
      cmd = github_install_cmd(entry, safe_agent)

      case Sandbox.exec(handle, "bash", ["-lc", cmd],
             stderr_to_stdout: true,
             timeout: 120_000
           ) do
        {:ok, _output, 0} ->
          :ok

        {:ok, output, code} ->
          Logger.warning(
            "skills.sh install failed (#{code}) for #{inspect(entry)}: #{String.slice(output, 0, 500)}"
          )

        {:error, reason} ->
          Logger.warning("skills.sh install failed for #{inspect(entry)}: #{inspect(reason)}")
      end
    end)
  end

  # Build the skills.sh install command for one github entry. `@ref` pins
  # the fetch to a tag/branch/sha (skills.sh resolves `owner/repo@ref`).
  # Every interpolated value passes the safe_token! allow-list separately —
  # `@` itself is never accepted inside a token.
  @doc false
  def github_install_cmd(entry, safe_agent) do
    source = safe_token!(entry["source"])

    pinned =
      case entry["ref"] do
        nil -> source
        "" -> source
        ref -> source <> "@" <> safe_token!(ref)
      end

    "npx -y skills@latest add #{pinned} --global --agent #{safe_agent} --yes" <>
      case entry["name"] do
        nil -> ""
        "" -> ""
        name -> " --skill #{safe_token!(name)}"
      end
  end

  # Allow-list quoting guard for values interpolated into `bash -lc`.
  # Permits `[A-Za-z0-9._/-]` which is the full set needed for owner/repo
  # identifiers, skill names, and the short `--agent` strings the runtimes
  # declare. Anything else raises rather than silently passing through —
  # we never want a `;` or `$` smuggled into a shelled-out command. A host
  # that validates a skill ref at write time mirrors this expression.
  @doc false
  def safe_token!(value) when is_binary(value) do
    if Regex.match?(~r{\A[A-Za-z0-9._/-]+\z}, value) do
      value
    else
      raise ArgumentError, "unsafe skill token (rejected by allow-list): #{inspect(value)}"
    end
  end
end
