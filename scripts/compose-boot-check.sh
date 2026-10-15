#!/usr/bin/env bash
# Runs the documented self-host quick start verbatim against the image the
# tree pins, then asks the app what the walkthrough asks and what the
# retirement in ADR 0057 promises. Two workflows run it, and it is one script
# so they cannot drift:
#
# Note which version the answers describe. The pin is the *last release*, so
# on a PR and on main this asks about the release a new user would pull, and
# only on the tag does it ask about the tree being released. An assertion
# here is therefore a statement about shipped behaviour, and may not be added
# before the release that makes it true: the retired-dialect checks below
# could not land until v0.18.0's pin did, because v0.17.1 still served all
# five paths.
#
#   ci.yml       "Compose boots the pinned image" on every PR and main push,
#                skipped when the pinned tag has no image yet (a release
#                bump PR, and main right after it merges).
#   release.yml  the same check on the tag, after image-manifest has
#                published the image the bump pins, before the GitHub
#                Release is created.
#
# The exact commands the quick start documents (cp, the two openssl lines,
# up) rather than a synthetic env: the check exists to run what a fresh user
# runs, so any divergence here would defeat it. The two appended keys are
# the only definition of each: the example file ships them commented out, so
# a followed quick start no longer leaves two copies of every secret in .env,
# shadowing each other and relying on last-value-wins (#1215).
set -euo pipefail

# Default: the compose app this script boots. Overridable so the assertions
# below can be pointed at an already-running server (a deployment, or a
# release candidate) without a second copy of them.
APP="${APP:-http://127.0.0.1:4000}"

cp .env.compose.example .env
echo "SECRET_KEY_BASE=$(openssl rand -base64 48 | tr -d '\n')" >> .env
echo "MASTER_SECRETS_KEY=$(openssl rand 32 | base64 | tr '+/' '-_' | tr -d '=\n')" >> .env
docker compose up -d

probe() {
  # Boot runs migrations before the endpoint listens, so tolerate refused
  # connections while waiting. A non-200 answer is a verdict, not a retry.
  for _ in $(seq 1 60); do
    code=$(curl -s -o /dev/null -w '%{http_code}' "${APP}$1") || code=000
    if [ "$code" = "200" ]; then
      echo "  $1 -> 200"
      return 0
    fi
    if [ "$code" != "000" ]; then
      echo "  $1 -> $code (expected 200)" >&2
      return 1
    fi
    sleep 2
  done
  echo "  $1 never answered" >&2
  return 1
}

probe /health
probe /health/ready

# The retirement has to hold in the artifact. A suite pass is not
# evidence about the image: the tree it tested and the release someone pulls
# are different objects, and this repository has shipped a prod-only no-op
# that every test passed (the runtime image had no coreutils). The four
# `/v1` answers and the `/api` ones below need no API key, so the whole
# matrix that does not need an account is checkable here, on the image, for
# the cost of six requests.
#
# The three answers are deliberately different and all three are load-bearing
# (ADR 0057 carries the correction): `/v1` is unrouted, so it is 404 before
# any authentication runs; `/api/...` is routed as far as the API pipeline,
# so a keyless call is 401 and an `Accept: text/event-stream` is refused by
# content negotiation with 406 before dispatch. A client probing for a bare
# 404 to detect the cutover reads the other two as something else, which is
# why a regression in any single one of them matters.
answers() {
  # answers <method> <path> <expected> [curl args...]
  local method="$1" path="$2" want="$3"
  shift 3
  local got
  got=$(curl -s -o /dev/null -w '%{http_code}' -X "$method" "$@" \
    "${APP}${path}") || got=000
  if [ "$got" = "$want" ]; then
    echo "  $method $path -> $got"
    return 0
  fi
  echo "  $method $path -> $got (expected $want)" >&2
  return 1
}

json=(-H 'Content-Type: application/json' -d '{}')
stream=(-H 'Accept: text/event-stream')
nil_uuid=00000000-0000-0000-0000-000000000000

echo "the retired compatibility dialects (ADR 0057):"
answers POST /v1/chat/completions            404 "${json[@]}"
answers GET  /v1/models                      404
answers GET  "/v1/models/gpt-4o"             404
answers POST "/api/agui/${nil_uuid}"         401 "${json[@]}"
answers POST "/api/agui/${nil_uuid}"         406 "${json[@]}" "${stream[@]}"
answers POST "/api/mcp/caller/${nil_uuid}"   401 "${json[@]}"

# A dialect error body surviving on a retired path would mean a controller is
# still mounted somewhere, which the status code alone does not rule out.
body=$(curl -s -X POST "${json[@]}" "${APP}/v1/chat/completions")
if [ "${body}" = '{"errors":{"detail":"Not Found"}}' ]; then
  echo "  POST /v1/chat/completions body is the unmatched-path answer"
else
  echo "  POST /v1/chat/completions answered ${body}, not the unmatched-path answer" >&2
  exit 1
fi
