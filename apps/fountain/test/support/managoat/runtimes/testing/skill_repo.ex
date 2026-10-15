defmodule Managoat.Runtimes.Testing.SkillRepo do
  @moduledoc """
  Local git repositories standing in for GitHub in the skills tests.

  `create!/3` makes `<base>/<owner>/<repo>.git`, and `env/1` is the
  environment that sends git's `https://github.com/` there, so the real
  fetch script runs against it unchanged. `exec/2` runs a sandbox exec
  locally with that environment.
  """

  @doc "A repository at `<base>/<repo>.git` holding `files` (path => contents). Returns its commit sha."
  @spec create!(String.t(), String.t(), %{String.t() => String.t()}) :: String.t()
  def create!(base, repo, files) do
    dir = Path.join(base, repo <> ".git")
    File.mkdir_p!(dir)
    git!(dir, ["init", "-q", "-b", "main"])
    git!(dir, ["config", "uploadpack.allowAnySHA1InWant", "true"])
    commit!(base, repo, files)
  end

  @doc "Replace the repository's files with `files` and commit. Returns the new sha."
  @spec commit!(String.t(), String.t(), %{String.t() => String.t()}) :: String.t()
  def commit!(base, repo, files) do
    dir = Path.join(base, repo <> ".git")

    for entry <- File.ls!(dir), entry != ".git", do: File.rm_rf!(Path.join(dir, entry))

    for {path, contents} <- files do
      File.mkdir_p!(Path.dirname(Path.join(dir, path)))
      File.write!(Path.join(dir, path), contents)
    end

    git!(dir, ["add", "-A"])
    git!(dir, ["-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-q", "-m", "c"])
    dir |> git!(["rev-parse", "HEAD"]) |> String.trim()
  end

  @doc "Tag the repository's current commit."
  @spec tag!(String.t(), String.t(), String.t()) :: :ok
  def tag!(base, repo, tag) do
    git!(Path.join(base, repo <> ".git"), ["tag", tag])
    :ok
  end

  @doc "The environment that makes git fetch `https://github.com/<repo>.git` from `base`."
  @spec env(String.t()) :: [{String.t(), String.t()}]
  def env(base) do
    [
      {"GIT_CONFIG_COUNT", "2"},
      {"GIT_CONFIG_KEY_0", "url.file://#{base}/.insteadOf"},
      {"GIT_CONFIG_VALUE_0", "https://github.com/"},
      {"GIT_CONFIG_KEY_1", "protocol.file.allow"},
      {"GIT_CONFIG_VALUE_1", "always"}
    ]
  end

  @doc "A SKILL.md with the given frontmatter name."
  @spec skill_md(String.t(), String.t()) :: String.t()
  def skill_md(name, body \\ "Body"),
    do: "---\nname: #{name}\ndescription: The #{name} skill.\n---\n#{body}\n"

  @doc "Run a `Managoat.Sandbox.exec/4` bash call on this machine, with its env."
  @spec exec([String.t()], keyword()) :: {:ok, String.t(), non_neg_integer()}
  def exec(args, opts) do
    {output, code} =
      System.cmd("bash", args, env: Keyword.get(opts, :env) || [], stderr_to_stdout: true)

    {:ok, output, code}
  end

  defp git!(dir, args) do
    {out, 0} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)
    out
  end
end
