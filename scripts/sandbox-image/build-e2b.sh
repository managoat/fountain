#!/usr/bin/env bash
# Build the reference E2B template from images/e2b/ on hosted E2B (e2b.app),
# then smoke-test it live with smoke-e2b.sh.
#
# This is the recipe for a self-hoster whose instance runs on hosted E2B. It is
# not what managoat.com runs: production's E2B endpoint is loam's E2B API
# (https://api.e2b.loam.inevitable.fyi), whose `fountain` template is built by
# loam from its own images/e2b-fountain/Containerfile
# (https://github.com/arugula-salad/loam). loam has no template build routes,
# so this script cannot target it. CI does not run this script; it only smokes
# production's template (.github/workflows/sandbox-images.yml).
#
# By hand:
#
#     E2B_API_KEY=e2b_... scripts/sandbox-image/build-e2b.sh
#
# `e2b template create <name>` is name-addressed and rebuilds in place, so the
# template ID an instance points at survives every rebuild. Sandboxes already
# running keep the copy they started from.
#
# Environment:
#   E2B_API_KEY   required, and it must be the account the instance uses — a
#                 template built under another account is invisible to its key
#   E2B_TEMPLATE  template name to rebuild (default: fountain)
#   E2B_BASE_URL  control-plane base (default: https://api.e2b.app)
#   E2B_USER      in-guest user the smoke runs as (default: sprite)
#   SKIP_SMOKE    set to 1 to build without creating a sandbox

set -euo pipefail

# Pinned: the CLI decides what "template create" means, and a silent major
# would change the artifact the instance boots from.
CLI="@e2b/cli@2.17.1"

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
template="${E2B_TEMPLATE:-fountain}"

if [ -z "${E2B_API_KEY:-}" ]; then
  echo "E2B_API_KEY is not set — cannot talk to e2b.dev" >&2
  exit 1
fi

command -v npx > /dev/null || { echo "npx is required" >&2; exit 1; }

echo "==> building E2B template ${template} from images/e2b/e2b.Dockerfile"
npx --yes "$CLI" template create "$template" \
  --path "${root}/images/e2b" \
  --dockerfile e2b.Dockerfile

if [ "${SKIP_SMOKE:-}" = "1" ]; then
  echo "==> SKIP_SMOKE=1, leaving the template unverified"
  exit 0
fi

E2B_TEMPLATE="$template" "${root}/scripts/sandbox-image/smoke-e2b.sh"
