# Rebuilds scripts/test-timings.tsv, the cost table scripts/partition-files.exs
# balances on. Reads module timing reports on stdin. Download the partition
# artifacts from one successful CI run (scripts/ci/README.md), then run:
#
#     cat /tmp/fountain-ci-timings/coverdata-*/*.timings.log \
#       | elixir scripts/regen-test-timings.exs
#
# Run it when the partitions visibly drift apart — the partition jobs print
# their predicted cost, so a manifest that has gone stale shows up there rather
# than having to be remembered. Absolute numbers do not need to match CI; only
# the ratios between files matter to the bucketing.

input = IO.read(:stdio, :eof)

# ExUnit prints the module, then its file on the next line. Paths come through
# app-relative for apps/fountain, so they are normalised back to repo-relative
# here. The guard below — every parsed path must exist on disk — is what turns
# a layout change into a loud failure here rather than a quietly shrunken
# manifest.
entries =
  Regex.scan(~r/^\s*[A-Za-z0-9_.]+ \((\d+(?:\.\d+)?)ms\)\n\s*\[([^\]]+)\]/m, input)
  |> Enum.map(fn [_, ms, path] ->
    path =
      cond do
        String.starts_with?(path, "test/") ->
          "apps/fountain/" <> path

        true ->
          path
      end

    {number, ""} = Float.parse(ms)
    {path, round(number)}
  end)
  |> Enum.reduce(%{}, fn {path, ms}, acc -> Map.update(acc, path, ms, &(&1 + ms)) end)

if map_size(entries) == 0 do
  IO.puts(:stderr, "no module timings found on stdin — was --slowest-modules passed?")
  System.halt(1)
end

missing = Enum.reject(Map.keys(entries), &File.exists?/1)

if missing != [] do
  IO.puts(:stderr, "these parsed paths do not exist, so the normalisation is wrong:")
  Enum.each(Enum.take(missing, 5), &IO.puts(:stderr, "  " <> &1))
  System.halt(1)
end

body =
  entries
  |> Enum.sort()
  |> Enum.map_join("\n", fn {path, ms} -> "#{path}\t#{ms}" end)

File.write!("scripts/test-timings.tsv", """
# Measured cost per test file, milliseconds. Regenerate with:
#   cat /tmp/fountain-ci-timings/coverdata-*/*.timings.log | elixir scripts/regen-test-timings.exs
# Consumed by scripts/partition-files.exs. A file missing from here is costed
# at the median rather than zero, so adding tests degrades balance gently
# instead of silently loading one partition.
#{body}
""")

IO.puts("wrote scripts/test-timings.tsv: #{map_size(entries)} files")
