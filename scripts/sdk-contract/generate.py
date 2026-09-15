#!/usr/bin/env python3
"""Regenerate the contract and supported wire models, or check for stale output."""
import argparse
import difflib
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def typescript(check):
    output = ROOT / "sdk/typescript/src/generated/openapi.ts"
    with tempfile.TemporaryDirectory(prefix="fountain-types-") as directory:
        fresh = Path(directory) / "openapi.ts"
        subprocess.run([
            str(ROOT / "sdk/typescript/node_modules/.bin/openapi-typescript"),
            str(ROOT / "dist/openapi.json"), "-o", str(fresh),
        ], cwd=ROOT, check=True)
        generated = fresh.read_text()
    if check:
        old = output.read_text()
        if old != generated:
            sys.stderr.writelines(difflib.unified_diff(
                old.splitlines(True), generated.splitlines(True),
                fromfile=str(output), tofile="regenerated"))
            return 1
    else:
        output.write_text(generated)
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--target", choices=["all", "contract", "typescript", "swift"], default="all")
    parser.add_argument("--skip-export", action="store_true", help="use existing artifacts (split CI jobs)")
    args = parser.parse_args()
    if args.skip_export and args.target == "contract":
        parser.error("--target contract cannot skip its export/check")
    status = 0
    flags = ["--check"] if args.check else []
    if not args.skip_export:
        status |= subprocess.run(["bash", "scripts/sdk-contract/build.sh", *flags], cwd=ROOT).returncode
        if status and not args.check:
            return status
    if args.target in {"all", "typescript"}:
        status |= typescript(args.check)
    if args.target in {"all", "swift"}:
        status |= subprocess.run([sys.executable, "scripts/sdk-contract/generate-swift.py", *flags], cwd=ROOT).returncode
    if status:
        print("Generated wire artifacts are stale or generation failed. Run: mise exec -- python3 scripts/sdk-contract/generate.py", file=sys.stderr)
    return status


if __name__ == "__main__":
    sys.exit(main())
