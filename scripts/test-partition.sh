#!/usr/bin/env bash
#
# Runs one partition of the test suite with coverage export, and refuses to
# exit 0 unless it can prove the partition actually ran tests.
#
# The proof is the point. `mix test --partition 3` — singular, the flag is
# `--partitions` — prints usage and exits 0 having run nothing, which in CI is
# a green check over a suite that never ran. That is the same shape as #612,
# where the format gate passed for the life of the repo while checking none of
# apps/. Partitioning multiplies the ways to land there: a wrong
# MIX_TEST_PARTITION, a matrix and a `--partitions` count that disagree, a
# filter that empties one partition. So this parses ExUnit's own summary line
# and fails if it is missing or reports zero.
#
# Usage: MIX_TEST_PARTITION=<n> scripts/test-partition.sh <total-partitions>

set -euo pipefail

cd "$(dirname "$0")/.."

partitions="${1:?usage: MIX_TEST_PARTITION=<n> scripts/test-partition.sh <total-partitions>}"
partition="${MIX_TEST_PARTITION:?MIX_TEST_PARTITION must be set}"

# `mix test --partitions` writes the export here, named for the partition, and
# `mix test.coverage` merges every *.coverdata it finds under the umbrella's
# children. The count file lands beside it: the merge job sums the counts so a
# human reading the log sees how many tests the gate actually stood on.
cover_dir="apps/fountain/cover"  # repo-relative; the mix run below cds into apps/fountain
coverdata="$cover_dir/$partition.coverdata"
counts="$cover_dir/$partition.tests"

log=$(mktemp)
trap 'rm -f "$log"' EXIT

# Explicit file list rather than `mix test --partitions`. That flag deals files
# out by their index in the sorted list, so a partition's runtime is arbitrary:
# six partitions of this suite ranged 24.5s to 66.5s, and adding one test file
# reshuffled every one of them. scripts/partition-files.exs assigns by measured
# cost instead, weighting a sync module at its full duration and an async one
# at duration/max_cases, because ExUnit runs the async ones in parallel and the
# sync ones strictly one at a time.
files=$(elixir scripts/partition-files.exs "$partition" "$partitions")

if [ -z "$files" ]; then
  echo "partition $partition/$partitions was assigned no files" >&2
  exit 1
fi

file_count=$(printf '%s\n' "$files" | wc -l | tr -d ' ')
echo "partition $partition/$partitions: $file_count files"

# `mix test` must run from apps/fountain, not the umbrella root. That app's
# test_paths are ["test", "../../ee/test"], and an explicit path is resolved
# against the working directory — from the root, `../../ee/...` points outside
# the repo and `ee/...` matches nothing, which CLAUDE.md already warns about.
cd apps/fountain

# Every path is checked before mix sees it, because `mix test` reports
# "did not match any directory/file" ONLY when NONE of its paths match: an
# unresolvable path alongside resolvable ones is dropped in silence, exit 0.
# That is how the first version of this ran green while skipping all 22 ee
# files — 300 tests, and the 0-tests guard below could not see it because the
# core files still ran. A path that does not exist is a failure here.
missing=""
while IFS= read -r f; do
  [ -f "$f" ] || missing="$missing $f"
done <<EOF
$files
EOF

if [ -n "$missing" ]; then
  echo "partition $partition/$partitions: these paths do not exist relative to apps/fountain," >&2
  echo "  and mix would have skipped them without failing:" >&2
  for f in $missing; do echo "    $f" >&2; done
  exit 1
fi

# The umbrella compile updates _build/test/consolidated, but a child run can
# load its own older lib/fountain/consolidated from the restored build cache.
# Its protocol table may omit newly compiled implementations (including
# credential Inspect redaction). Removing this generated table makes the
# child compile rebuild it from the current implementations before tests load.
#
# A typo in this path would remove nothing, exit 0, and put the bug back
# silently -- the same shape as every other trap this file exists to catch.
# So assert the build is where we think it is whenever there is one at all;
# a cold checkout has no _build yet and nothing that can be stale.
app_build=../../_build/test/lib/fountain

if [ -d ../../_build/test/lib ] && [ ! -d "$app_build" ]; then
  echo "expected the fountain build at $app_build, relative to apps/fountain." >&2
  echo "  the path has moved; the stale protocol table would not be removed." >&2
  exit 1
fi

rm -rf "$app_build/consolidated"

set +e
# shellcheck disable=SC2086 # word splitting is how the file list is passed
elixir -r ../../scripts/ci/timing-formatter.exs -S mix test \
  --formatter ExUnit.CLIFormatter --formatter Fountain.CI.TimingFormatter \
  --max-cases 8 --export-coverage "$partition" --cover $files 2>&1 | tee "$log"
status=${PIPESTATUS[0]}
set -e
mkdir -p cover
cp "$log" "cover/$partition.timings.log"

if [ "$status" -ne 0 ]; then
  exit "$status"
fi

# ExUnit's summary line, e.g. "5 doctests, 3 properties, 837 tests, 0 failures".
# Anchored on the trailing comma so "0 failures" cannot be read as the count.
count=$(grep -oE '[0-9]+ tests?,' "$log" | tail -1 | grep -oE '^[0-9]+' || true)

if [ -z "$count" ]; then
  echo "partition $partition/$partitions: no ExUnit summary line in the output —" >&2
  echo "  the suite did not run, whatever the exit status said." >&2
  exit 1
fi

if [ "$count" -eq 0 ]; then
  echo "partition $partition/$partitions ran 0 tests" >&2
  exit 1
fi

cd - > /dev/null

if [ ! -f "$coverdata" ]; then
  echo "partition $partition/$partitions ran $count tests but exported no coverage" >&2
  echo "  (expected $coverdata — without it the merged gate would silently" >&2
  echo "  measure a fraction of the suite and still report a number)." >&2
  exit 1
fi

echo "$count" >"$counts"
echo "partition $partition/$partitions: $count tests, coverage exported to $coverdata"
