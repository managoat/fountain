#!/usr/bin/env python3
"""Validate the complete CI plan before publishing the stable required check."""

import argparse
import json
import os
import re
from pathlib import Path


FULL_JOBS = {
    "test", "coverage", "elixir-static", "release-and-contract", "cli-plugins", "typescript-sdk",
    "core-distribution", "compose-fresh-clone", "compose-pinned-image-boot",
}
# The SDK leg runs on every plan, docs-only included; only a reused tree skips
# it. It is a fraction of a minute, and the routing that used to skip an
# unselected language cost more to keep right than it saved.
SDK_JOBS = {"typescript-sdk"}
JOBS = FULL_JOBS | {"already-tested", "changes", "workflow-checks", "docs"}

# Which probes are expected to have run, per event. A merge group is the only
# plan that runs both: the queue classifies the diff like a PR *and* asks
# whether the tree it is about to test has already been tested.
PROBES = {
    "pull_request": {"changes"},
    "workflow_dispatch": {"changes"},
    "push": {"already-tested"},
    "merge_group": {"already-tested", "changes"},
}


def _reuse(needs):
    skip = needs["already-tested"].get("outputs", {}).get("skip")
    if skip not in {"true", "false"}:
        raise ValueError("the tested-tree probe did not make a decision")
    return skip == "true"


def _classification(needs):
    outputs = needs["changes"].get("outputs", {})
    if any(outputs.get(key) not in ("true", "false") for key in ("docs_only", "manual_docs", "cli_docs")):
        raise ValueError("change classification is missing or invalid")
    tree = outputs.get("tree")
    if not isinstance(tree, str) or not re.fullmatch(r"[0-9a-f]{40}", tree):
        raise ValueError("checkout tree is missing or invalid")
    if outputs["cli_docs"] == "true" and outputs["manual_docs"] != "true":
        raise ValueError("CLI documentation requires manual checks")
    return outputs["docs_only"] == "true", outputs["manual_docs"] == "true"


def validate(event, needs):
    if event not in PROBES:
        raise ValueError(f"unsupported CI event: {event}")
    if set(needs) != JOBS:
        raise ValueError(f"CI dependencies differ: missing={JOBS - set(needs)}, extra={set(needs) - JOBS}")

    expected = dict.fromkeys(JOBS, "skipped")
    for probe in PROBES[event]:
        expected[probe] = "success"
    expected["workflow-checks"] = "success"

    reuse = _reuse(needs) if "already-tested" in PROBES[event] else False
    docs_only, manual_docs = _classification(needs) if "changes" in PROBES[event] else (False, True)
    if event == "workflow_dispatch" and docs_only:
        raise ValueError("manual CI must select the complete plan")
    # Published manuals owe docs; contributor-only text does not. A reused
    # tree skips every workload job; a docs-only plan skips the server jobs
    # and still owes the SDK legs.
    if not reuse:
        expected.update(dict.fromkeys(SDK_JOBS, "success"))
        if docs_only and manual_docs:
            expected["docs"] = "success"
        if not docs_only:
            expected.update(dict.fromkeys(FULL_JOBS, "success"))
    _check_results(needs, expected)


def _check_results(needs, expected):
    errors = [f"{job}: expected {result}, got {needs[job].get('result')}"
              for job, result in sorted(expected.items()) if needs[job].get("result") != result]
    if errors:
        raise ValueError("\n".join(errors))


if __name__ == "__main__":
    argparse.ArgumentParser().parse_args()
    needs = json.loads(os.environ["CI_NEEDS"])
    event = os.environ["GITHUB_EVENT_NAME"]
    validate(event, needs)
    # Only complete CI may publish evidence for main's tested-tree shortcut.
    if event != "push":
        Path("tested-tree.txt").write_text(needs["changes"]["outputs"]["tree"] + "\n")
    print("Every job required by this CI plan passed.")
