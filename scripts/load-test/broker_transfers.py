#!/usr/bin/env python3
"""Measure public download/redirect fixtures without recording URLs or headers."""

import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import re
import subprocess
import tempfile
from urllib.parse import urlsplit


FIELDS = (
    "response_code", "http_connect", "exitcode", "num_redirects", "num_connects",
    "size_download", "time_namelookup", "time_connect", "time_appconnect",
    "time_starttransfer", "time_redirect", "time_total",
)
WRITE_OUT = "{" + ",".join('"' + key + '":"%{' + key + '}"' for key in FIELDS) + "}\\n"


def quote(value):
    """Quote curl config values; reject line injection before spawning curl."""
    if any(ord(c) < 32 or ord(c) == 127 for c in value):
        raise ValueError("control characters are not allowed in configuration")
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def load_cases(path):
    cases = json.loads(Path(path).read_text())
    if not isinstance(cases, list) or not cases:
        raise ValueError("cases must be a nonempty list")
    names = set()
    for case in cases:
        if not isinstance(case, dict) or set(case) != {"name", "url", "sha256"}:
            raise ValueError("each case needs exactly name, url and sha256")
        if not re.fullmatch(r"[a-zA-Z0-9_-]{1,64}", case["name"]) or case["name"] in names:
            raise ValueError("case names must be unique safe labels")
        names.add(case["name"])
        url = urlsplit(case["url"])
        if url.scheme not in {"http", "https"} or not url.hostname or url.username or url.password:
            raise ValueError("fixtures need HTTP(S) URLs without userinfo")
        quote(case["url"])
        if not re.fullmatch(r"[0-9a-f]{64}", case["sha256"]):
            raise ValueError("each fixture requires its expected lowercase SHA-256")
    return cases


def transfer(case, route, count, *, proxy=None, ca=None, timeout=30, max_bytes=200_000_000):
    """One curl process permits connection reuse across count sequential GETs.

    No body, URL, Location, proxy credential, curl stderr, or raw write-out is
    included in the result. Each body is discarded after integrity checking.
    """
    if route not in {"direct", "proxy"} or (route == "proxy" and not proxy):
        raise ValueError("proxy route requires a proxy URL")
    with tempfile.TemporaryDirectory(prefix="broker-transfer-") as directory:
        lines = []
        paths = []
        for index in range(count):
            if index:
                lines.append("next")
            body = Path(directory) / str(index)
            paths.append(body)
            lines += [
                "silent", "location", "max-redirs = 10",
                "proto = \"=http,https\"",
                'proto-redir = "=' + ("https" if case["url"].startswith("https:") else "http,https") + '"',
                "connect-timeout = 10", f"max-time = {timeout}",
                f"max-filesize = {max_bytes}",
                "url = " + quote(case["url"]), "output = " + quote(str(body)),
                "write-out = " + quote(WRITE_OUT),
                "noproxy = " + quote("*" if route == "direct" else ""),
            ]
            if route == "proxy":
                lines.append("proxy = " + quote(proxy))
            if ca:
                lines.append("cacert = " + quote(ca))
        env = {key: value for key, value in os.environ.items() if key.lower() not in {
            "http_proxy", "https_proxy", "all_proxy", "no_proxy",
        }}
        # URLs and proxy authentication travel on stdin, never in process argv.
        try:
            process = subprocess.run(
                ["curl", "-q", "--config", "-"], input="\n".join(lines) + "\n",
                text=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                env=env, timeout=count * timeout + 5, check=False,
            )
        except subprocess.TimeoutExpired:
            return [{"case": case["name"], "route": route, "error": "runner_timeout"}]
        try:
            metrics = [json.loads(line) for line in process.stdout.splitlines()]
            if len(metrics) != count:
                raise ValueError("missing records")
            for row in metrics:
                if set(row) != set(FIELDS):
                    raise ValueError("unexpected metric")
                for key, value in row.items():
                    row[key] = float(value) if key.startswith("time_") else int(value)
                    if not math.isfinite(row[key]) or row[key] < 0:
                        raise ValueError("unexpected metric")
        except (ValueError, TypeError):
            return [{"case": case["name"], "route": route, "error": "invalid_curl_metrics"}]
        results = []
        for index, (row, path) in enumerate(zip(metrics, paths)):
            digest = hashlib.sha256()
            if path.exists():
                with path.open("rb") as body:
                    for chunk in iter(lambda: body.read(1024 * 1024), b""):
                        digest.update(chunk)
            integrity_ok = path.exists() and digest.hexdigest() == case["sha256"]
            results.append({
                "case": case["name"], "route": route,
                "connection_context": "fresh_process" if index == 0 else "reuse_eligible",
                **row, "integrity_ok": integrity_ok,
                "ok": row["exitcode"] == 0 and 200 <= row["response_code"] < 300 and integrity_ok,
            })
        return results


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("cases", help="private JSON file of named URL/hash fixtures")
    parser.add_argument("--route", choices=("direct", "proxy", "both"), default="direct")
    parser.add_argument("--proxy-env", default="BENCHMARK_PROXY_URL")
    parser.add_argument("--cacert", help="CA bundle for the target/MITM certificate")
    parser.add_argument("--rounds", type=int, default=3)
    parser.add_argument("--sequence", type=int, default=2, help="GETs per curl process")
    parser.add_argument("--timeout", type=int, default=30)
    parser.add_argument("--max-bytes", type=int, default=200_000_000)
    args = parser.parse_args()
    if not (1 <= args.rounds <= 100 and 1 <= args.sequence <= 20 and
            1 <= args.timeout <= 300 and 1 <= args.max_bytes <= 1_000_000_000):
        parser.error("rounds, sequence, timeout or max-bytes outside allowed bounds")
    try:
        cases = load_cases(args.cases)
        routes = ["direct", "proxy"] if args.route == "both" else [args.route]
        proxy = os.environ.get(args.proxy_env)
        if "proxy" in routes and not proxy:
            raise ValueError("proxy environment variable is unset")
        failed = False
        for round_index in range(args.rounds):
            # Alternate route order to reduce systematic warm-cache/order bias.
            for route in routes[::1 if round_index % 2 == 0 else -1]:
                for case in cases:
                    for row in transfer(case, route, args.sequence, proxy=proxy, ca=args.cacert,
                                        timeout=args.timeout, max_bytes=args.max_bytes):
                        print(json.dumps({"round": round_index + 1, **row}), flush=True)
                        failed |= not row.get("ok", False)
        return int(failed)
    except (ValueError, TypeError, KeyError, OSError):
        # Exception text may contain a private URL, file content or credential.
        parser.exit(2, "Invalid fixture/configuration or unavailable curl; no sensitive details logged.\n")


if __name__ == "__main__":
    raise SystemExit(main())
