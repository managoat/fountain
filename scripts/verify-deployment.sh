#!/usr/bin/env bash
# The push-button conformance check: point it at a Fountain deployment and it
# prints a verdict.
#
#   scripts/verify-deployment.sh https://managoat.com
#   scripts/verify-deployment.sh http://localhost:4000 probe
#
# It is a credential shim over `node deployed/verify.mjs`, which composes the
# run and owns every assertion. Keys come from the environment when they are
# already exported, and otherwise from the macOS keychain, so a routine run
# needs no secret on the command line and none is written to shell history.
# Everything else — profiles, limits, output — is documented in
# `deployed/README.md` and `node deployed/verify.mjs --help`.
#
# Provision the two accounts this needs once per deployment, as the "Provision
# test accounts" section of `deployed/README.md` describes.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
service="${FOUNTAIN_SUITE_KEYCHAIN_SERVICE:-fountain-prod-deployed-suite-key}"

usage() {
  cat <<'USAGE'
Verify a deployed Fountain.

  scripts/verify-deployment.sh <base-url> [profile] [-- <verify.mjs flags>]

  base-url   the deployment's public ingress; http:// only for loopback
  profile    probe, basic, execution, streaming (default), canary,
             secrets, mcp, webhooks, schedules

Credentials, in order of preference:
  1. FOUNTAIN_SUITE_KEY / FOUNTAIN_SUITE_OTHER_KEY already in the environment
  2. the macOS keychain, service $FOUNTAIN_SUITE_KEYCHAIN_SERVICE
     (default fountain-prod-deployed-suite-key), account = the variable name

Pass anything else through to the runner after `--`, for example:
  scripts/verify-deployment.sh https://example.test execution -- --model anthropic/claude-haiku-4-5
USAGE
}

if [[ $# -eq 0 || ${1:-} == -h || ${1:-} == --help ]]; then usage; exit 0; fi

url="$1"; shift
profile=streaming
if [[ $# -gt 0 && ${1:-} != --* ]]; then profile="$1"; shift; fi
if [[ ${1:-} == -- ]]; then shift; fi

# Read a key from the keychain only when the variable is not already set, so an
# exported key always wins and a CI-style invocation never touches the keychain.
keychain_source=""
load_key() {
  local name="$1"
  if [[ -n "${!name:-}" ]]; then return 0; fi
  if ! command -v security >/dev/null 2>&1; then return 0; fi
  local value
  if value="$(security find-generic-password -s "$service" -a "$name" -w 2>/dev/null)"; then
    export "$name=$value"
    keychain_source="$service"
  fi
}

load_key FOUNTAIN_SUITE_KEY
load_key FOUNTAIN_SUITE_OTHER_KEY

if [[ -n "$keychain_source" ]]; then
  echo "  keys       keychain: $keychain_source"
else
  echo "  keys       environment"
fi

exec node "$root/deployed/verify.mjs" "$url" --profile "$profile" "$@"
