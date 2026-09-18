#!/usr/bin/env python3
"""Run the offline #2394 runner probe without adding it to the normal Go suite."""

import json
from pathlib import Path
import subprocess
import tempfile


def main():
    root = Path(__file__).resolve().parents[2]
    source = root / "scripts/sandbox-files/runner_exec_probe_test.go"
    destination = root / "cli/internal/runner/files_execution_probe_test.go"
    if destination.exists():
        raise SystemExit(f"refusing to shadow existing file: {destination}")
    with tempfile.TemporaryDirectory(prefix="fountain-2394-overlay-") as directory:
        overlay = Path(directory) / "overlay.json"
        overlay.write_text(json.dumps({"Replace": {str(destination): str(source)}}))
        result = subprocess.run(
            ["go", "test", "-mod=readonly", "-count=1", "-v", "-timeout=20s",
             "-overlay", str(overlay), "-run", "^TestFilesRunnerExecTimeoutProbe$",
             "./internal/runner"],
            cwd=root / "cli", check=False,
        )
        return result.returncode


if __name__ == "__main__":
    raise SystemExit(main())
