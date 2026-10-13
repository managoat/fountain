#!/usr/bin/env bash
#
# The local gate behind `mix precommit`: CI's Elixir static job, the sobelow
# scan and a prod release assemble, in that order, as one command whose exit
# status is the verdict. The test suite is a stage too, but not a default
# one: CI runs the whole suite on every PR and again in the merge queue, so
# locally it is opt-in.
#
#   mix precommit                 every stage but the suite
#   mix precommit --full          every stage, the suite last
#   mix precommit credo test      only those stages, in the canonical order
#   mix precommit --list          the stage names and what each runs
#   scripts/precommit.sh          the same thing without the alias
#
# Every stage is its own OS process, so no stage can leave Mix state behind
# for the next one, and the script never trusts a stage's output: a non-zero
# status stops the run, the summary names the stage, and that status is the
# script's own. `mix precommit` hands it to the shell with `System.halt/1`,
# so nothing sits between the failed stage and `$?`.
#
# One thing the script cannot fix: a pipe. `mix precommit | tee log` reports
# tee's status unless the shell has `pipefail` on. Read the last line, which
# is always `precommit: PASSED` or `precommit: FAILED ...`, or set pipefail.
#
# What CI runs that this does not: hex.audit, the Go modules, the release
# BOOT (this assembles only; booting needs SECRET_KEY_BASE and a database),
# OpenAPI validation and the SDK jobs. scripts/ci/README.md lists them all.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

# ── the stages ────────────────────────────────────────────────────────────
#
# name | what it runs. Kept in one table so `--list`, the summary and the
# order can never disagree.
STAGES=(
  "toolchain|elixir and OTP match .tool-versions"
  "conflict-markers|python3 scripts/conflict-markers.py"
  "compile|MIX_ENV=test mix compile --warnings-as-errors"
  "deps|mix deps.unlock --check-unused"
  "format|mix format --check-formatted"
  "credo|MIX_ENV=test mix credo --strict"
  "dialyzer|MIX_ENV=dev mix dialyzer"
  "sobelow|scripts/sobelow.sh"
  "release|MIX_ENV=prod mix deps.get && mix release fountain_server --overwrite"
  "test|MIX_ENV=test mix test (with --full or by name; CI runs it on every plan)"
)

# Stages that run only with --full or when named. The suite is here because
# CI runs it on every PR and again in the merge queue, and a local run of
# 6,000 tests before every push at this merge rate bought little that the
# six-minute CI run did not.
OPT_IN_STAGES=(test)

stage_toolchain() {
  # The formatter, credo and dialyzer all change output between Elixir
  # releases, so a gate run on the wrong toolchain is the classic "green
  # here, red in CI". `.tool-versions` is what CI and the release image are
  # held to (toolchain_lockstep_test.exs); this checks the shell's `mix`
  # against it. Elixir exactly, OTP by major.
  local want_elixir want_otp have_elixir have_otp
  want_elixir="$(awk '$1 == "elixir" { sub(/-otp-.*/, "", $2); print $2 }' .tool-versions)"
  want_otp="$(awk '$1 == "erlang" { split($2, v, "."); print v[1] }' .tool-versions)"
  have_elixir="$(elixir --version 2>/dev/null | awk '/^Elixir / { print $2 }')"
  have_otp="$(erl -noshell -eval 'io:format("~s", [erlang:system_info(otp_release)]), halt().' 2>/dev/null)"

  if [[ "$have_elixir" == "$want_elixir" && "$have_otp" == "$want_otp" ]]; then
    echo "Elixir $have_elixir on OTP $have_otp"
    return 0
  fi

  echo "this shell runs Elixir ${have_elixir:-?} on OTP ${have_otp:-?}; .tool-versions pins $want_elixir on OTP $want_otp." >&2
  echo "Activate mise in the shell, or run \`mise exec -- mix precommit\`." >&2
  echo "PRECOMMIT_ALLOW_TOOLCHAIN_DRIFT=1 skips this check when the mismatch is deliberate." >&2
  [[ "${PRECOMMIT_ALLOW_TOOLCHAIN_DRIFT:-}" == "1" ]]
}

# `mix_in test compile ...` rather than `MIX_ENV=test mix compile ...` inline:
# the env is set per stage on purpose (three stages build three envs), and
# the linter reads `MIX_ENV=test` as an assignment of the `test` builtin.
mix_in() {
  local env="$1"
  shift
  MIX_ENV="$env" mix "$@"
}

stage_conflict_markers() { python3 scripts/conflict-markers.py; }

# MIX_ENV=test so test/support and the test-only deps compile under
# warnings-as-errors too, which is the env CI's static job uses.
stage_compile() { mix_in test compile --warnings-as-errors; }

# `--check-unused` reports lockfile entries no dependency needs and writes
# nothing, which is what CI's `deps.unlock --unused && git diff --exit-code
# mix.lock` establishes the long way round.
stage_deps() { mix_in test deps.unlock --check-unused; }

stage_format() { mix_in test format --check-formatted; }

stage_credo() { mix_in test credo --strict; }

# MIX_ENV=dev on purpose: dialyzer analyzes the shipped code, and the test
# env would drag test/support and the test-only deps into the PLT.
stage_dialyzer() { mix_in dev dialyzer; }

# Not plain `mix sobelow`: at the umbrella root sobelow finds no Phoenix app,
# scans nothing and exits 0. The script scans apps/fountain;
# sobelow_gate_test.exs checks this file names it.
stage_sobelow() { scripts/sobelow.sh; }

# The only stage that builds :prod, and so the only one that can see a
# dependency graph the dev and test builds do not have: the OpenTelemetry
# family is `only: :prod`, and a duplicate-module clash between a new
# dependency and one of those leaves every other stage green while
# `mix release` refuses to assemble (#1472, #1477). Assemble only; CI boots
# it. Plain `deps.get`, not CI's `deps.get --only prod`: `--only` prunes
# deps/ to that env and would delete credo, dialyxir, sobelow and the test
# deps out from under the stages that already ran and the one still to come.
stage_release() {
  mix_in prod deps.get && mix_in prod release fountain_server --overwrite
}

# The whole suite from the umbrella root, in one run.
# Opt-in (OPT_IN_STAGES): `--full` or `mix precommit test`.
stage_test() { mix_in test test; }

# ── the runner ────────────────────────────────────────────────────────────

# Literal membership, never a pattern: `grep -qx` read the argument as a
# regex, so `te.t` and `.*` passed validation, matched no canonical name at
# selection time and printed PASSED over zero stages.
is_stage() {
  local s
  for s in "${STAGES[@]}"; do [[ "${s%%|*}" == "$1" ]] && return 0; done
  return 1
}

selected_has() {
  local s
  for s in "${selected[@]}"; do [[ "$s" == "$1" ]] && return 0; done
  return 1
}

is_opt_in() {
  local s
  for s in "${OPT_IN_STAGES[@]}"; do [[ "$s" == "$1" ]] && return 0; done
  return 1
}

list_stages() {
  local s
  for s in "${STAGES[@]}"; do printf '  %-17s %s\n' "${s%%|*}" "${s#*|}"; done
}

usage() {
  echo "usage: scripts/precommit.sh [--list] [--full] [stage ...]"
  echo
  echo "stages, in the order they run (${OPT_IN_STAGES[*]}: only with --full or by name):"
  list_stages
}

selected=()
full=0
for arg in "$@"; do
  case "$arg" in
    --list) usage; exit 0 ;;
    --full) full=1 ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "precommit: unknown option $arg" >&2; usage >&2; exit 64 ;;
    *)
      if ! is_stage "$arg"; then
        echo "precommit: no stage named '$arg'" >&2; usage >&2; exit 64
      fi
      selected+=("$arg")
      ;;
  esac
done

# No names: every stage, minus the opt-in ones unless --full. Names win
# over --full, so `mix precommit credo test` runs exactly those two.
run_list=()
for s in "${STAGES[@]}"; do
  name="${s%%|*}"
  if [[ ${#selected[@]} -eq 0 ]]; then
    if [[ $full -eq 1 ]] || ! is_opt_in "$name"; then
      run_list+=("$name")
    fi
  elif selected_has "$name"; then
    run_list+=("$name")
  fi
done

total=${#run_list[@]}
# A verdict over zero stages is not a verdict. Unreachable once every name
# is checked literally above; kept so a future selector bug fails loudly.
if [[ $total -eq 0 ]]; then
  echo "precommit: no stages selected" >&2; usage >&2; exit 64
fi
started=$SECONDS
n=0
for name in "${run_list[@]}"; do
  n=$((n + 1))
  echo
  echo "precommit ── [$n/$total] $name"
  stage_started=$SECONDS
  "stage_${name//-/_}"
  status=$?
  took=$((SECONDS - stage_started))
  if [[ $status -ne 0 ]]; then
    echo
    echo "precommit ── [$n/$total] $name FAILED (exit $status, ${took}s)"
    if [[ $n -lt $total ]]; then
      echo "precommit ── not run: ${run_list[*]:$n}"
    fi
    echo "precommit: FAILED at $name (exit $status) after $((SECONDS - started))s"
    exit "$status"
  fi
  echo "precommit ── [$n/$total] $name ok (${took}s)"
done

echo
echo "precommit: PASSED ($total stages, $((SECONDS - started))s)"
