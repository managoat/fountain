#!/usr/bin/env python3
"""Regenerate the TypeScript SDK's wire types from the server, or check them.

The server is the only description of the API. `mix openapi.export` renders it
to `dist/openapi.json` (not checked in); this script sorts that document's keys
and runs `openapi-typescript` over it into
`sdk/typescript/src/generated/openapi.ts`, which is checked in.

    generate.py                 export, then write openapi.ts
    generate.py --check         export, then fail if openapi.ts is stale
    generate.py --skip-export   use the dist/openapi.json already on disk
    generate.py --export-only   export and sort dist/openapi.json, nothing else

The export boots the app, so it needs the Elixir toolchain and a migrated
database. Regenerating needs `npm ci` in sdk/typescript.
"""
import argparse
import difflib
import json
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
SPEC = ROOT / "dist/openapi.json"
OUTPUT = ROOT / "sdk/typescript/src/generated/openapi.ts"


def export():
    """Render the spec, then sort its keys.

    open_api_spex encodes maps in Jason's internal order, which is stable by
    accident rather than by contract. Sorting makes the document, and the types
    generated from it, depend on this script alone.
    """
    subprocess.run(["mix", "openapi.export"], cwd=ROOT, check=True, stdout=subprocess.DEVNULL)
    spec = json.loads(SPEC.read_text())
    SPEC.write_text(json.dumps(spec, indent=2, sort_keys=True, ensure_ascii=False) + "\n")


def typescript(check):
    with tempfile.TemporaryDirectory(prefix="fountain-types-") as directory:
        fresh = Path(directory) / "openapi.ts"
        subprocess.run([
            str(ROOT / "sdk/typescript/node_modules/.bin/openapi-typescript"),
            str(SPEC), "-o", str(fresh),
        ], cwd=ROOT, check=True)
        generated = fresh.read_text()
    if not check:
        OUTPUT.write_text(generated)
        return 0
    old = OUTPUT.read_text()
    if old == generated:
        return 0
    sys.stderr.writelines(difflib.unified_diff(
        old.splitlines(True), generated.splitlines(True),
        fromfile=str(OUTPUT.relative_to(ROOT)), tofile="regenerated"))
    print("sdk/typescript/src/generated/openapi.ts is stale. Run: mise exec -- python3 scripts/sdk-contract/generate.py",
          file=sys.stderr)
    return 1


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--skip-export", action="store_true", help="use the dist/openapi.json already on disk")
    mode.add_argument("--export-only", action="store_true", help="export and sort the spec; generate nothing")
    parser.add_argument("--check", action="store_true", help="fail on a diff instead of writing")
    args = parser.parse_args()
    if not args.skip_export:
        export()
    if args.export_only:
        return 0
    if not SPEC.exists():
        parser.error(f"{SPEC.relative_to(ROOT)} does not exist; run without --skip-export")
    return typescript(args.check)


if __name__ == "__main__":
    sys.exit(main())
