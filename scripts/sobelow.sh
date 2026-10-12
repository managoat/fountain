#!/usr/bin/env bash
# The sobelow scan, run from apps/fountain.
#
# Not plain `mix sobelow` at the umbrella root: there sobelow finds no Phoenix
# app, scans nothing and exits 0, which is indistinguishable from a pass
# (#194, #311). This script is the one entry point both callers use, so the
# working directory cannot drift between them.
#
# Callers: `mix precommit` (scripts/precommit.sh) and .github/workflows/ci.yml.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"

cd "$root/apps/fountain"
exec mix sobelow --config
