# The facts about an Elixir SDK release, in one place, so the PR gate and
# release tooling cannot disagree about them.
#
#   elixir scripts/elixir-sdk-release.exs state
#   elixir scripts/elixir-sdk-release.exs guard <base-ref>
#
# No dependencies: this runs before `mix deps.get`. The version is read from
# the `@version` attribute in mix.exs, so loading the Mix project is unnecessary.
defmodule ElixirSdkRelease do
  @package_dir "sdk/elixir"
  @mix "#{@package_dir}/mix.exs"
  @changelog "#{@package_dir}/CHANGELOG.md"
  @license "#{@package_dir}/LICENSE"
  @http "#{@package_dir}/lib/fountain/http.ex"
  @shipped_dirs ["#{@package_dir}/lib/", "#{@package_dir}/priv/"]
  @shipped_files [@mix, @license]

  def main(["state"]) do
    {name, version} = manifest(File.read!(@mix))

    %{
      "name" => name,
      "version" => version,
      "published" => published?(name, version),
      "tag" => "sdk-elixir-v#{version}"
    }
    |> JSON.encode!()
    |> IO.puts()
  end

  def main(["guard", base]) do
    changed = git(["diff", "--name-only", "#{base}...HEAD"]) |> String.split("\n", trim: true)
    head_source = File.read!(@mix)
    {name, head_version} = manifest(head_source)
    base_source = read_at(base, @mix)
    base_version = if base_source, do: base_source |> manifest() |> elem(1)
    bumped = head_version != base_version

    needs_release =
      Enum.filter(changed, fn path ->
        cond do
          path == @mix ->
            is_nil(base_source) or consumer_facing(head_source) != consumer_facing(base_source)

          path in @shipped_files ->
            true

          true ->
            Enum.any?(@shipped_dirs, &String.starts_with?(path, &1))
        end
      end)

    IO.puts("package:  #{name}")
    IO.puts("base:     #{base_version || "not present"}")
    IO.puts("head:     #{head_version}#{if bumped, do: "  (bumped)", else: "  (unchanged)"}")
    IO.puts("touched:  #{length(changed)} file(s) in the PR")
    if needs_release != [], do: IO.puts("shipped:  #{Enum.join(needs_release, ", ")}")

    cond do
      needs_release != [] and not bumped ->
        fail(
          "This PR changes what the Elixir SDK ships (#{Enum.join(needs_release, ", ")}) " <>
            "but leaves @version at #{head_version}. Nothing publishes without a bump. " <>
            "Bump @version in #{@mix} and add a \"## [<version>]\" heading to " <>
            "#{@changelog}. To change the published surface without releasing, add the " <>
            "\"release:skip-sdk\" label."
        )

      not bumped ->
        IO.puts("\nNo Elixir SDK release needed for this PR.")

      true ->
        problems =
          [
            published?(name, head_version) &&
              "#{name} #{head_version} already exists on Hex, which does not allow a " <>
                "version to be republished. Bump to something new.",
            not (File.read!(@changelog) =~ "## [#{head_version}]") &&
              "#{@changelog} has no \"## [#{head_version}]\" heading.",
            not user_agent_matches?(head_version) &&
              "The User-Agent in #{@http} does not say #{head_version}. Keep it in sync " <>
                "with @version."
          ]
          |> Enum.filter(&is_binary/1)

        case problems do
          [] -> IO.puts("\n#{name} #{head_version} is ready to publish.")
          _ -> Enum.each(problems, &fail/1)
        end
    end

    if Process.get(:failed), do: System.halt(1)
  end

  def main(_) do
    IO.puts(:stderr, "usage: elixir scripts/elixir-sdk-release.exs state | guard <base-ref>")
    System.halt(2)
  end

  defp manifest(source) do
    with [_, name] <- Regex.run(~r/^\s*app:\s*:(\w+)/m, source),
         [_, version] <- Regex.run(~r/^\s*@version\s+"([^"]+)"/m, source) do
      {name, version}
    else
      _ -> raise "could not read app: and @version from #{@mix}"
    end
  end

  # mix.exs ships, but comments, blank lines, and dev/test-only dependencies
  # do not affect a consumer. Compare the projection that reaches Hex.
  defp consumer_facing(source) do
    source
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
    |> Enum.reject(&(&1 =~ ~r/only:\s*(:dev|:test|\[\s*:(dev|test)\s*,\s*:(dev|test)\s*\])/))
  end

  defp user_agent_matches?(version) do
    File.read!(@http) =~ ~s(@user_agent "fountain-sdk-elixir/#{version}")
  end

  defp published?(name, version) do
    url = "https://hex.pm/api/packages/#{name}/releases/#{version}"

    case System.cmd("curl", ["-sS", "-o", "/dev/null", "-w", "%{http_code}", url],
           stderr_to_stdout: true
         ) do
      {"200", 0} -> true
      {"404", 0} -> false
      {status, 0} -> raise "hex.pm answered #{status} for #{name} #{version}"
      {error, exit_status} -> raise "hex.pm request failed (curl #{exit_status}): #{error}"
    end
  end

  defp read_at(ref, path) do
    case System.cmd("git", ["show", "#{ref}:#{path}"], stderr_to_stdout: true) do
      {source, 0} -> source
      {_, _} -> nil
    end
  end

  defp git(args) do
    case System.cmd("git", args, stderr_to_stdout: true) do
      {out, 0} -> out
      {out, status} -> raise "git #{Enum.join(args, " ")} exited #{status}: #{out}"
    end
  end

  defp fail(message) do
    IO.puts(:stderr, "::error::#{message}")
    Process.put(:failed, true)
  end
end

ElixirSdkRelease.main(System.argv())
