#!/usr/bin/env bash
# Smoke-test an E2B template live: create one sandbox from it, run smoke.sh
# inside as the exec user (the image's shape and claude, codex and gemini
# --version), destroy the sandbox.
#
# Runs in CI against production's endpoint (.github/workflows/sandbox-images.yml)
# and from build-e2b.sh after a build. By hand:
#
#     E2B_API_KEY=... E2B_BASE_URL=https://api.e2b.loam.inevitable.fyi \
#       scripts/sandbox-image/smoke-e2b.sh
#
# It builds nothing. Any E2B-compatible control plane works: hosted e2b.app, or
# loam's E2B API, which is what production runs on and which has no template
# build routes (loam builds its templates from its own repository).
#
# Environment:
#   E2B_API_KEY   required: a key of the account or project that sees the template
#   E2B_TEMPLATE  template to smoke (default: fountain)
#   E2B_BASE_URL  control-plane base, https://api.<domain> (default: https://api.e2b.app)
#   E2B_USER      in-guest user the smoke runs as (default: sprite)

set -euo pipefail

# Pinned: the SDK is how the smoke reaches the control plane and envd.
SDK="e2b==2.56.0"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
base_url="${E2B_BASE_URL:-https://api.e2b.app}"

if [ -z "${E2B_API_KEY:-}" ]; then
  echo "E2B_API_KEY is not set" >&2
  exit 1
fi

command -v python3 > /dev/null || { echo "python3 is required" >&2; exit 1; }

# The SDK addresses the control plane and each sandbox's envd from one domain:
# api.<domain> and <port>-<sandbox id>.<domain>.
host="${base_url#https://}"
host="${host%%/*}"
case "$host" in
  api.*) E2B_DOMAIN="${host#api.}" ;;
  *) echo "E2B_BASE_URL must be https://api.<domain>, got ${base_url}" >&2; exit 1 ;;
esac

venv="$(mktemp -d)"
trap 'rm -rf "$venv"' EXIT
python3 -m venv "$venv"
"$venv/bin/pip" install --quiet --disable-pip-version-check "$SDK"

E2B_DOMAIN="$E2B_DOMAIN" \
E2B_TEMPLATE="${E2B_TEMPLATE:-fountain}" \
E2B_USER="${E2B_USER:-sprite}" \
  "$venv/bin/python" -I "${here}/smoke_e2b.py" "${here}/smoke.sh"
