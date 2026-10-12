"""Exercise report filtering and failure propagation without compiler downloads."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "dead-code.sh"


class DeadCodeReportTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for directory in ("scripts", "bin", "apps/fountain", "cli"):
            (self.root / directory).mkdir(parents=True)
        shutil.copy2(SCRIPT, self.root / "scripts/dead-code.sh")
        self.env = {**os.environ, "PATH": f"{self.root / 'bin'}:{os.environ['PATH']}"}

    def tool(self, name, body):
        executable = self.root / "bin" / name
        executable.write_text("#!/usr/bin/env bash\n" + body)
        executable.chmod(0o755)

    def report(self, language):
        return subprocess.run(
            ["bash", str(self.root / "scripts/dead-code.sh"), language],
            env=self.env, capture_output=True, text=True, check=False,
        )

    def test_excludes_same_module_private_advice_but_keeps_dead_code(self):
        # The locked analyzer calls a function with a same-module caller
        # "should be private"; it is live, unlike the other two diagnostics.
        self.tool("mix", """cat <<'REPORT'
Compiling 3 files (.ex)
hint: Example.live/0 should be private (is not used outside defining module)
    lib/example.ex:2

hint: Example.unused/0 is unused
    lib/example.ex:4

hint: Example.recursive/0 is called only recursively
    lib/example.ex:6
REPORT
""")
        result = self.report("elixir")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("Example.live", result.stdout)
        self.assertNotIn("lib/example.ex:2", result.stdout)
        self.assertNotIn("Compiling", result.stdout)
        self.assertIn("hint: Example.unused/0 is unused\n    lib/example.ex:4", result.stdout)
        self.assertIn("hint: Example.recursive/0 is called only recursively\n    lib/example.ex:6", result.stdout)

    def test_success_without_findings_is_success(self):
        self.tool("mix", "echo 'Generated fountain app'\n")
        self.tool("go", "exit 0\n")
        for language in ("elixir", "go", "all"):
            with self.subTest(language=language):
                result = self.report(language)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertNotIn("hint:", result.stdout)
                self.assertNotIn("unreachable func:", result.stdout)

    def test_compile_failure_retains_status_and_both_diagnostic_streams(self):
        self.tool("mix", "echo 'Compilation failed'\necho 'invalid source' >&2\nexit 23\n")
        result = self.report("elixir")
        self.assertEqual(result.returncode, 23)
        self.assertIn("Compilation failed", result.stderr)
        self.assertIn("invalid source", result.stderr)

    def test_go_failure_is_not_a_clean_report(self):
        self.tool("go", """echo 'cannot load packages' >&2
exit 24
""")
        result = self.report("go")
        self.assertEqual(result.returncode, 24)
        self.assertIn("cannot load packages", result.stderr)

    def test_successful_go_report_contains_the_module(self):
        self.tool("go", "echo 'main.go:8:1: unreachable func: unused'\n")
        result = self.report("go")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("### cli", result.stdout)
        self.assertEqual(result.stdout.count("unreachable func: unused"), 1)
