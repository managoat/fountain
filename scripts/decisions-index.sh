#!/usr/bin/env bash
# Regenerate decisions/index.md from ADR frontmatter (OKF spec §8).
#
# `okf index` would do this too, but it sorts by title and truncates the
# description; ADRs read better in number order with their status beside them.
# CI runs this and fails if the committed index differs (see
# .github/workflows/decisions.yml), so edit frontmatter, not the index.
set -euo pipefail
cd "$(dirname "$0")/../decisions"

{
  cat <<'EOF'
# Decisions

Architecture Decision Records for Managoat, one per file, numbered in the
order they were opened. The index lists the decision status and summary;
read each ADR for its implementation status and rationale. The
[template](0001-template.md) describes the small required frontmatter.
`okf validate .` checks the bundle and `okf backlinks . <id>` shows dependencies.
Gaps in numbering are ADRs that were proposed and closed unmerged: 0012
(#488, deploy manifests to fountain-ops), 0066 (#2600, app-owned principals)
and 0069 (#2641, a secret never enters the sandbox). Their text is on those
pull requests.

## ADRs

| # | Title | ADR status | Description |
|---|-------|------------|-------------|
EOF
  for f in [0-9][0-9][0-9][0-9]-*.md; do
    awk -v file="$f" '
      function unq(s) { sub(/^"/, "", s); sub(/"$/, "", s); gsub(/\\"/, "\"", s); return s }
      NR == 1 && $0 != "---" { exit 1 }
      NR > 1 && $0 == "---" { done = 1 }
      !done && /^adr: /         { adr = unq(substr($0, 6)) }
      !done && /^title: /       { title = unq(substr($0, 8)) }
      !done && /^adr_status: /  { st = unq(substr($0, 13)) }
      !done && /^description: / { desc = unq(substr($0, 14)) }
      END {
        gsub(/\|/, "\\|", title); gsub(/\|/, "\\|", desc)
        printf "| %s | [%s](%s) | %s | %s |\n", adr, title, file, st, desc
      }' "$f"
  done
} > index.md

# Every ADR's OKF `status` must be the lifecycle its `adr_status` maps to
# (0001-template.md): Proposed is draft; Accepted, Partially accepted and the
# template are stable; Superseded by NNNN, Retired and Rejected are deprecated.
# okf validates `status` alone, so a stale pair would otherwise pass. The
# index above is written first, so one bad pair does not hide a stale index.
bad=0
for f in [0-9][0-9][0-9][0-9]-*.md; do
  awk -v file="$f" '
    function unq(s) { sub(/^"/, "", s); sub(/"$/, "", s); return s }
    NR > 1 && $0 == "---" { exit }
    /^status: /     { st = unq(substr($0, 9)) }
    /^adr_status: / { adr = unq(substr($0, 13)) }
    END {
      if (adr == "Proposed") want = "draft"
      else if (adr == "Accepted" || adr == "Partially accepted" || adr == "Template") want = "stable"
      else if (adr ~ /^Superseded by [0-9][0-9][0-9][0-9]$/ || adr == "Retired" || adr == "Rejected") want = "deprecated"
      else { printf "%s: unknown adr_status \"%s\"\n", file, adr > "/dev/stderr"; exit 1 }
      if (st != want) { printf "%s: adr_status \"%s\" needs status: %s, not \"%s\"\n", file, adr, want, st > "/dev/stderr"; exit 1 }
    }' "$f" || bad=1
done
if [ "$bad" -ne 0 ]; then
  echo "decisions-index: fix the status/adr_status pairs above (see 0001-template.md)" >&2
  exit 1
fi

# One ADR per number, and the number in the file name is the one in its
# frontmatter. Two ADRs once shared 0089, which made "ADR 0089" ambiguous in
# code comments and links; this keeps that from happening again.
bad=0
numbers=""
for f in [0-9][0-9][0-9][0-9]-*.md; do
  adr=$(awk 'NR > 1 && $0 == "---" { exit } /^adr: / { v = substr($0, 6); gsub(/"/, "", v); print v }' "$f")
  if [ "$adr" != "${f:0:4}" ]; then
    echo "decisions-index: $f has adr: \"$adr\", not its file name's ${f:0:4}" >&2
    bad=1
  fi
  numbers+="${f:0:4}"$'\n'
done
for n in $(printf '%s' "$numbers" | sort | uniq -d); do
  echo "decisions-index: ADR $n is used by more than one file:" "$n"-*.md >&2
  bad=1
done
if [ "$bad" -ne 0 ]; then
  echo "decisions-index: give each ADR its own number, the same in adr: and the file name" >&2
  exit 1
fi
