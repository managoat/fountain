import copy
from pathlib import Path
import re
import unittest

from gate import FULL_JOBS, JOBS, PROBES, SDK_JOBS, SITE_JOBS, validate


EVENTS = ("pull_request", "push", "workflow_dispatch")
PLANS = [("workflow_dispatch", {}), ("pull_request", {}), ("pull_request", {"docs": True}),
         ("pull_request", {"docs": True, "cli": True, "site": True}),
         ("pull_request", {"docs": True, "manual": False}), ("pull_request", {"site": True}),
         ("pull_request", {"docs": True, "manual": False, "site": True}), ("push", {})]

# Jobs in ci.yml that CI required deliberately does not wait for: the site
# publish runs after the `site` job on main and gates nothing.
UNGATED = {"gate", "site-publish"}


def plan(event="pull_request", docs=False, manual=True, site=False, cli=False):
    if event != "pull_request":
        docs, site, cli = False, True, False
    jobs = {job: {"result": "skipped", "outputs": {}} for job in JOBS}
    jobs["workflow-checks"]["result"] = "success"
    if "changes" in PROBES[event]:
        jobs["changes"] = {"result": "success", "outputs": {
            "docs_only": str(docs).lower(), "manual_docs": str(manual).lower(), "cli_docs": str(cli).lower(),
            "site": str(site).lower(),
        }}
    # The SDK legs run on every plan.
    for job in SDK_JOBS:
        jobs[job]["result"] = "success"
    if site:
        for job in SITE_JOBS:
            jobs[job]["result"] = "success"
    if docs and cli:
        jobs["docs"]["result"] = "success"
    if not docs:
        for job in FULL_JOBS:
            jobs[job]["result"] = "success"
    return jobs


class GateTest(unittest.TestCase):
    def test_workflow_and_gate_cover_the_same_jobs(self):
        workflow = (Path(__file__).resolve().parents[2] / ".github/workflows/ci.yml").read_text()
        jobs = set(re.findall(r"^  ([a-z][a-z0-9_-]*):$", workflow.split("\njobs:\n", 1)[1], re.M))
        self.assertEqual(jobs - UNGATED, JOBS)
        gate = workflow.split("\n  gate:\n", 1)[1]
        dependencies = gate.split("    needs:\n", 1)[1].split("    steps:\n", 1)[0]
        self.assertEqual(set(re.findall(r"^      - (.*)$", dependencies, re.M)), JOBS)

    def test_every_event_the_workflow_triggers_on_is_a_plan(self):
        """A trigger the gate cannot validate fails every run of that event."""
        workflow = (Path(__file__).resolve().parents[2] / ".github/workflows/ci.yml").read_text()
        triggers = workflow.split("\non:\n", 1)[1].split("\nconcurrency:", 1)[0]
        declared = set(re.findall(r"^  ([a-z_]+):$", triggers, re.M))
        self.assertEqual(declared, set(PROBES))

    def test_all_supported_plans(self):
        for event, options in PLANS:
            with self.subTest(event=event, options=options):
                validate(event, plan(event, **options))

    def test_every_required_job_rejects_failure_cancel_and_skip(self):
        for event, options in PLANS:
            original = plan(event, **options)
            for job, state in original.items():
                if state["result"] != "success":
                    continue
                for result in ("failure", "cancelled", "skipped", None):
                    with self.subTest(event=event, options=options, job=job, result=result):
                        jobs = copy.deepcopy(original)
                        jobs[job]["result"] = result
                        with self.assertRaises(ValueError):
                            validate(event, jobs)

    def test_missing_job_is_not_a_pass(self):
        for event in EVENTS:
            for job in JOBS:
                jobs = plan(event)
                del jobs[job]
                with self.subTest(event=event, job=job):
                    with self.assertRaises(ValueError):
                        validate(event, jobs)

    def test_missing_classification_is_not_a_docs_skip(self):
        for event in ("pull_request", "workflow_dispatch"):
            for key in ("docs_only", "manual_docs", "cli_docs"):
                jobs = plan(event, docs=True)
                del jobs["changes"]["outputs"][key]
                with self.subTest(event=event, key=key):
                    with self.assertRaises(ValueError):
                        validate(event, jobs)

    def test_main_runs_the_complete_plan(self):
        """A push has no classifier, so nothing may be skipped on main."""
        jobs = plan("push")
        for job in FULL_JOBS:
            with self.subTest(job=job):
                broken = copy.deepcopy(jobs)
                broken[job]["result"] = "skipped"
                with self.assertRaises(ValueError):
                    validate("push", broken)

    def test_site_runs_on_main_and_dispatch(self):
        """No classifier on push, and dispatch is complete: the site is never skipped there."""
        for event in ("push", "workflow_dispatch"):
            for job in SITE_JOBS:
                jobs = plan(event)
                jobs[job]["result"] = "skipped"
                with self.subTest(event=event, job=job):
                    with self.assertRaises(ValueError):
                        validate(event, jobs)
        jobs = plan("workflow_dispatch")
        jobs["changes"]["outputs"]["site"] = "false"
        for job in SITE_JOBS:
            jobs[job]["result"] = "skipped"
        with self.assertRaisesRegex(ValueError, "complete plan"):
            validate("workflow_dispatch", jobs)

    def test_site_skip_is_accepted_only_when_unselected(self):
        for options in ({}, {"docs": True}, {"docs": True, "manual": False}):
            jobs = plan("pull_request", **options)
            self.assertEqual(jobs["site"]["result"], "skipped")
            validate("pull_request", jobs)
            jobs["site"]["result"] = "success"
            with self.subTest(options=options), self.assertRaises(ValueError):
                validate("pull_request", jobs)

    def test_site_publish_waits_for_the_site_tests(self):
        workflow = (Path(__file__).resolve().parents[2] / ".github/workflows/ci.yml").read_text()
        job = workflow.split("\n  site-publish:\n", 1)[1].split("\n\n", 1)[0]
        self.assertIn("    needs: site\n", job)
        self.assertIn("needs.site.result == 'success'", job)
        # `changes` is skipped on push, so a condition without a status
        # function (an implicit success()) skips this job on every push.
        self.assertIn("!cancelled()", job)
        self.assertIn("needs.site.outputs.publish == 'true'", job)
        self.assertIn("uses: ./.github/workflows/site.yml", job)
        site = (Path(__file__).resolve().parents[2] / ".github/workflows/site.yml").read_text()
        triggers = site.split("\non:\n", 1)[1].split("\n\n", 1)[0]
        self.assertEqual(set(re.findall(r"^  ([a-z_]+):$", triggers, re.M)), {"workflow_call"})

    def test_sdk_legs_run_on_docs_only_plans(self):
        for job in SDK_JOBS:
            jobs = plan("pull_request", docs=True)
            jobs[job]["result"] = "skipped"
            with self.subTest(job=job):
                with self.assertRaises(ValueError):
                    validate("pull_request", jobs)

    def test_sdk_job_conditions_are_unconditional(self):
        """No classifier output may skip an SDK leg; the contract check is unconditional."""
        workflow = (Path(__file__).resolve().parents[2] / ".github/workflows/ci.yml").read_text()
        jobs = dict(re.findall(r"^  ([a-z][a-z0-9-]*):\n(.*?)(?=^  [a-z][a-z0-9-]*:|\Z)",
                               workflow.split("\njobs:\n", 1)[1], re.M | re.S))
        for job in SDK_JOBS:
            condition = re.search(r"^    if: (.*?)(?=\n\n)", jobs[job], re.M | re.S)[1]
            self.assertEqual(condition, "${{ !cancelled() }}")
        release = jobs["release-and-contract"]
        steps = dict(re.findall(r"      - name: ([^\n]+)\n(.*?)(?=      - (?:name:|uses:)|\Z)", release, re.S))
        for name in ("Set up Node", "SDK install", "SDK types match the spec",
                     "Validate OpenAPI spec", "Export the OpenAPI document"):
            self.assertNotIn("        if:", steps[name])
        self.assertIn("run: python3 scripts/sdk-contract/generate.py --skip-export --check",
                      steps["SDK types match the spec"])

    def test_unexpected_failed_job_cannot_hide_on_docs_path(self):
        jobs = plan("pull_request", docs=True)
        jobs["test"]["result"] = "failure"
        with self.assertRaises(ValueError):
            validate("pull_request", jobs)

    def test_unsupported_event_is_rejected(self):
        for event in ("unknown_event", "merge_group"):
            with self.subTest(event=event):
                with self.assertRaises(ValueError):
                    validate(event, plan("pull_request"))
