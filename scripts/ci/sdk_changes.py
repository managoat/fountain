#!/usr/bin/env python3
"""Select SDKs from a Git diff; unknown paths or unreadable diffs select all."""

import re
import subprocess
import sys


LANGUAGES = frozenset({"elixir", "python", "typescript", "swift"})
# SDK-local docs and tooling take precedence over the unrelated-path allowlist.
OWNED_FILES = {
    "elixir": {"docs/elixir-sdk.md", "scripts/elixir-sdk-release.exs",
               ".github/workflows/elixir-sdk-publish.yml",
               ".github/workflows/elixir-sdk-release-gate.yml"},
    "python": {"docs/python-sdk.md", ".github/workflows/python-sdk-publish.yml",
               ".github/workflows/python-sdk-release-gate.yml"},
    "typescript": {"docs/sdk.md", "scripts/sdk-release.mjs", "scripts/sdk-publish-tag.mjs",
                   "scripts/sdk-publish-tag.test.mjs", ".github/workflows/sdk-publish.yml",
                   ".github/workflows/sdk-release-gate.yml"},
    "swift": {"docs/swift-sdk.md", "Package.swift", "Package.resolved", ".swift-format"},
}
# Only test trees go here, never a whole app. `ee/lib/fountain_web/` must keep
# fanning out: it can move the OpenAPI document, which every SDK is generated
# against.
UNRELATED_PREFIXES = (
    "docs/", "decisions/", "assets/", "apps/fountain/assets/",
    "apps/fountain/lib/fountain_web/live/", "apps/fountain/lib/fountain_web/components/",
    "apps/fountain/test/", "apps/fountain_buzz/test/", "apps/fountain_support/test/",
    "apps/fountain_google/test/",
    "ee/test/",
)
UNRELATED_FILES = {
    "apps/fountain/lib/fountain/telemetry.ex", "apps/fountain/lib/fountain/telemetry_tick.ex",
    "apps/fountain/lib/fountain_web/telemetry.ex",
}


def classify(paths):
    selected = set()
    if not paths:
        return LANGUAGES
    for path in paths:
        if (not path or path.startswith("/") or re.search(r"[\x00-\x1f\x7f]", path)
                or any(part in {"", ".", ".."} for part in path.split("/"))):
            return LANGUAGES
        owner = next((language for language in LANGUAGES
                      if path.startswith(f"sdk/{language}/") or path in OWNED_FILES[language]), None)
        if owner:
            selected.add(owner)
        elif path not in UNRELATED_FILES and not path.startswith(UNRELATED_PREFIXES):
            # Shared contract/conformance, API implementation, build config,
            # CI policy and every unregistered path require every SDK.
            return LANGUAGES
    return frozenset(selected)


def from_git(base):
    if not re.fullmatch(r"[0-9a-f]{40}", base):
        return LANGUAGES
    try:
        result = subprocess.run(
            ["git", "diff", "--no-ext-diff", "--no-textconv", "--no-renames",
             "--name-only", "-z", base, "HEAD", "--"],
            check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        ).stdout
        if not result or not result.endswith(b"\0"):
            return LANGUAGES
        return classify(result[:-1].decode("utf-8").split("\0"))
    except (OSError, subprocess.CalledProcessError, UnicodeDecodeError):
        return LANGUAGES


if __name__ == "__main__":
    selected = from_git(sys.argv[1]) if len(sys.argv) == 2 else LANGUAGES
    # Only fixed keys and boolean values reach GITHUB_OUTPUT, never file names.
    for language in sorted(LANGUAGES):
        print(f"sdk_{language}={str(language in selected).lower()}")
