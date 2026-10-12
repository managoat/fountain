#!/usr/bin/env bash
# The published manual's rendering, structure and links.
set -euo pipefail
cd "$(dirname "$0")/.."

mix test apps/fountain/test/fountain/docs_test.exs \
  apps/fountain/test/fountain_web/controllers/docs_controller_test.exs
