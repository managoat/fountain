# Resolve a pinned ACP adapter's dependency tree into the manifest
# `Managoat.Runtimes.ACP.install/3` installs from, without npm on the sandbox.
#
#     elixir scripts/acp-lock.exs @agentclientprotocol/claude-agent-acp 0.81.2
#
# Writes apps/fountain/priv/runtimes/acp/<name>@<version>.tsv, one package per
# line:
#
#     <path under the install dir>\t<tarball url>\t<sha512 integrity>\t<os>\t<cpu>\t<libc>
#
# `-` marks a field npm left empty. Platform packages (the optional ones npm
# picks by os/cpu/libc) are all listed; the installer keeps the ones matching
# the sandbox, as npm would. Needs npm and network on the machine running it,
# and nothing else: the resolution is npm's own (`--package-lock-only`).
#
# Run it whenever `@adapters` (apps/fountain/lib/managoat/runtimes/acp.ex)
# pins a new version. The file name carries the version, so a pin without its
# manifest fails to compile.

[package, version] =
  case System.argv() do
    [p, v] -> [p, v]
    _ -> raise "usage: elixir scripts/acp-lock.exs <package> <version>"
  end

tmp = Path.join(System.tmp_dir!(), "acp-lock-#{System.unique_integer([:positive])}")
File.mkdir_p!(tmp)

try do
  File.write!(Path.join(tmp, "package.json"), ~s({"name":"acp-lock","version":"0.0.0"}))

  npm_args = [
    "install",
    "--package-lock-only",
    "--no-audit",
    "--no-fund",
    "#{package}@#{version}"
  ]

  case System.cmd("npm", npm_args, cd: tmp, stderr_to_stdout: true) do
    {_, 0} -> :ok
    {out, code} -> raise "npm exited #{code}:\n#{out}"
  end

  lock = Path.join(tmp, "package-lock.json") |> File.read!() |> JSON.decode!()

  rows =
    for {path, entry} <- lock["packages"], path != "" do
      for key <- ~w(resolved integrity), is_nil(entry[key]) do
        raise "#{path} has no #{key}: an install script or link, not a registry tarball"
      end

      if entry["hasInstallScript"],
        do: raise("#{path} has an install script, which the manifest installer does not run")

      # npm's lockfile records a platform package's os and cpu but not its
      # libc, so glibc and musl builds look alike there. The registry has it.
      entry =
        if entry["os"] || entry["cpu"] do
          name = path |> String.split("node_modules/") |> List.last()

          case System.cmd("npm", ["view", "#{name}@#{entry["version"]}", "libc", "--json"],
                 stderr_to_stdout: true
               ) do
            {"", 0} -> entry
            {json, 0} -> Map.put(entry, "libc", json |> JSON.decode!() |> List.wrap())
            {out, code} -> raise "npm view #{name} exited #{code}:\n#{out}"
          end
        else
          entry
        end

      field = fn key ->
        Enum.join(entry[key] || [], ",") |> then(&if(&1 == "", do: "-", else: &1))
      end

      Enum.join(
        [
          path,
          entry["resolved"],
          entry["integrity"],
          field.("os"),
          field.("cpu"),
          field.("libc")
        ],
        "\t"
      )
    end
    |> Enum.sort()

  root = "node_modules/#{package}"

  unless Enum.any?(rows, &String.starts_with?(&1, root <> "\t")),
    do: raise("#{root} missing from the lock")

  name = package |> String.split("/") |> List.last()

  dest =
    Path.join([__DIR__, "..", "apps", "fountain", "priv", "runtimes", "acp", "#{name}@#{version}.tsv"])
    |> Path.expand()

  File.mkdir_p!(Path.dirname(dest))
  File.write!(dest, Enum.join(rows, "\n") <> "\n")
  IO.puts("#{dest}: #{length(rows)} packages")
after
  File.rm_rf!(tmp)
end
