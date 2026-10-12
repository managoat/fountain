import copy
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import textwrap
import unittest

from changes import MANUAL_EXTENSIONS, classify_docs
from gate import validate
from test_gate import plan


ROOT = Path(__file__).resolve().parents[2]


class DocumentationRoutingTest(unittest.TestCase):
    def test_paths_select_checks(self):
        cases = [
            (["CLAUDE.md", "CONTRIBUTING.md", "SETUP.md", "contributing/docs.md",
              "standards/new-guide.md", "scripts/ci/README.md"], True, False, False),
            (["README.md"], True, True, False),
            (["decisions/0001-template.md", "decisions/index.md"], True, False, False),
            (["changelog.d/2210-docs.md"], True, False, False),
            (["docs/index.md", "changelog.d/2210-docs.md"], True, True, False),
            (["CHANGELOG.md"], True, True, False),
            (["docs/nav.yml", "docs/images/primitives.svg"], True, True, False),
            (["CONTRIBUTING.md", "docs/index.md"], True, True, False),
            (["docs/cli/commands.md"], True, True, True),
            (["docs/sdk.md"], True, True, False),
            (["sdk/typescript/README.md"], True, False, False),
        ]
        cases += [([f"apps/{app}/docs/nav.yml", f"apps/{app}/docs/guide.md"],
                   True, True, False) for app in MANUAL_EXTENSIONS]
        for paths, short, manual, cli in cases:
            with self.subTest(paths=paths):
                flags = classify_docs(paths)
                self.assertEqual(flags, {"docs_only": short, "manual_docs": manual, "cli_docs": cli})
                for event, reuse in (("pull_request", False), ("merge_group", False), ("merge_group", True)):
                    needs = plan(event, docs=short, manual=manual, reuse=reuse)
                    needs["changes"]["outputs"]["cli_docs"] = str(cli).lower()
                    validate(event, needs)
                    self.assertEqual(needs["docs"]["result"],
                                     "success" if manual and not reuse else "skipped")
                    for job, state in needs.items():
                        if state["result"] == "success":
                            for result in ("failure", "cancelled", "skipped"):
                                broken = copy.deepcopy(needs)
                                broken[job]["result"] = result
                                with self.assertRaises(ValueError, msg=f"{event}: {job} {result}"):
                                    validate(event, broken)

    def test_code_and_unknown_paths_cannot_enter_the_short_path(self):
        for path in (
            "apps/fountain/lib/fountain/agents.ex", "apps/fountain/test/fountain/docs_test.exs",
            "apps/fountain_buzz/lib/fountain_buzz/docs.ex", "apps/fountain_buzz/test/fountain_buzz/docs_test.exs",
            "apps/new_extension/docs/page.md", "contributing/tool.py", "standards/check.sh",
            "config/test.exs", "mix.exs", "mix.lock", "Dockerfile",
            "decisions/evidence/decimal-advisory.json", "decisions/check.py", "changelog.d/check.sh",
            "deploy/k8s/prometheusrule.yaml", "deploy/grafana/fountain-ops.json",
            "scripts/test-alerts.py", "scripts/decisions-index.sh", "scripts/test-docs.sh", ".github/workflows/ci.yml",
            "sdk/typescript/src/client.ts", "sdk/contract/README.md", "new-directory/guide.md",
        ):
            with self.subTest(path=path):
                self.assertFalse(classify_docs(["CONTRIBUTING.md", "docs/cli.md", path])["docs_only"])

    def test_malformed_paths_and_empty_diffs_require_full_validation(self):
        for paths in ([], [""], ["/docs/index.md"], ["docs/../mix.exs"],
                      ["docs//index.md"], ["docs/./index.md"], ["docs/file\ndocs_only=true"]):
            with self.subTest(paths=paths):
                self.assertFalse(classify_docs(paths)["docs_only"])

    def test_cli_reference_checks_cannot_be_hidden_by_contributor_classification(self):
        for event in ("pull_request", "merge_group"):
            needs = plan(event, docs=True, manual=False)
            needs["changes"]["outputs"]["cli_docs"] = "true"
            with self.assertRaisesRegex(ValueError, "CLI documentation requires manual checks"):
                validate(event, needs)

    def test_malformed_documentation_flags_fail_the_gate(self):
        for key in ("docs_only", "manual_docs", "cli_docs"):
            for value in (None, "", "TRUE", True, False, 0, [], {}):
                with self.subTest(key=key, value=value):
                    needs = plan("merge_group", docs=True, manual=False, reuse=True)
                    needs["changes"]["outputs"][key] = value
                    with self.assertRaises(ValueError):
                        validate("merge_group", needs)

    def test_real_diff_includes_deleted_and_renamed_code(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            def git(*args):
                return subprocess.check_output(["git", *args], cwd=root, stderr=subprocess.DEVNULL).decode().strip()
            def write(name):
                p = root / name
                p.parent.mkdir(parents=True, exist_ok=True)
                p.write_text("fixture\n")
            def commit():
                git("add", "-A")
                git("-c", "user.name=Docs test", "-c", "user.email=docs@example.invalid",
                    "-c", "commit.gpgsign=false", "commit", "-qm", "fixture")
                return git("rev-parse", "HEAD")
            def outputs(base):
                result = subprocess.check_output([sys.executable, str(ROOT / "scripts/ci/changes.py"), base],
                                                 cwd=root, text=True)
                return dict(line.split("=", 1) for line in result.splitlines())
            git("init", "-q")
            write("config/runtime.exs")
            write("docs/old.md")
            base = commit()
            (root / "docs/old.md").unlink()
            commit()
            self.assertEqual(outputs(base)["docs_only"], "true")
            base = git("rev-parse", "HEAD")
            git("mv", "config/runtime.exs", "docs/moved.md")
            commit()
            self.assertEqual(outputs(base)["docs_only"], "false")
            for invalid in ("", "--output=unsafe", "a" * 40, git("rev-parse", "HEAD")):
                self.assertEqual(outputs(invalid)["docs_only"], "false")

    def test_workflow_classifies_actual_pr_and_merge_group_bases(self):
        workflow = (ROOT / ".github/workflows/ci.yml").read_text()
        job = workflow.split("\n  changes:\n", 1)[1].split("\n  test:\n", 1)[0]
        script = textwrap.dedent(job.split("        id: filter\n", 1)[1].split("        run: |\n", 1)[1])
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            def git(*args):
                return subprocess.check_output(["git", *args], cwd=root, stderr=subprocess.DEVNULL).decode().strip()
            def commit():
                git("add", "-A")
                git("-c", "user.name=Docs test", "-c", "user.email=docs@example.invalid",
                    "-c", "commit.gpgsign=false", "commit", "-qm", "fixture")
            git("init", "-q", "-b", "main")
            classifier = root / "scripts/ci/changes.py"
            classifier.parent.mkdir(parents=True)
            classifier.write_text((ROOT / "scripts/ci/changes.py").read_text())
            commit()
            git("checkout", "-qb", "feature")
            git("remote", "add", "origin", str(root))
            output = root / ".git/ci-outputs"
            for path, short, manual in (("CONTRIBUTING.md", True, False),
                                        ("docs/cli.md", True, True),
                                        ("decisions/0002-choice.md", True, False),
                                        ("changelog.d/2210-docs.md", True, False),
                                        ("CHANGELOG.md", True, True),
                                        ("apps/fountain_slack/docs/nav.yml", True, True),
                                        ("sdk/typescript/README.md", True, False),
                                        ("config/runtime.exs", False, False)):
                base = git("rev-parse", "HEAD")
                git("branch", "-f", "main", base)
                target = root / path
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text("fixture\n")
                commit()
                for event in ("pull_request", "merge_group"):
                    with self.subTest(path=path, event=event):
                        output.write_text("")
                        result = subprocess.run(["bash", "-e", "-c", script], cwd=root,
                                                capture_output=True, text=True,
                                                env=dict(os.environ, GITHUB_EVENT_NAME=event,
                                                         GITHUB_OUTPUT=str(output), GITHUB_BASE_REF="main",
                                                         MERGE_GROUP_BASE_SHA=base if event == "merge_group" else ""))
                        self.assertEqual(result.returncode, 0, result.stderr)
                        values = dict(line.split("=", 1) for line in output.read_text().splitlines())
                        self.assertEqual(values["diff_base"], base)
                        self.assertEqual(values["docs_only"], str(short).lower())
                        self.assertEqual(values["manual_docs"], str(manual).lower())


class DocumentationRunnerTest(unittest.TestCase):
    def test_alert_evaluation_skips_only_explicit_docs_plans(self):
        workflow = (ROOT / ".github/workflows/ci.yml").read_text()
        job = workflow.split("\n  workflow-checks:\n", 1)[1].split("\n  gate:\n", 1)[0]
        self.assertIn("    needs: changes\n", job)
        # A skipped classifier on push must not skip the required policy job.
        self.assertIn("    if: ${{ !cancelled() }}\n", job)
        for name in ("Install the alert rule evaluator", "Evaluate shipped alert fixtures"):
            step = job.split(f"      - name: {name}\n", 1)[1].split("      - ", 1)[0]
            self.assertIn("        if: ${{ needs.changes.outputs.docs_only != 'true' }}\n", step)
        for name in ("Reject conflict markers", "Test CI decisions", "Check the changelog fragments"):
            step = job.split(f"      - name: {name}\n", 1)[1].split("      - ", 1)[0]
            self.assertNotIn("        if:", step)

    def test_workflow_requires_manual_selection_and_honors_tree_reuse(self):
        workflow = (ROOT / ".github/workflows/ci.yml").read_text()
        job = workflow.split("\n  docs:\n", 1)[1].split("\n  workflow-checks:\n", 1)[0]
        self.assertIn("needs: [already-tested, changes]", job)
        for condition in ("needs.already-tested.outputs.skip != 'true'",
                          "needs.changes.outputs.docs_only == 'true'",
                          "needs.changes.outputs.manual_docs == 'true'"):
            self.assertIn(condition, job)
        self.assertIn("run: bash scripts/test-docs.sh", job)
        self.assertIn("if: ${{ needs.changes.outputs.cli_docs == 'true' }}", job)
        self.assertIn("go test -count=1 ./internal/cmd -run", job)

    def test_runner_covers_registered_manuals_and_stops_on_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            mix = root / "mix"
            mix.write_text('#!/bin/bash\nprintf "%s|%s\\n" "$PWD" "$*" >> "$DOCS_CALLS"\n'
                           'if [[ "$PWD" == *"${FAIL_APP:-never-match}" ]]; then exit 42; fi\n')
            mix.chmod(0o755)
            calls = root / "calls"
            env = dict(os.environ, PATH=str(root) + os.pathsep + os.environ["PATH"], DOCS_CALLS=str(calls))
            result = subprocess.run(["bash", str(ROOT / "scripts/test-docs.sh")], env=env)
            self.assertEqual(result.returncode, 0)
            entries = [line.split("|", 1) for line in calls.read_text().splitlines()]
            self.assertEqual([Path(cwd).name for cwd, _ in entries[1:]], list(MANUAL_EXTENSIONS))
            self.assertEqual(len(entries), 1 + len(MANUAL_EXTENSIONS))
            self.assertEqual(entries[0][1].split()[1:], [
                "apps/fountain/test/fountain/docs_test.exs",
                "apps/fountain/test/fountain_web/controllers/docs_controller_test.exs",
            ])
            for app, (_, command) in zip(MANUAL_EXTENSIONS, entries[1:]):
                self.assertEqual(command.split()[1:], [f"test/{app}/docs_test.exs", f"test/{app}/manual_test.exs"])
            for cwd, command in entries:
                self.assertTrue(command.startswith("test "))
                for test in command.split()[1:]:
                    self.assertTrue((Path(cwd) / test).is_file(), test)
            calls.unlink()
            result = subprocess.run(["bash", str(ROOT / "scripts/test-docs.sh")],
                                    env=dict(env, FAIL_APP="fountain_buzz"))
            self.assertEqual(result.returncode, 42)
            self.assertEqual(len(calls.read_text().splitlines()), 2)
