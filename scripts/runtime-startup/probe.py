#!/usr/bin/env python3
"""Bounded, offline Node startup comparison for Fountain issue #2402."""

import argparse
import concurrent.futures
import datetime
import json
import os
from pathlib import Path
import platform
import resource
import signal
import subprocess
import threading
import time


def launch(argv, directory, path, timeout, barrier):
    """Use an empty home and allowlisted environment; never read credentials."""
    directory.mkdir()
    env = {
        "PATH": path,
        "HOME": str(directory),
        "TMPDIR": str(directory),
        "LANG": "C.UTF-8",
    }
    barrier.wait(timeout=5)
    started = time.monotonic()
    result = {"argv": argv, "directory": str(directory)}
    try:
        child = subprocess.Popen(
            argv, cwd=directory, env=env, stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True,
        )
    except OSError as error:
        return {**result, "spawn_error": str(error), "failed": True}

    timed_out = False
    try:
        stdout, stderr = child.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        timed_out = True
        # A shim may still have children holding its pipes open.
        try:
            os.killpg(child.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        stdout, stderr = child.communicate()

    # Linux may add .<pid> when core_uses_pid is enabled. A fresh directory
    # distinguishes a helper's new core from an artifact of an earlier run.
    cores = sorted(str(p) for p in directory.glob("core*") if p.is_file())
    return {
        **result,
        "pid": child.pid,
        "returncode": child.returncode,
        "signal": signal.Signals(-child.returncode).name if child.returncode < 0 else None,
        "timed_out": timed_out,
        "stdout": stdout.decode(errors="replace"),
        "stderr": stderr.decode(errors="replace"),
        "cores": cores,
        "elapsed_seconds": round(time.monotonic() - started, 3),
        "failed": timed_out or child.returncode != 0 or bool(cores),
    }


def batch(argv, output, path, timeout, workers, label):
    barrier = threading.Barrier(workers)
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:
        futures = [
            pool.submit(launch, argv, output / f"{label}-{i}", path, timeout, barrier)
            for i in range(workers)
        ]
        return [future.result() for future in futures]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--node", required=True, type=Path, help="actual Node executable")
    parser.add_argument("--shim", type=Path, default=Path("/.sprite/bin/node"))
    parser.add_argument("--adapter", type=Path, help="optional ACP dist/index.js; runs --version only")
    parser.add_argument("--output", required=True, type=Path, help="new artifact directory")
    parser.add_argument("--rounds", type=int, default=10, choices=range(1, 21), metavar="1..20")
    parser.add_argument("--workers", type=int, default=6, choices=range(2, 9), metavar="2..8")
    parser.add_argument("--capture-core", action="store_true", help="enable Linux cores in empty homes")
    args = parser.parse_args()

    if platform.system() != "Linux":
        parser.error("run inside the disposable Linux sandbox being investigated")
    for name in ("node", "shim", "adapter"):
        value = getattr(args, name)
        if value is not None:
            value = value.resolve(strict=True)
            if not value.is_file():
                parser.error(f"--{name} must be a file")
            setattr(args, name, value)
    if args.capture_core:
        pattern = Path("/proc/sys/kernel/core_pattern").read_text().strip()
        if pattern not in ("core", "core.%p"):
            parser.error("core capture requires core_pattern=core or core.%p; no sysctls are changed")
    _, hard_limit = resource.getrlimit(resource.RLIMIT_CORE)
    if args.capture_core and hard_limit == 0:
        parser.error("the inherited hard core limit is zero")
    resource.setrlimit(resource.RLIMIT_CORE, (hard_limit if args.capture_core else 0, hard_limit))

    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    path = f"{args.node.parent}:/usr/bin:/bin"
    tail = [str(args.adapter), "--version"] if args.adapter else ["-e", "console.log(process.version)"]
    metadata = {
        "started_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "platform": platform.uname()._asdict(),
        "node": str(args.node), "shim": str(args.shim),
        "adapter": str(args.adapter) if args.adapter else None,
        "rounds": args.rounds, "workers": args.workers,
        "capture_core": args.capture_core,
        "environment_keys": ["PATH", "HOME", "TMPDIR", "LANG"],
    }
    (output / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")
    failed = False
    with (output / "results.jsonl").open("w") as log:
        for name, executable in (("direct", args.node), ("shim", args.shim)):
            # Keep single-process controls separate from concurrent samples.
            schedule = [("control", 1, 3), ("concurrent", args.workers, args.rounds)]
            for phase, workers, rounds in schedule:
                for round_number in range(rounds):
                    label = f"{name}-{phase}-{round_number}"
                    results = batch([str(executable), *tail], output, path, 20, workers, label)
                    for result in results:
                        log.write(json.dumps({"case": name, "phase": phase, "round": round_number, **result}) + "\n")
                    log.flush()
                    failures = sum(r["failed"] for r in results)
                    print(f"{label}: {failures}/{workers} abnormal (including helper cores)", flush=True)
                    if failures:
                        failed = True
                        break
                if failed:
                    break
            if failed:
                break
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
