#!/usr/bin/env python3
"""Validate the complete CI plan before publishing the stable required check."""

import argparse
import json
import os


FULL_JOBS = {
    "test", "coverage", "elixir-static", "release-and-contract", "cli", "typescript-sdk",
    "compose-fresh-clone", "compose-pinned-image-boot",
}
# The SDK leg runs on every plan, docs-only included. It is a fraction of a
# minute, and the routing that used to skip an unselected language cost more
# to keep right than it saved.
SDK_JOBS = {"typescript-sdk"}
# The managoat.com pages (site/). Selected by the classifier's `site` output on
# a pull request, and always run on push and dispatch.
SITE_JOBS = {"site"}
JOBS = FULL_JOBS | SITE_JOBS | {"changes", "workflow-checks", "docs"}

# Which probes are expected to have run, per event. A push to main runs none:
# it always takes the complete plan.
PROBES = {
    "pull_request": {"changes"},
    "workflow_dispatch": {"changes"},
    "push": set(),
}


def _classification(needs):
    outputs = needs["changes"].get("outputs", {})
    if any(outputs.get(key) not in ("true", "false")
           for key in ("docs_only", "manual_docs", "cli_docs", "site")):
        raise ValueError("change classification is missing or invalid")
    if outputs["cli_docs"] == "true" and outputs["manual_docs"] != "true":
        raise ValueError("CLI documentation requires manual checks")
    return (outputs["docs_only"] == "true", outputs["cli_docs"] == "true",
            outputs["site"] == "true")


def validate(event, needs):
    if event not in PROBES:
        raise ValueError(f"unsupported CI event: {event}")
    if set(needs) != JOBS:
        raise ValueError(f"CI dependencies differ: missing={JOBS - set(needs)}, extra={set(needs) - JOBS}")

    expected = dict.fromkeys(JOBS, "skipped")
    for probe in PROBES[event]:
        expected[probe] = "success"
    expected["workflow-checks"] = "success"

    classified = "changes" in PROBES[event]
    docs_only, cli_docs, site = _classification(needs) if classified else (False, False, True)
    if event == "workflow_dispatch" and (docs_only or not site):
        raise ValueError("manual CI must select the complete plan")
    # The manual is tested and rendered by the `site` job (decisions/0081);
    # `docs` is only the CLI reference parity check, owed by a docs-only plan
    # that touched docs/cli*. A full plan runs it in cli. A docs-only
    # plan skips the server jobs and still owes the SDK legs.
    expected.update(dict.fromkeys(SDK_JOBS, "success"))
    if docs_only and cli_docs:
        expected["docs"] = "success"
    if not docs_only:
        expected.update(dict.fromkeys(FULL_JOBS, "success"))
    # The site rides along with any plan that touched it, docs-only or not.
    if site:
        expected.update(dict.fromkeys(SITE_JOBS, "success"))
    _check_results(needs, expected)


def _check_results(needs, expected):
    errors = [f"{job}: expected {result}, got {needs[job].get('result')}"
              for job, result in sorted(expected.items()) if needs[job].get("result") != result]
    if errors:
        raise ValueError("\n".join(errors))


if __name__ == "__main__":
    argparse.ArgumentParser().parse_args()
    validate(os.environ["GITHUB_EVENT_NAME"], json.loads(os.environ["CI_NEEDS"]))
    print("Every job required by this CI plan passed.")
