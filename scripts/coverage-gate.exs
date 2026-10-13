# Enforces the coverage threshold across the partitions' exports.
#
# This is `mix test.coverage` minus the part CI cannot use. That task spends
# roughly 90% of its time rendering an HTML report — 530 files and 129MB on
# this repo, ~17s of the coverage job — and nothing reads it: the job asserts a
# threshold and exits. Measured on the same six exports:
#
#     mix test.coverage    85.46%   7.4s wall / 18.7s user   (+129MB of HTML)
#     this script          85.46%   3.6s
#
# The number is identical, and that is the whole basis for using this instead.
# Two details of `:cover` have to be handled to make it so, and getting either
# wrong moves the total by percentage points rather than failing loudly:
#
#   * `:cover.analyse(mod, :coverage, :line)` returns one entry per *clause*,
#     so a line with several clauses appears several times. A line counts once,
#     and counts as covered if ANY clause on it ran. Summing the entries
#     instead reported 81.32% against the real 85.46% — under the threshold,
#     failing a build that should pass.
#   * Line 0 is module-level bookkeeping, not executable, and is dropped.
#
# It reads coverage.exs, so `:ignore_modules` and the threshold stay in the one
# place `mix test.coverage` and `mix test --cover` already read them from.
#
# Run it as `elixir scripts/coverage-gate.exs`, not through `mix run`. It reads
# .coverdata and coverage.exs and touches nothing else — no deps, no _build, no
# app modules — so mix has nothing to contribute and a great deal to do first:
# through `mix run` the step recompiled the app ("Compiling 10 files") for a
# script that never calls it, which was most of its 12s in CI.
#
# Elixir is pinned (.tool-versions), so these semantics cannot drift without a
# deliberate bump. WHEN BUMPING ELIXIR, re-run `mix test.coverage` on the same
# exports and check the totals still agree.

opts = "coverage.exs" |> Code.eval_file() |> elem(0)
ignore = Keyword.get(opts, :ignore_modules, [])
threshold = opts |> Keyword.get(:summary, []) |> Keyword.get(:threshold, 90)

# One directory holds every export: the partitions write <n>.coverdata here,
# so the gate stands on their union.
exports = Path.wildcard("apps/fountain/cover/*.coverdata")

if exports == [] do
  IO.puts(:stderr, "no .coverdata under apps/fountain/cover — nothing was merged")
  System.halt(1)
end

ignored? = fn mod ->
  name = inspect(mod)

  Enum.any?(ignore, fn
    %Regex{} = re -> Regex.match?(re, name)
    atom when is_atom(atom) -> atom == mod
    _ -> false
  end)
end

{:ok, _} = :cover.start()
for f <- exports, do: :ok = :cover.import(String.to_charlist(f))

per_module =
  :cover.imported_modules()
  |> Enum.reject(ignored?)
  |> Enum.map(fn mod ->
    {covered, total} =
      case :cover.analyse(mod, :coverage, :line) do
        {:ok, lines} ->
          lines
          |> Enum.reject(fn {{_mod, line}, _} -> line == 0 end)
          |> Enum.reduce(%{}, fn {{_mod, line}, {c, _n}}, seen ->
            Map.update(seen, line, c > 0, &(&1 or c > 0))
          end)
          |> Enum.reduce({0, 0}, fn {_line, covered?}, {c, t} ->
            {c + if(covered?, do: 1, else: 0), t + 1}
          end)

        _ ->
          {0, 0}
      end

    {mod, covered, total}
  end)

{covered, total} =
  Enum.reduce(per_module, {0, 0}, fn {_m, c, t}, {a, b} -> {a + c, b + t} end)

pct = if total > 0, do: covered * 100 / total, else: 100.0

# The table is gone with the HTML, so name the modules a failure would point at.
worst =
  per_module
  |> Enum.filter(fn {_m, _c, t} -> t > 0 end)
  |> Enum.sort_by(fn {_m, c, t} -> c / t end)
  |> Enum.take(15)

IO.puts(
  "coverage: #{Float.round(pct, 2)}% (#{covered}/#{total} lines, #{length(per_module)} modules, threshold #{threshold}%)"
)

IO.puts("merged #{length(exports)} export(s): #{Enum.map_join(exports, ", ", &Path.basename/1)}")
IO.puts("\nleast covered:")

for {mod, c, t} <- worst do
  IO.puts(
    "  #{String.pad_leading(Float.to_string(Float.round(c * 100 / t, 1)), 6)}%  #{inspect(mod)} (#{c}/#{t})"
  )
end

if pct < threshold do
  IO.puts(:stderr, "\ncoverage #{Float.round(pct, 2)}% is below the #{threshold}% threshold")
  System.halt(1)
end

IO.puts("\ncoverage gate passed")
