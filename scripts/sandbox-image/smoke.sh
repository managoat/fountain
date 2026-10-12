#!/usr/bin/env bash
# Asserts the base-image shape Fountain's provisioning pipeline assumes.
#
# This runs INSIDE a sandbox (or inside the image under `docker run`), never on
# the CI runner. Every caller ships it the same way — base64 on one command
# line — so the E2B template and a local `docker build` are held to the
# identical contract.
#
# Every check stands for a provisioning step that fails in a way that is hard
# to read from the outside. The npm one is the #691 trap: a global install as
# `sprite` against the root-owned default prefix exits 243 with no output, and
# the conversation only reports that the runtime is missing. It is checked by
# doing the install, not by reading the setting, because the setting was right
# in the image that failed.
#
# SMOKE_EXPECT_USER asserts which user the provider selected in-guest, and is
# set only where Fountain pins that: E2B, where envd picks the user from Basic
# auth and E2B_USER must match what the template creates. Elsewhere the value
# is reported rather than asserted.
#
# The exit code and the trailing marker both carry the verdict: a provider exec
# API that swallows the exit code still cannot fake the marker.

set -uo pipefail

failures=0

pass() { printf 'ok    %s\n' "$1"; }

fail() {
  printf 'FAIL  %s\n' "$1"
  if [ -n "${2:-}" ]; then printf '      %s\n' "$2"; fi
  failures=$((failures + 1))
}

# Run a command, capture combined output, report on the exit code.
check() {
  local label="$1"
  shift
  local out status
  out="$(timeout 180 "$@" 2>&1)"
  status=$?
  if [ "$status" -eq 0 ]; then
    pass "$label${out:+ (${out%%$'\n'*})}"
  else
    fail "$label" "exit ${status}: ${out:-no output}"
  fi
}

echo "== identity"
whoami="$(whoami 2>&1)"
echo "      user=${whoami} home=${HOME:-unset} pwd=$(pwd)"

if [ -n "${SMOKE_EXPECT_USER:-}" ]; then
  if [ "$whoami" = "$SMOKE_EXPECT_USER" ]; then
    pass "runs as ${SMOKE_EXPECT_USER}"
  else
    fail "runs as ${SMOKE_EXPECT_USER}" "got ${whoami}"
  fi
fi

if [ -w "${HOME:-/nonexistent}" ]; then
  pass "HOME is writable"
else
  fail "HOME is writable" "${HOME:-unset} is not writable by ${whoami}"
fi

echo
echo "== base tooling"
check "bash" bash --version
check "git" git --version
check "node" node --version
check "npm" npm --version

echo
echo "== a global npm install as the exec user (#691)"
prefix="$(npm config get prefix 2>&1)"
echo "      npm prefix=${prefix}"

# The measurement, not the setting. `--silent` is what hid the EACCES last
# time, so it stays in, and Managoat.Runtimes.ACP installs with it.
if npm_out="$(timeout 300 npm install -g --no-progress --silent semver 2>&1)"; then
  if [ -x "${prefix}/bin/semver" ]; then
    pass "npm install -g"
  else
    fail "npm install -g" "exit 0, but no ${prefix}/bin/semver"
  fi
else
  fail "npm install -g" "exit $?: ${npm_out:-no output — the 243 signature}"
fi

echo
echo "== agent CLIs"
# claude, codex and gemini are root-installed into the system prefix, so they
# answer on any PATH.
check "claude" claude --version
check "codex" codex --version
check "gemini" gemini --version
check "bun" /home/sprite/.bun/bin/bun --version

echo
if [ "$failures" -eq 0 ]; then
  echo "FOUNTAIN_IMAGE_SMOKE_OK"
  exit 0
fi

echo "FOUNTAIN_IMAGE_SMOKE_FAILED ${failures}"
exit 1
