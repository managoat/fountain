import importlib.util
from pathlib import Path
import signal
import sys
import tempfile
import threading
import unittest


spec = importlib.util.spec_from_file_location("startup_probe", Path(__file__).with_name("probe.py"))
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)


class StartupProbeTest(unittest.TestCase):
    def run_child(self, code, timeout=2):
        with tempfile.TemporaryDirectory() as root:
            return probe.launch(
                [sys.executable, "-c", code], Path(root) / "sample",
                f"{Path(sys.executable).parent}:/usr/bin:/bin", timeout, threading.Barrier(1),
            )

    def test_preserves_native_signal_and_both_streams(self):
        result = self.run_child(
            "import os,signal,sys; print('out',flush=True); "
            "print('err',file=sys.stderr,flush=True); os.kill(os.getpid(),signal.SIGTERM)"
        )
        self.assertEqual(result["returncode"], -signal.SIGTERM)
        self.assertEqual(result["signal"], "SIGTERM")
        self.assertEqual(result["stdout"], "out\n")
        self.assertEqual(result["stderr"], "err\n")
        self.assertTrue(result["failed"])

    def test_successful_wrapper_cannot_hide_helper_core(self):
        result = self.run_child("from pathlib import Path; Path('core.123').write_bytes(b'fixture')")
        self.assertEqual(result["returncode"], 0)
        self.assertEqual(len(result["cores"]), 1)
        self.assertTrue(result["failed"])

    def test_timeout_kills_descendants_holding_output_pipes(self):
        result = self.run_child(
            "import subprocess,sys; "
            "subprocess.Popen([sys.executable,'-c','import time; time.sleep(60)'])",
            timeout=0.2,
        )
        self.assertTrue(result["timed_out"])
        self.assertTrue(result["failed"])
        self.assertLess(result["elapsed_seconds"], 3)

    def test_does_not_inherit_credentials_or_shared_home(self):
        from unittest.mock import patch
        with patch.dict("os.environ", {"FOUNTAIN_API_KEY": "must-not-inherit"}):
            result = self.run_child(
                "import os; from pathlib import Path; "
                "assert 'FOUNTAIN_API_KEY' not in os.environ; "
                "assert Path.home().resolve() == Path.cwd(); "
                "assert not list(Path.home().iterdir())"
            )
        self.assertFalse(result["failed"], result)


if __name__ == "__main__":
    unittest.main()
