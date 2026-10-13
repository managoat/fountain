#!/usr/bin/env bash
# Rebuild the E2B template from images/e2b/, then smoke-test it live.
#
# Runs in CI (.github/workflows/sandbox-images.yml) and by hand:
#
#     E2B_API_KEY=... scripts/sandbox-image/build-e2b.sh
#
# `e2b template create <name>` is name-addressed and rebuilds in place, so the
# template ID prod is pinned to (px8ej9g93zg6b8q9w01j, alias `fountain`)
# survives every rebuild. Sandboxes already running keep the copy they started
# from. There is no in-between state to protect, which is why this script is so
# much shorter than its Daytona counterpart.
#
# Environment:
#   E2B_API_KEY   required, and it must be the account prod uses — a template
#                 built under another org is invisible to prod's key
#   E2B_TEMPLATE  template name to rebuild (default: fountain)
#   E2B_BASE_URL  control-plane base (default: https://api.e2b.app)
#   E2B_USER      in-guest user the smoke runs as (default: sprite)
#   SKIP_SMOKE    set to 1 to build without creating a sandbox

set -euo pipefail

# Pinned: the CLI decides what "template create" means, and a silent major
# would change the artifact prod boots from.
CLI="@e2b/cli@2.17.1"

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
template="${E2B_TEMPLATE:-fountain}"
base_url="${E2B_BASE_URL:-https://api.e2b.app}"
user="${E2B_USER:-sprite}"

if [ -z "${E2B_API_KEY:-}" ]; then
  echo "E2B_API_KEY is not set — cannot talk to e2b.dev" >&2
  exit 1
fi

for tool in jq npx; do
  command -v "$tool" > /dev/null || { echo "${tool} is required" >&2; exit 1; }
done

echo "==> building E2B template ${template} from images/e2b/e2b.Dockerfile"
npx --yes "$CLI" template create "$template" \
  --path "${root}/images/e2b" \
  --dockerfile e2b.Dockerfile

if [ "${SKIP_SMOKE:-}" = "1" ]; then
  echo "==> SKIP_SMOKE=1, leaving the template unverified"
  exit 0
fi

sandbox_id=""

cleanup() {
  if [ -n "$sandbox_id" ]; then
    echo "==> destroying smoke sandbox ${sandbox_id}"
    curl -sS -X DELETE -H "X-API-Key: ${E2B_API_KEY}" \
      "${base_url}/sandboxes/${sandbox_id}" > /dev/null || true
  fi
}
trap cleanup EXIT

echo "==> creating a smoke sandbox from ${template}"
# No `fountain: "1"` metadata, deliberately: that is the label the reaper and
# the ops gauges count as a Fountain sandbox, and a CI sandbox is neither
# leaked nor theirs to reason about. The short timeout is the backstop for a
# smoke that dies before its trap runs.
create_body="$(jq -nc --arg t "$template" \
  '{templateID: $t, timeout: 600, metadata: {fountain_image_smoke: "1"}}')"

create_out="$(curl -sS -X POST \
  -H "X-API-Key: ${E2B_API_KEY}" \
  -H "Content-Type: application/json" \
  -d "$create_body" \
  "${base_url}/sandboxes")"

sandbox_id="$(jq -r '.sandboxID // .sandboxId // empty' <<< "$create_out")"

if [ -z "$sandbox_id" ]; then
  echo "no sandbox ID in the create response: ${create_out}" >&2
  exit 1
fi

echo "==> smoking ${sandbox_id} as ${user}"
smoke_b64="$(base64 < "${root}/scripts/sandbox-image/smoke.sh" | tr -d '\n')"
# The asserted user is E2B's own contract: envd selects the in-guest user from
# Basic auth, so E2B_USER and the template's user have to agree or every
# provisioning write lands in the wrong home.
in_guest="export SMOKE_EXPECT_USER=${user}; echo ${smoke_b64} | base64 -d | bash"

# envd accepts the connection before it is ready to run anything, and PR #693
# is the record of what that race costs. Retry the first exec only.
#
# `--` ends the CLI's own options; without it `-lc` is parsed as one and every
# attempt fails with "unknown option '-lc'" (#2481's first real run). stdin is
# closed because the CLI forwards a non-TTY stdin to the command and waits for
# its EOF.
attempt=1
output=""
while :; do
  if output="$(npx --yes "$CLI" sandbox exec --user "$user" "$sandbox_id" -- bash -lc "$in_guest" < /dev/null 2>&1)"; then
    break
  fi
  if [ "$attempt" -ge 6 ]; then
    break
  fi
  echo "    exec attempt ${attempt} failed, retrying in 5s"
  attempt=$((attempt + 1))
  sleep 5
done

echo "$output"

if ! grep -q FOUNTAIN_IMAGE_SMOKE_OK <<< "$output"; then
  echo "==> smoke FAILED for template ${template}" >&2
  exit 1
fi

echo "==> template ${template} rebuilt and smoked clean"
