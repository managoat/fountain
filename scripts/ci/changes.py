#!/usr/bin/env python3
"""Select documentation checks from one conservative, NUL-delimited diff."""

import re
import subprocess
import sys


# An SDK's README is documentation; its job runs on every plan regardless.
SDK_READMES = frozenset(f"sdk/{language}/README.md"
                        for language in ("elixir", "python", "typescript", "swift"))


# Only these extension manuals have registered documentation suites.
MANUAL_EXTENSIONS = ("fountain_buzz", "fountain_google", "fountain_microsoft", "fountain_slack")
CONTRIBUTOR_FILES = {"CLAUDE.md", "CONTRIBUTING.md", "SETUP.md", "SDKs.md", "scripts/ci/README.md"}


def contributor_doc(path):
    return path in CONTRIBUTOR_FILES or (
        path.endswith(".md") and path.startswith(("contributing/", "standards/", "decisions/", "changelog.d/"))
    )


def manual_doc(path):
    # README's diagram alt text is checked by Fountain.DocsTest.
    return path in {"README.md", "CHANGELOG.md"} or path.startswith(
        ("docs/", *(f"apps/{app}/docs/" for app in MANUAL_EXTENSIONS))
    )


def valid_paths(paths):
    return bool(paths) and all(
        path and not path.startswith("/") and not re.search(r"[\x00-\x1f\x7f]", path)
        and not any(part in {"", ".", ".."} for part in path.split("/"))
        for path in paths
    )


def classify_docs(paths):
    if not valid_paths(paths):
        return {"docs_only": False, "manual_docs": True, "cli_docs": False}
    return {
        "docs_only": all(contributor_doc(p) or manual_doc(p) or p in SDK_READMES for p in paths),
        "manual_docs": any(manual_doc(p) for p in paths),
        "cli_docs": any(p == "docs/cli.md" or p.startswith("docs/cli/") for p in paths),
    }


def changed_paths(base):
    if not re.fullmatch(r"[0-9a-f]{40}", base):
        return []
    try:
        result = subprocess.run(
            ["git", "diff", "--no-ext-diff", "--no-textconv", "--no-renames",
             "--name-only", "-z", base, "HEAD", "--"],
            check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        ).stdout
        if not result or not result.endswith(b"\0"):
            return []
        paths = result[:-1].decode("utf-8").split("\0")
        return paths if valid_paths(paths) else []
    except (OSError, subprocess.CalledProcessError, UnicodeDecodeError):
        return []


if __name__ == "__main__":
    paths = changed_paths(sys.argv[1]) if len(sys.argv) == 2 else []
    outputs = classify_docs(paths)
    # Never write paths or other diff-controlled text to GITHUB_OUTPUT.
    for key, value in outputs.items():
        print(f"{key}={str(value).lower()}")
