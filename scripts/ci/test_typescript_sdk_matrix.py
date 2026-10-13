import json
from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[2]


class TypeScriptSDKMatrixTest(unittest.TestCase):
    def test_minimum_runtime_uses_compiled_tests_and_current_keeps_native_typescript(self):
        package = json.loads((ROOT / "sdk/typescript/package.json").read_text())
        minimum = package["engines"]["node"].removeprefix(">=")
        workflow = (ROOT / ".github/workflows/ci.yml").read_text()
        job = workflow.split("\n  typescript-sdk:\n", 1)[1].split("\n  cli-plugins:\n", 1)[0]
        versions = re.findall(r'"([0-9.]+)"', re.search(r"        node: \[(.*)\]", job)[1])
        self.assertIn(minimum + ".0", versions)
        self.assertIn("24", versions)
        self.assertIn("fail-fast: false", job)
        self.assertIn("node-version: ${{ matrix.node }}", job)
        steps = dict(re.findall(r"      - name: ([^\n]+)\n(.*?)(?=      - (?:name:|uses:)|\Z)", job, re.S))
        self.assertIn("if: ${{ matrix.node == '24' }}", steps["SDK tests"])
        self.assertIn("run: npm test", steps["SDK tests"])
        minimum_tests = steps["SDK tests on the minimum runtime"]
        self.assertIn("if: ${{ matrix.node == '" + minimum + ".0' }}", minimum_tests)
        self.assertIn("run: node scripts/test-compiled.mjs", minimum_tests)
        self.assertIn("run: node scripts/verify-package.mjs", steps["SDK packed artifact"])
        for name in ("SDK install", "SDK typecheck", "SDK build", "SDK bundles for the browser", "SDK packed artifact", "TypeScript SDK contract"):
            self.assertNotIn("        if:", steps[name])
