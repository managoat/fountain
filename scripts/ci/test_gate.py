import copy
from pathlib import Path
import re
import unittest

from gate import FULL_JOBS, JOBS, PROBES, SDK_JOBS, validate


EVENTS = ("pull_request", "push", "merge_group", "workflow_dispatch")


def plan(event="pull_request", docs=False, reuse=False, manual=True):
    if event == "workflow_dispatch":
        docs = False
    jobs = {job: {"result": "skipped", "outputs": {}} for job in JOBS}
    jobs["workflow-checks"]["result"] = "success"
    if "already-tested" in PROBES[event]:
        jobs["already-tested"] = {"result": "success", "outputs": {"skip": str(reuse).lower()}}
    if "changes" in PROBES[event]:
        jobs["changes"] = {"result": "success", "outputs": {
            "docs_only": str(docs).lower(), "manual_docs": str(manual).lower(),
            "cli_docs": "false", "tree": "a" * 40,
        }}
    if reuse:
        return jobs
    # The SDK legs run on every plan that is not a reused tree.
    for job in SDK_JOBS:
        jobs[job]["result"] = "success"
    if docs and manual:
        jobs["docs"]["result"] = "success"
    elif not docs:
        for job in FULL_JOBS:
            jobs[job]["result"] = "success"
    return jobs


class GateTest(unittest.TestCase):
    def test_workflow_and_gate_cover_the_same_jobs(self):
        workflow = (Path(__file__).resolve().parents[2] / ".github/workflows/ci.yml").read_text()
        jobs = set(re.findall(r"^  ([a-z][a-z0-9_-]*):$", workflow.split("\njobs:\n", 1)[1], re.M))
        self.assertEqual(jobs - {"gate"}, JOBS)
        gate = workflow.split("\n  gate:\n", 1)[1]
        dependencies = gate.split("    needs:\n", 1)[1].split("    steps:\n", 1)[0]
        self.assertEqual(set(re.findall(r"^      - (.*)$", dependencies, re.M)), JOBS)

    def test_every_event_the_workflow_triggers_on_is_a_plan(self):
        """A trigger the gate cannot validate fails every run of that event.

        The merge queue is the expensive version: an unsupported event fails
        `CI required`, and the queue reads that as the PR being broken and
        ejects it.
        """
        workflow = (Path(__file__).resolve().parents[2] / ".github/workflows/ci.yml").read_text()
        triggers = workflow.split("\non:\n", 1)[1].split("\nconcurrency:", 1)[0]
        declared = set(re.findall(r"^  ([a-z_]+):$", triggers, re.M))
        self.assertEqual(declared, set(PROBES))

    def test_all_supported_plans(self):
        for event, options in [("workflow_dispatch", {}), ("pull_request", {}), ("pull_request", {"docs": True}),
                               ("push", {}),
                               ("push", {"reuse": True}), ("merge_group", {}),
                               ("merge_group", {"docs": True}),
                               ("merge_group", {"reuse": True})]:
            with self.subTest(event=event, options=options):
                validate(event, plan(event, **options))

    def test_every_required_job_rejects_failure_cancel_and_skip(self):
        for event, options in [("workflow_dispatch", {}), ("pull_request", {}), ("pull_request", {"docs": True}),
                               ("push", {}), ("push", {"reuse": True}),
                               ("merge_group", {}), ("merge_group", {"docs": True}),
                               ("merge_group", {"reuse": True})]:
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

    def test_missing_classification_or_tree_is_not_a_docs_skip(self):
        for event in ("pull_request", "merge_group", "workflow_dispatch"):
            for key in ("docs_only", "manual_docs", "cli_docs", "tree"):
                jobs = plan(event, docs=True)
                del jobs["changes"]["outputs"][key]
                with self.subTest(event=event, key=key):
                    with self.assertRaises(ValueError):
                        validate(event, jobs)

    def test_missing_reuse_decision_fails(self):
        for event in ("push", "merge_group"):
            jobs = plan(event, reuse=True)
            jobs["already-tested"]["outputs"] = {}
            with self.subTest(event=event):
                with self.assertRaises(ValueError):
                    validate(event, jobs)

    def test_sdk_legs_run_on_docs_only_plans_and_skip_only_for_reused_trees(self):
        for event in ("pull_request", "merge_group"):
            for job in SDK_JOBS:
                jobs = plan(event, docs=True)
                jobs[job]["result"] = "skipped"
                with self.subTest(event=event, job=job):
                    with self.assertRaises(ValueError):
                        validate(event, jobs)
        for job in SDK_JOBS:
            jobs = plan("merge_group", reuse=True)
            jobs[job]["result"] = "success"
            with self.subTest(job=job):
                with self.assertRaises(ValueError):
                    validate("merge_group", jobs)

    def test_sdk_job_conditions_honor_only_tree_reuse(self):
        """No classifier output may skip an SDK leg; the contract check is unconditional."""
        workflow = (Path(__file__).resolve().parents[2] / ".github/workflows/ci.yml").read_text()
        jobs = dict(re.findall(r"^  ([a-z][a-z0-9-]*):\n(.*?)(?=^  [a-z][a-z0-9-]*:|\Z)",
                               workflow.split("\njobs:\n", 1)[1], re.M | re.S))
        for job in SDK_JOBS:
            condition = re.search(r"^    if: (.*?)(?=\n\n)", jobs[job], re.M | re.S)[1]
            self.assertEqual(condition, "${{ !cancelled() && needs.already-tested.outputs.skip != 'true' }}")
        release = jobs["release-and-contract"]
        steps = dict(re.findall(r"      - name: ([^\n]+)\n(.*?)(?=      - (?:name:|uses:)|\Z)", release, re.S))
        for name in ("Set up Node", "SDK install", "SDK types match the spec",
                     "Validate OpenAPI spec", "SDK wire contract is current"):
            self.assertNotIn("        if:", steps[name])
        self.assertIn("run: scripts/sdk-contract/build.sh --check", steps["SDK wire contract is current"])

    def test_unexpected_failed_job_cannot_hide_on_docs_path(self):
        for event in ("pull_request", "merge_group"):
            jobs = plan(event, docs=True)
            jobs["test"]["result"] = "failure"
            with self.subTest(event=event):
                with self.assertRaises(ValueError):
                    validate(event, jobs)

    def test_a_merge_group_needs_both_probes(self):
        """Either probe alone would let the queue merge on half a decision."""
        for probe in ("already-tested", "changes"):
            jobs = plan("merge_group")
            jobs[probe] = {"result": "skipped", "outputs": {}}
            with self.subTest(probe=probe):
                with self.assertRaises(ValueError):
                    validate("merge_group", jobs)

    def test_unsupported_event_is_rejected(self):
        with self.assertRaises(ValueError):
            validate("unknown_event", plan("pull_request"))
