#!/usr/bin/env bash
# The published manual's rendering, structure and cross-extension links.
set -euo pipefail
cd "$(dirname "$0")/.."

mix test apps/fountain/test/fountain/docs_test.exs \
  apps/fountain/test/fountain_web/controllers/docs_controller_test.exs

for app in fountain_google fountain_microsoft fountain_slack; do
  (
    cd "apps/$app"
    mix test "test/$app/docs_test.exs" "test/$app/manual_test.exs"
  )
done
