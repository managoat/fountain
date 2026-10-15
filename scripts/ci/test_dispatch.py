import copy
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import textwrap
import unittest

from gate import FULL_JOBS, validate
from test_gate import plan


ROOT = Path(__file__).resolve().parents[2]


class DispatchTest(unittest.TestCase):
    def test_actual_classifier_selects_full_ci_without_fetching_a_base(self):
        workflow = (ROOT / ".github/workflows/ci.yml").read_text()
        job = workflow.split("\n  changes:\n", 1)[1].split("\n  test:\n", 1)[0]
        self.assertIn("|| github.event_name == 'workflow_dispatch' }}", job)
        script = job.split("        id: filter\n", 1)[1].split("        run: |\n", 1)[1]
        script = textwrap.dedent(script.split("\n      - name:", 1)[0])
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fake_git = root / "git"
            fake_git.write_text('#!/bin/sh\ntouch "$GIT_CALLED"\nexit 97\n')
            fake_git.chmod(0o755)
            output = root / "outputs"
            result = subprocess.run(["bash", "-e", "-c", script], cwd=ROOT, capture_output=True, text=True,
                                    env=dict(os.environ, GITHUB_EVENT_NAME="workflow_dispatch",
                                             GITHUB_OUTPUT=str(output), GITHUB_BASE_REF="",
                                             GIT_CALLED=str(root / "called"),
                                             PATH=str(root) + os.pathsep + os.environ["PATH"]))
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse((root / "called").exists())
            values = dict(line.split("=", 1) for line in output.read_text().splitlines())
            self.assertEqual(values, {"diff_base": "", "docs_only": "false",
                                      "manual_docs": "true", "cli_docs": "false", "site": "true"})

    def test_gate_rejects_a_partial_manual_plan(self):
        needs = copy.deepcopy(plan("workflow_dispatch"))
        needs["changes"]["outputs"]["docs_only"] = "true"
        for job in FULL_JOBS:
            needs[job]["result"] = "skipped"
        needs["docs"]["result"] = "success"
        with self.assertRaisesRegex(ValueError, "manual CI must select the complete plan"):
            validate("workflow_dispatch", needs)

    def test_full_manual_gate_passes(self):
        needs = plan("workflow_dispatch")
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run([sys.executable, str(ROOT / "scripts/ci/gate.py")], cwd=directory,
                                    capture_output=True, text=True,
                                    env=dict(os.environ, GITHUB_EVENT_NAME="workflow_dispatch",
                                             CI_NEEDS=json.dumps(needs)))
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("Every job required by this CI plan passed.", result.stdout)
