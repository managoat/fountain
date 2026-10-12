#!/usr/bin/env bash
# Dead-code reports for the server and the two Go modules. Advisory: nothing
# here gates a merge, and the Elixir half is a list of candidates rather than
# verdicts (CONTRIBUTING.md, "Finding dead code", explains the five shapes it
# gets wrong). `.github/workflows/dead-code.yml` runs this monthly.
#
#   scripts/dead-code.sh            both
#   scripts/dead-code.sh elixir     public functions no compiled module calls
#   scripts/dead-code.sh go         unreachable functions, both Go modules
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
what=${1:-all}

# x/tools ships deadcode; pinned so two runs of the report agree.
DEADCODE_VERSION=${DEADCODE_VERSION:-v0.50.0}

elixir_report() {
  echo "## Elixir: public functions no compiled module calls (mix_unused)"
  echo
  # mix_unused merges its manifest across compiles, retaining deleted callers.
  # Clean this app's dev artifacts first (not dependencies or other environments),
  # then --force so the tracer sees every remaining module.
  # Keep compiler diagnostics visible and propagate analyzer failures. Only
  # dead-code hints enter the report: mix_unused 0.4.1 cannot disable its
  # Private analyzer through config, and a same-module caller is still live.
  # shellcheck disable=SC1010 # `do` is mix's task, not the shell keyword
  (cd "$root/apps/fountain" &&
    MIX_UNUSED=1 MIX_ENV=dev mix do clean --only dev + compile --force) |
    tee /dev/stderr |
    awk '/^hint: .* (is unused|is called only recursively)$/ { print; if (getline > 0) print }'
}

go_report() {
  echo "## Go: unreachable functions (golang.org/x/tools/cmd/deadcode)"
  echo
  echo "### cli"
  # -test: a function only a test reaches is not unreachable.
  (cd "$root/cli" && go run "golang.org/x/tools/cmd/deadcode@$DEADCODE_VERSION" -test ./...)
  echo
}

case "$what" in
  elixir) elixir_report ;;
  go) go_report ;;
  all)
    elixir_report
    echo
    go_report
    ;;
  *)
    echo "usage: $0 [elixir|go|all]" >&2
    exit 2
    ;;
esac
