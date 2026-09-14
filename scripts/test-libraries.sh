#!/usr/bin/env bash
#
# Runs the test suite of every umbrella app EXCEPT apps/fountain with coverage,
# and drops each export into apps/fountain/cover so the coverage job merges it
# with the partitions' exports and the 85% gate stands on the union
# (scripts/coverage-gate.exs reads that one directory).
#
# That is two kinds of app today: a library on its way out (apps/managoat_*,
# decisions/0037 — none right now, all nine graduated) and a first-party
# extension (apps/fountain_buzz, apps/fountain_support and apps/fountain_google,
# decisions/0043).
# They need the same treatment for the same reason, so the glob is "every
# sibling" rather than a list to keep updated.
#
# Why a separate script and not another partition: scripts/partition-files.sh
# and the timings manifest are written against apps/fountain and ee/, whose
# tests all belong to the :fountain app. A sibling app's tests belong to that
# app, run from its own directory, and instrument its own modules — and
# apps/fountain cannot load them at all, because it deliberately depends on
# neither. Without this they would be unmeasured and would run only when
# someone ran `mix test` at the root. CI runs this from one partition (see
# ci.yml). When a sibling's suite grows past a few seconds, give it a matrix
# entry of its own instead.
#
# Same discipline as test-partition.sh: a run that cannot prove it ran tests
# exits nonzero, and so does one that exported no coverage.
#
# Usage: scripts/test-libraries.sh

set -euo pipefail

cd "$(dirname "$0")/.."

merge_dir="apps/fountain/cover"
mkdir -p "$merge_dir"

shopt -s nullglob
apps=()
for dir in apps/*/; do
  [ "$dir" = "apps/fountain/" ] && continue
  apps+=("$dir")
done
shopt -u nullglob

# Zero siblings is a legitimate state — a core-only checkout with every library
# on hex and no extension — and the coverage job counts the same directories, so
# the merge still balances.
if [ "${#apps[@]}" -eq 0 ]; then
  echo "no sibling apps under apps/ besides fountain; nothing to run"
  exit 0
fi

for dir in "${apps[@]}"; do
  app=$(basename "$dir")
  log=$(mktemp)

  echo "== $app"
  set +e
  (cd "$dir" && mix test --cover --export-coverage "$app") 2>&1 | tee "$log"
  status=${PIPESTATUS[0]}
  set -e

  if [ "$status" -ne 0 ]; then
    rm -f "$log"
    exit "$status"
  fi

  count=$(grep -oE '[0-9]+ tests?,' "$log" | tail -1 | grep -oE '^[0-9]+' || true)
  rm -f "$log"

  if [ -z "$count" ] || [ "$count" -eq 0 ]; then
    echo "$app: no ExUnit summary line or 0 tests — the suite did not run" >&2
    exit 1
  fi

  export_file="$dir/cover/$app.coverdata"
  if [ ! -f "$export_file" ]; then
    echo "$app ran $count tests but exported no coverage (expected $export_file)" >&2
    exit 1
  fi

  cp "$export_file" "$merge_dir/lib-$app.coverdata"
  echo "$count" > "$merge_dir/lib-$app.tests"
  echo "$app: $count tests, coverage exported to $merge_dir/lib-$app.coverdata"
done
