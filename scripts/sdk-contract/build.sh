#!/usr/bin/env bash
# Rebuild the SDK wire contract from the server.
#
#   scripts/sdk-contract/build.sh          rebuild dist/openapi.json and
#                                          sdk/contract/contract.json
#   scripts/sdk-contract/build.sh --check  rebuild the artifact, then fail if
#                                          the checked-in contract is stale
#
# The export needs the Elixir toolchain and a database URL, because rendering
# the spec boots the app. The SDK verifier does not — they read the checked
# in projection, which is the whole point of committing it.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# From the umbrella root, where the `openapi.export` alias lives.
(cd "${root}" && mix openapi.export >/dev/null)

exec python3 "${root}/scripts/sdk-contract/build.py" "$@"
