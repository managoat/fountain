#!/usr/bin/env bash
# The push-button conformance check: point it at a Fountain deployment and it
# prints a verdict.
#
#   scripts/verify-deployment.sh https://fountain.example.com
#   scripts/verify-deployment.sh http://localhost:4000 probe
#
# It is ergonomics over `node deployed/verify.mjs`, which owns the run: the
# target rules, credential resolution and every assertion. Keys come from
# FOUNTAIN_SUITE_KEY and FOUNTAIN_SUITE_OTHER_KEY, and on macOS a key that is
# not exported is read from the keychain under an account naming the exact
# target, so a key stored for one deployment is never sent to another.
#
# Provision the two accounts once per deployment, as the "Provision test
# accounts" section of `deployed/README.md` describes. It also gives the
# `security add-generic-password` line that stores a key for a target.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  cat <<'USAGE'
Verify a deployed Fountain.

  scripts/verify-deployment.sh <base-url> [profile] [-- <verify.mjs flags>]

  base-url   the deployment's origin; http:// only for loopback
  profile    probe, basic, execution, streaming (default), canary

The secrets, mcp, webhooks and schedules profiles need configuration no flag
supplies. Write a target file and run deployed/cli.mjs for those.

Run `node deployed/verify.mjs --help` for the full flag list.
USAGE
}

if [[ $# -eq 0 || ${1:-} == -h || ${1:-} == --help ]]; then usage; exit 0; fi

url="$1"; shift
profile=streaming
if [[ $# -gt 0 && ${1:-} != --* ]]; then profile="$1"; shift; fi
if [[ ${1:-} == -- ]]; then shift; fi

exec node "$root/deployed/verify.mjs" "$url" --profile "$profile" "$@"
