#!/usr/bin/env python3
"""Probe ingress through a rollout; record sampling bounds, never an invented exact outage."""
import argparse
import datetime
import json
import time
import urllib.error
import urllib.request


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def sample(url, timeout, opener=None):
    started = time.monotonic()
    row = {"started_at": datetime.datetime.now(datetime.timezone.utc).isoformat()}
    try:
        with (opener or urllib.request.build_opener(NoRedirect)).open(url, timeout=timeout) as response:
            row["status"] = response.status
    except urllib.error.HTTPError as error:
        row["status"] = error.code
        error.close()
    except (OSError, urllib.error.URLError) as error:
        row["status"] = None
        row["error"] = type(error).__name__
    row["elapsed_ms"] = round((time.monotonic() - started) * 1000, 3)
    row["at"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
    row["available"] = row["status"] == 200
    return row


def summarize(rows):
    outages = []
    last_success = None
    current = None
    for row in rows:
        if row["available"]:
            if current:
                current["first_success"] = row["at"]
                outages.append(current)
                current = None
            last_success = row["at"]
        else:
            if current is None:
                current = {"last_success": last_success, "first_failure": row["at"], "failed_samples": 0}
            current["last_failure"] = row["at"]
            current["failed_samples"] += 1
    if current:
        current["first_success"] = None
        outages.append(current)
    return {"samples": len(rows), "failed_samples": sum(not r["available"] for r in rows),
            "outages": outages,
            "interpretation": "Sampling brackets only. Availability between observations is unknown; null bounds are censored."}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("url", help="External ingress health URL, without credentials")
    parser.add_argument("--duration", type=float, default=300)
    parser.add_argument("--interval", type=float, default=1)
    parser.add_argument("--timeout", type=float, default=2)
    parser.add_argument("--output", required=True, help="New JSONL file; existing evidence is never overwritten")
    args = parser.parse_args()
    if min(args.duration, args.interval, args.timeout) <= 0:
        parser.error("duration, interval and timeout must be positive")
    rows = []
    deadline = time.monotonic() + args.duration
    with open(args.output, "x", encoding="utf-8") as output:
        try:
            while time.monotonic() < deadline:
                start = time.monotonic()
                row = sample(args.url, args.timeout)
                rows.append(row)
                output.write(json.dumps(row) + "\n")
                output.flush()
                time.sleep(max(0, min(args.interval - (time.monotonic() - start), deadline - time.monotonic())))
        except KeyboardInterrupt:
            pass
    print(json.dumps(summarize(rows), indent=2))


if __name__ == "__main__":
    main()
