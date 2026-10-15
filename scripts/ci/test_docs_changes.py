import copy
import os
import re
from pathlib import Path
import subprocess
import sys
import tempfile
import textwrap
import unittest

from changes import classify_docs
from gate import validate
from test_gate import plan


ROOT = Path(__file__).resolve().parents[2]


class DocumentationRoutingTest(unittest.TestCase):
    def test_paths_select_checks(self):
        cases = [
            (["CLAUDE.md", "CONTRIBUTING.md", "SETUP.md", "contributing/docs.md",
              "standards/new-guide.md", "scripts/ci/README.md"], True, False, False, False),
            (["README.md"], True, True, False, True),
            (["decisions/0001-template.md", "decisions/index.md"], True, False, False, False),
            (["docs/index.md", "decisions/index.md"], True, True, False, True),
            (["CHANGELOG.md"], True, True, False, True),
            (["docs/nav.yml", "docs/images/primitives.svg"], True, True, False, True),
            (["CONTRIBUTING.md", "docs/index.md"], True, True, False, True),
            (["docs/cli/commands.md"], True, True, True, True),
            (["docs/sdk.md"], True, True, False, True),
            (["sdk/typescript/README.md"], True, False, False, False),
            (["site/lib/site/pages.ex", "site/k8s/ingressroute.yaml", "site/mix.lock"], True, False, False, True),
            (["site/README.md", "docs/self-hosting.md"], True, True, False, True),
            (["apps/fountain/lib/fountain/agents.ex"], False, False, False, False),
            ([".tool-versions"], False, False, False, True),
            ([".github/workflows/ci.yml"], False, False, False, True),
            ([".github/workflows/site.yml"], False, False, False, True),
            (["apps/fountain/lib/fountain/agents.ex", "site/lib/site/pages.ex"], False, False, False, True),
        ]
        for paths, short, manual, cli, site in cases:
            with self.subTest(paths=paths):
                flags = classify_docs(paths)
                self.assertEqual(flags, {"docs_only": short, "manual_docs": manual, "cli_docs": cli,
                                         "site": site})
                for event in ("pull_request",):
                    needs = plan(event, docs=short, manual=manual, site=site, cli=cli)
                    validate(event, needs)
                    self.assertEqual(needs["docs"]["result"], "success" if short and cli else "skipped")
                    self.assertEqual(needs["site"]["result"], "success" if site else "skipped")
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
            "apps/new_app/lib/new_app.ex", "apps/new_app/docs/page.md", "contributing/tool.py", "standards/check.sh",
            "config/test.exs", "mix.exs", "mix.lock", "Dockerfile",
            "decisions/evidence/measurement.json", "decisions/check.py",
            "deploy/k8s/prometheusrule.yaml", "deploy/grafana/fountain-ops.json",
            "scripts/test-alerts.py", "scripts/decisions-index.sh", "scripts/test-docs.sh", ".github/workflows/ci.yml",
            "sdk/typescript/src/client.ts", "sdk/contract/README.md", "new-directory/guide.md",
            ".github/workflows/site.yml", "sites/page.ex",
        ):
            with self.subTest(path=path):
                self.assertFalse(classify_docs(["CONTRIBUTING.md", "docs/cli.md", path])["docs_only"])

    def test_malformed_paths_and_empty_diffs_require_full_validation(self):
        for paths in ([], [""], ["/docs/index.md"], ["docs/../mix.exs"],
                      ["docs//index.md"], ["docs/./index.md"], ["docs/file\ndocs_only=true"]):
            with self.subTest(paths=paths):
                self.assertFalse(classify_docs(paths)["docs_only"])
                self.assertTrue(classify_docs(paths)["site"])

    def test_cli_reference_checks_cannot_be_hidden_by_contributor_classification(self):
        needs = plan("pull_request", docs=True, manual=False)
        needs["changes"]["outputs"]["cli_docs"] = "true"
        with self.assertRaisesRegex(ValueError, "CLI documentation requires manual checks"):
            validate("pull_request", needs)

    def test_malformed_documentation_flags_fail_the_gate(self):
        for key in ("docs_only", "manual_docs", "cli_docs", "site"):
            for value in (None, "", "TRUE", True, False, 0, [], {}):
                with self.subTest(key=key, value=value):
                    needs = plan("pull_request", docs=True, manual=False)
                    needs["changes"]["outputs"][key] = value
                    with self.assertRaises(ValueError):
                        validate("pull_request", needs)

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

    def test_workflow_classifies_actual_pr_bases(self):
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
            for path, short, manual, site in (("CONTRIBUTING.md", True, False, False),
                                              ("docs/cli.md", True, True, True),
                                              ("decisions/0002-choice.md", True, False, False),
                                              ("CHANGELOG.md", True, True, True),
                                              ("sdk/typescript/README.md", True, False, False),
                                              ("site/lib/site.ex", True, False, True),
                                              ("config/runtime.exs", False, False, False)):
                base = git("rev-parse", "HEAD")
                git("branch", "-f", "main", base)
                target = root / path
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text("fixture\n")
                commit()
                with self.subTest(path=path):
                    output.write_text("")
                    result = subprocess.run(["bash", "-e", "-c", script], cwd=root,
                                            capture_output=True, text=True,
                                            env=dict(os.environ, GITHUB_EVENT_NAME="pull_request",
                                                     GITHUB_OUTPUT=str(output), GITHUB_BASE_REF="main"))
                    self.assertEqual(result.returncode, 0, result.stderr)
                    values = dict(line.split("=", 1) for line in output.read_text().splitlines())
                    self.assertEqual(values["diff_base"], base)
                    self.assertEqual(values["docs_only"], str(short).lower())
                    self.assertEqual(values["manual_docs"], str(manual).lower())
                    self.assertEqual(values["site"], str(site).lower())


class SiteJobTest(unittest.TestCase):
    def test_site_job_is_selected_by_the_classifier(self):
        workflow = (ROOT / ".github/workflows/ci.yml").read_text()
        changes = workflow.split("\n  changes:\n", 1)[1].split("\n  test:\n", 1)[0]
        self.assertIn("      site: ${{ steps.filter.outputs.site }}\n", changes)
        job = workflow.split("\n  site:\n", 1)[1].split("\n  site-publish:\n", 1)[0]
        self.assertIn("    needs: changes\n", job)
        # `!= 'false'`: an empty output (push, a failed classifier) runs it.
        self.assertIn("    if: ${{ !cancelled() && needs.changes.outputs.site != 'false' }}\n", job)
        for command in ("mix format --check-formatted", "mix compile --warnings-as-errors",
                        "mix test", "mix site.build", "nginx -t", "kubectl kustomize k8s"):
            self.assertIn(command, job)


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
        for name in ("Reject conflict markers", "Test CI decisions"):
            step = job.split(f"      - name: {name}\n", 1)[1].split("      - ", 1)[0]
            self.assertNotIn("        if:", step)

    def test_docs_job_is_cli_parity_on_docs_only_plans(self):
        workflow = (ROOT / ".github/workflows/ci.yml").read_text()
        job = workflow.split("\n  docs:\n", 1)[1].split("\n  workflow-checks:\n", 1)[0]
        self.assertIn("needs: changes", job)
        for condition in ("needs.changes.outputs.docs_only == 'true'",
                          "needs.changes.outputs.cli_docs == 'true'"):
            self.assertIn(condition, job)
        self.assertIn("go test -count=1 ./internal/cmd -run", job)
        # The manual itself is the site job's; nothing here compiles the
        # server or starts a database (decisions/0081).
        for gone in ("mix ", "postgres", "PG_IMAGE"):
            self.assertNotIn(gone, job)

    def test_every_manual_change_selects_the_site_job(self):
        for path in ("README.md", "CHANGELOG.md", "docs/index.md", "docs/cli.md",
                     "apps/fountain/priv/first_request/first-request.sh",
                     "sdk/typescript/examples/pull-request.ts", "deploy/k8s/prometheusrule.yaml"):
            with self.subTest(path=path):
                self.assertTrue(classify_docs([path])["site"])
        self.assertFalse(classify_docs(["apps/fountain/priv/first_request.ex"])["site"])

    def test_site_publishes_what_it_renders(self):
        workflow = (ROOT / ".github/workflows/ci.yml").read_text()
        job = workflow.split("\n  site:\n", 1)[1].split("\n  site-publish:\n", 1)[0]
        diff = job.split('git diff --quiet "${BEFORE}" HEAD --', 1)[1].split("; then", 1)[0]
        for path in ("site", "docs", "CHANGELOG.md", "apps/fountain/priv/first_request",
                     "sdk/typescript/examples", ".tool-versions", ".github/workflows/site.yml"):
            self.assertRegex(diff, rf"(^|\s){re.escape(path)}(\s|$)", path)
