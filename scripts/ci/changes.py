#!/usr/bin/env python3
"""Select documentation checks from one conservative, NUL-delimited diff."""

import re
import subprocess
import sys


# An SDK's README is documentation; its job runs on every plan regardless.
SDK_READMES = frozenset({"sdk/typescript/README.md"})


CONTRIBUTOR_FILES = {"CLAUDE.md", "CONTRIBUTING.md", "SETUP.md", "scripts/ci/README.md"}


def contributor_doc(path):
    return path in CONTRIBUTOR_FILES or (
        path.endswith(".md") and path.startswith(("contributing/", "decisions/"))
    )


# The managoat.com pages: a Mix project of their own that the server never
# compiles, reads or ships. ci.yml's `site` job tests and renders them, so a
# site-only diff owes the server nothing and takes the short path. The
# workflow files are not here: a CI change takes the full plan.
def site_path(path):
    return path.startswith("site/")


# What the `site` job reads besides site/: the manual (docs/), which it
# renders and tests (decisions/0081); the files its pages include by snippet
# or its tests read (MANUAL_SOURCES); the toolchain pin; and the two
# workflows that run and publish it. site/test/manual_test.exs fails if a
# page includes a file outside docs/ and MANUAL_SOURCES.
MANUAL_SOURCES = (
    "README.md",
    "apps/fountain/priv/first_request/",
    "deploy/k8s/prometheusrule.yaml",
    "sdk/typescript/examples/",
)
SITE_INPUTS = {"apps/fountain/priv/static/assets/paper.css", ".tool-versions", ".github/workflows/ci.yml", ".github/workflows/site.yml"}


def manual_source(path):
    return any(path == source or (source.endswith("/") and path.startswith(source))
               for source in MANUAL_SOURCES)


def site_input(path):
    return site_path(path) or path.startswith("docs/") or manual_source(path) or path in SITE_INPUTS


def manual_doc(path):
    # Published Markdown, rendered or tested by the `site` job: the manual,
    # and the README whose diagram alt text a manual test pins.
    return path == "README.md" or path.startswith("docs/")


def valid_paths(paths):
    return bool(paths) and all(
        path and not path.startswith("/") and not re.search(r"[\x00-\x1f\x7f]", path)
        and not any(part in {"", ".", ".."} for part in path.split("/"))
        for path in paths
    )


def classify_docs(paths):
    if not valid_paths(paths):
        return {"docs_only": False, "manual_docs": True, "cli_docs": False, "site": True}
    return {
        # "docs_only" is the short path: nothing here needs the server plan.
        "docs_only": all(
            contributor_doc(p) or manual_doc(p) or site_path(p) or p in SDK_READMES for p in paths
        ),
        "manual_docs": any(manual_doc(p) for p in paths),
        "cli_docs": any(p == "docs/cli.md" or p.startswith("docs/cli/") for p in paths),
        "site": any(site_input(p) for p in paths),
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
