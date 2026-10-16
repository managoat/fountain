#!/usr/bin/env python3
"""Small, bounded public-API soak; Python standard library only. See README.md."""

import argparse
import concurrent.futures
import datetime as dt
import json
import math
import os
from pathlib import Path
import signal
import statistics
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid


PROMPT = "Reply only: orange"
STOP = threading.Event()


def utc():
    return dt.datetime.now(dt.timezone.utc).isoformat()


def seconds(value):
    return dt.datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()


class APIError(Exception):
    def __init__(self, status, detail):
        self.status = status
        super().__init__(detail)


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class API:
    def __init__(self, base, key):
        parsed = urllib.parse.urlsplit(base)
        if parsed.scheme not in ("http", "https") or not parsed.netloc or parsed.username:
            raise ValueError("MANAGOAT_BASE_URL must be an http(s) instance URL without credentials")
        if parsed.query or parsed.fragment:
            raise ValueError("MANAGOAT_BASE_URL must not contain a query or fragment")
        self.base, self.key = base.rstrip("/"), key

    def call(self, method, path, body=None, timeout=15):
        request = urllib.request.Request(
            self.base + "/api" + path,
            data=None if body is None else json.dumps(body).encode(),
            headers={"Authorization": "Bearer " + self.key,
                     "Content-Type": "application/json", "User-Agent": "managoat-load-test/1"},
            method=method,
        )
        try:
            # Never forward the API key through a redirect. Do not retry writes:
            # client_request_id correlates a prompt; it is not an idempotency key.
            with urllib.request.build_opener(NoRedirect).open(request, timeout=timeout) as response:
                data = response.read()
                return json.loads(data) if data else {}
        except urllib.error.HTTPError as error:
            detail = error.read(4096).decode(errors="replace").replace(self.key, "[redacted]")
            error.close()
            raise APIError(error.code, detail) from None
        except (OSError, ValueError) as error:
            raise APIError(None, str(error).replace(self.key, "[redacted]")) from None


class Journal:
    def __init__(self, root):
        self.root = root
        self.lock = threading.Lock()

    def write(self, event, **data):
        row = {"at": utc(), "event": event, **data}
        with self.lock:
            with (self.root / "results.jsonl").open("a") as file:
                file.write(json.dumps(row) + "\n")
                file.flush()
                os.fsync(file.fileno())
            if event in ("result", "cleanup_error", "retained", "skipped_busy"):
                print(json.dumps(row), flush=True)

    def rows(self):
        path = self.root / "results.jsonl"
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []


def read_events(api, cid, cursor, timeout):
    query = {"blocks": "true", "limit": 500}
    if cursor is not None:
        query["after"] = cursor
    page = api.call("GET", f"/conversations/{cid}/events?" + urllib.parse.urlencode(query),
                    timeout=timeout)
    next_cursor = page.get("meta", {}).get("next_cursor")
    if page.get("meta", {}).get("has_more") and (next_cursor is None or next_cursor == cursor):
        raise ValueError("event pagination did not advance")
    return page["data"], next_cursor if next_cursor is not None else cursor, page["meta"]["has_more"]


def probe(api, journal, lane, kind, conversation, timeout, poll):
    started = time.monotonic()
    deadline = started + timeout
    request_id = str(uuid.uuid4())
    result = {"lane": lane["name"], "provider": lane["provider"], "runtime": lane["runtime"],
              "model": lane["model"], "agent_id": lane["agent_id"], "kind": kind, "client_request_id": request_id,
              "started_at": utc(), "status": "interrupted", "read_errors": 0}
    cid = conversation["id"] if conversation else None
    cursor = conversation.get("cursor") if conversation else None
    text, first, turn_start, first_server, ended = "", None, None, None, False
    visible, visible_server = None, None
    post_started = False

    def remaining():
        return max(0.01, min(15, deadline - time.monotonic()))

    try:
        if STOP.is_set():
            return conversation, result
        if conversation:
            # Do not consume an old turn's output when resuming a retained run.
            while True:
                _, cursor, more = read_events(api, cid, cursor, remaining())
                if not more:
                    break
                if time.monotonic() >= deadline:
                    raise TimeoutError("event preflight timed out")
            current = api.call("GET", f"/conversations/{cid}", timeout=remaining())["data"]
            sandbox = api.call("GET", "/sandboxes/" + current["sandbox_id"],
                               timeout=remaining())["data"]
            result["sandbox_before"] = sandbox["status"]
            if kind == "cold_resume" and sandbox["status"] != "suspended":
                result["status"] = "skipped_not_suspended"
                return conversation, result
            if current["agent_id"] != lane["agent_id"]:
                raise ValueError("conversation no longer belongs to this probe agent")
            conversation["sandbox_id"] = current["sandbox_id"]
            if kind == "warm" and sandbox["status"] == "suspended":
                result["kind"] = "cold_resume"
        # Preflight reads are outside request latency, but within the operation deadline.
        sent = time.monotonic()
        result["request_at"] = utc()
        body = {"prompt": PROMPT, "client_request_id": request_id}
        post_started = True
        if cid is None:
            body.update(agent_id=lane["agent_id"], title=f"load-test {request_id}")
            created = api.call("POST", "/conversations", body, remaining())["data"]
            cid = created["id"]
            conversation = {"id": cid, "agent_id": lane["agent_id"], "lane": lane,
                            "sandbox_id": created.get("sandbox_id"), "cursor": None}
            journal.write("created", **conversation, client_request_id=request_id)
        else:
            api.call("POST", f"/conversations/{cid}/prompts", body, remaining())
        result["ack_ms"] = round((time.monotonic() - sent) * 1000, 1)
        while time.monotonic() < deadline and not STOP.is_set():
            try:
                events, cursor, more = read_events(api, cid, cursor, remaining())
            except APIError as error:
                result["read_errors"] += 1
                journal.write("read_error", conversation_id=cid, client_request_id=request_id,
                              http_status=error.status, detail=str(error))
                if error.status is not None and error.status < 500:
                    raise
                STOP.wait(min(poll, max(0, deadline - time.monotonic())))
                continue
            for event in events:
                # Preserve stage diagnostics and structured output, not raw ACP init/config.
                journal.write("observation", conversation_id=cid, client_request_id=request_id,
                              data={key: event.get(key) for key in
                                    ("id", "kind", "stage", "state", "ts", "turn_id", "blocks")},
                              detail=event.get("data") if event.get("kind") == "stage" else None)
                if event.get("stage") == "turn" and event.get("state") == "started":
                    turn_start = event["ts"]
                    result["turn_id"] = event.get("turn_id")
                for block in event.get("blocks", []):
                    if visible is None and block.get("kind") in ("text", "thinking", "tool_use", "plan") and block.get("body"):
                        visible = round((time.monotonic() - sent) * 1000, 1)
                        visible_server = event["ts"]
                    if block.get("kind") == "text" and isinstance(block.get("body"), str):
                        text += block["body"]
                        if first is None and block["body"].strip():
                            first = round((time.monotonic() - sent) * 1000, 1)
                            first_server = event["ts"]
                if event.get("kind") == "stage" and event.get("state") == "failed":
                    result.update(status="stage_failed", failed_stage=event.get("stage"),
                                  detail=event.get("data"))
                    ended = True
                if event.get("stage") == "turn" and event.get("state") in ("done", "interrupted"):
                    if not ended:
                        result["status"] = "completed" if event["state"] == "done" else "interrupted"
                    ended = True
            if ended and not more:
                break
            if not more:
                STOP.wait(min(poll, max(0, deadline - time.monotonic())))
        if not ended:
            result["status"] = "interrupted" if STOP.is_set() else "timeout"
        result["request_to_terminal_observed_ms"] = round((time.monotonic() - sent) * 1000, 1)
        result["request_to_first_text_observed_ms"] = first
        result["request_to_first_visible_update_observed_ms"] = visible
        result["text"] = text
        if turn_start and first_server:
            result["turn_to_first_text_server_ms"] = round((seconds(first_server) - seconds(turn_start)) * 1000, 1)
        if turn_start and visible_server:
            result["turn_to_first_visible_update_server_ms"] = round((seconds(visible_server) - seconds(turn_start)) * 1000, 1)
        if result["status"] == "completed" and text.strip() != "orange":
            result["status"] = "unexpected_output"
        if ended:
            try:
                turns = api.call("GET", f"/conversations/{cid}/turns", timeout=remaining())["data"]
                turn = next((t for t in turns if t.get("client_request_id") == request_id), None)
                if turn:
                    result.update(turn_id=turn["id"], usage=turn.get("usage"),
                                  model_selection=turn.get("model_selection"))
            except APIError as error:
                journal.write("metadata_error", conversation_id=cid, detail=str(error))
    except APIError as error:
        result.update(status="http_error" if error.status else "transport_error",
                      http_status=error.status, detail=str(error),
                      write_may_have_succeeded=post_started and (error.status is None or error.status >= 500))
    except (ValueError, KeyError, TimeoutError) as error:
        result.update(status="protocol_error", detail=str(error))
    finally:
        result.update(conversation_id=cid, elapsed_ms=round((time.monotonic() - started) * 1000, 1))
        if conversation:
            conversation["cursor"] = cursor
        journal.write("result", **result)
    return conversation, result


def terminate(api, journal, conversation):
    try:
        current = api.call("GET", "/conversations/" + conversation["id"])["data"]
        if current["agent_id"] != conversation["agent_id"]:
            raise ValueError("cleanup refused: probe agent mismatch")
        api.call("POST", "/conversations/" + conversation["id"] + "/terminate", {})
        journal.write("terminated", id=conversation["id"])
        return True
    except (APIError, ValueError) as error:
        if isinstance(error, APIError) and error.status == 404:
            journal.write("terminated", id=conversation["id"], already_absent=True)
            return True
        journal.write("cleanup_error", id=conversation["id"], detail=str(error))
        return False


def resources(journal):
    conversations, agents, retained = {}, {}, set()
    for row in journal.rows():
        if row["event"] == "agent":
            agents[row["id"]] = row
        elif row["event"] == "created":
            conversations[row["id"]] = row
        elif row["event"] == "retained":
            retained.add(row["id"])
            conversations[row["id"]] = row["conversation"]
        elif row["event"] == "terminated":
            conversations.pop(row["id"], None)
            retained.discard(row["id"])
        elif row["event"] == "agent_deleted":
            agents.pop(row["id"], None)
    return conversations, agents, retained


def cleanup(api, journal, include_retained=False):
    conversations, agents, retained = resources(journal)
    for cid, conversation in conversations.items():
        if include_retained or cid not in retained:
            terminate(api, journal, conversation)
    conversations, _, _ = resources(journal)
    ambiguous_agents = {r.get("agent_id") for r in journal.rows() if r["event"] == "result"
                        and r.get("write_may_have_succeeded") and not r.get("conversation_id")}
    for aid in agents:
        if aid in ambiguous_agents or any(c["agent_id"] == aid for c in conversations.values()):
            continue
        try:
            api.call("DELETE", "/agents/" + aid)
            journal.write("agent_deleted", id=aid)
        except APIError as error:
            if error.status == 404:
                journal.write("agent_deleted", id=aid, already_absent=True)
            else:
                journal.write("cleanup_error", id=aid, detail=str(error))


def summarize(journal):
    groups = {}
    for row in journal.rows():
        if row["event"] != "result":
            continue
        key = "/".join(row[k] for k in ("lane", "kind"))
        group = groups.setdefault(key, {"outcomes": {}, "latencies": {}})
        status = row["status"]
        group["outcomes"][status] = group["outcomes"].get(status, 0) + 1
        if status == "completed":
            for field in ("request_to_first_text_observed_ms", "turn_to_first_text_server_ms",
                          "request_to_first_visible_update_observed_ms",
                          "turn_to_first_visible_update_server_ms", "request_to_terminal_observed_ms"):
                if row.get(field) is not None:
                    group["latencies"].setdefault(field, []).append(row[field])
    for group in groups.values():
        for field, values in group["latencies"].items():
            values.sort()
            group["latencies"][field] = {"n": len(values), "median": statistics.median(values),
                                        "p95": values[math.ceil(.95 * len(values)) - 1],
                                        "max": max(values)}
    conversations, agents, retained = resources(journal)
    rows = journal.rows()
    results = [r for r in rows if r["event"] == "result"]
    report = {"operations": len(results), "completed": sum(r["status"] == "completed" for r in results),
              "groups": groups, "skipped_busy": sum(r.get("count", 0) for r in rows if r["event"] == "skipped_busy"),
              "read_errors": sum(r["event"] == "read_error" for r in rows),
              "retained": [conversations[cid] for cid in sorted(retained)],
              "cleanup_pending": [c for cid, c in conversations.items() if cid not in retained],
              "agents_remaining": list(agents),
              "agent_cleanup_pending": [aid for aid in agents if not any(c["agent_id"] == aid for c in conversations.values())],
              "unresolved_agent_creates": [r["name"] for r in rows if r["event"] == "agent_create_attempt"
                                           and not any(a["event"] == "agent" and a.get("name") == r["name"] for a in rows)],
              "unresolved_launches": [r["client_request_id"] for r in rows if r["event"] == "result"
                                      and r.get("write_may_have_succeeded") and not r.get("conversation_id")]}
    (journal.root / "summary.json").write_text(json.dumps(report, indent=2) + "\n")
    return report


def lane_run(api, journal, lane, args, start):
    conversation, kept, slot = None, False, 0
    end = start + args.duration
    try:
        while start + slot * args.interval < end and not STOP.is_set():
            due = start + slot * args.interval
            missed = min(int(max(0, time.monotonic() - due) // args.interval),
                         max(0, math.ceil((end - due) / args.interval)))
            if missed:
                journal.write("skipped_busy", lane=lane["name"], count=missed)
                slot += missed
                due = start + slot * args.interval
            if due >= end or STOP.wait(max(0, due - time.monotonic())):
                break
            kind = "warm" if conversation else "fresh"
            conversation, result = probe(api, journal, lane, kind, conversation, args.timeout, args.poll)
            if conversation and (kind == "warm" or result["status"] != "completed"):
                if args.keep_idle and not kept and kind == "warm" and result["status"] == "completed":
                    journal.write("retained", id=conversation["id"], conversation=conversation)
                    kept = True
                else:
                    terminate(api, journal, conversation)
                conversation = None
            slot += 1
    finally:
        if conversation:
            terminate(api, journal, conversation)


def load_config(path):
    lanes = json.loads(path.read_text())["lanes"]
    expanded = []
    for lane in lanes:
        if lane["provider"] not in ("sprites", "e2b") or lane["runtime"] not in ("claude", "codex"):
            raise ValueError("example runner supports sprites/e2b and claude/codex")
        copies = lane.get("copies", 1)
        if type(copies) is not int or not 1 <= copies <= 32:
            raise ValueError("copies must be an integer between 1 and 32")
        if not isinstance(lane["model"], str) or not lane["model"]:
            raise ValueError("each lane needs a model")
        for index in range(copies):
            expanded.append({"name": f"{lane['name']}-{index + 1}",
                             **{key: lane[key] for key in ("provider", "runtime", "model")}})
    names = [lane["name"] for lane in expanded]
    if not names or len(names) != len(set(names)) or len(names) > 32:
        raise ValueError("use 1–32 lanes with unique names")
    return expanded


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("run", "resume", "cleanup", "report"))
    parser.add_argument("--output", type=Path, required=True, help="new run directory, or an existing run for other commands")
    parser.add_argument("--config", type=Path, default=Path(__file__).with_name("example.json"))
    parser.add_argument("--duration", type=float, default=3600, help="seconds of scheduled load")
    parser.add_argument("--interval", type=float, default=30, help="seconds between slots per lane")
    parser.add_argument("--timeout", type=float, default=240, help="operation deadline, including provisioning")
    parser.add_argument("--poll", type=float, default=1, help="event poll interval in seconds")
    parser.add_argument("--keep-idle", action="store_true", help="retain one completed conversation per lane for later resume")
    parser.add_argument("--deployment", default="unspecified", help="operator-supplied deployed version/SHA for comparisons")
    parser.add_argument("--include-retained", action="store_true", help="cleanup also terminates saved cold-resume conversations")
    args = parser.parse_args(argv)
    for name in ("duration", "interval", "timeout", "poll"):
        if not math.isfinite(getattr(args, name)) or getattr(args, name) <= 0:
            parser.error(name + " must be positive and finite")
    if args.command == "report":
        print(json.dumps(summarize(Journal(args.output)), indent=2))
        return 0
    base, key = os.environ.get("MANAGOAT_BASE_URL"), os.environ.get("MANAGOAT_API_KEY")
    if not base or not key:
        parser.error("set MANAGOAT_BASE_URL and MANAGOAT_API_KEY explicitly")
    api = API(base, key)
    if args.command == "run":
        lanes = load_config(args.config)
        args.output.mkdir(parents=True, exist_ok=False)
        args.output.chmod(0o700)
        metadata = {"base_url": api.base, "started_at": utc(), "config": lanes,
                    "duration": args.duration, "interval": args.interval,
                    "timeout": args.timeout, "poll": args.poll, "prompt": PROMPT,
                    "deployment": args.deployment}
        (args.output / "run.json").write_text(json.dumps(metadata, indent=2) + "\n")
    else:
        metadata = json.loads((args.output / "run.json").read_text())
        if metadata["base_url"] != api.base:
            parser.error("target differs from saved run; refusing to touch its resources")
    journal = Journal(args.output)
    for sig in (signal.SIGINT, signal.SIGTERM):
        signal.signal(sig, lambda *_: STOP.set())
    try:
        if args.command == "run":
            for lane in lanes:
                if STOP.is_set():
                    break
                name = "load-test-" + str(uuid.uuid4())
                journal.write("agent_create_attempt", name=name, lane=lane)
                agent = api.call("POST", "/agents", {
                    "name": name, "runtime": lane["runtime"],
                    "model": lane["model"], "sandbox_provider": lane["provider"],
                    "system": "Reply with the requested word only. Do not use tools.",
                    "permission_policy": {"default": "auto_deny"},
                })["data"]
                lane["agent_id"] = agent["id"]
                journal.write("agent", id=agent["id"], name=name, lane=lane)
            start = time.monotonic()
            journal.write("started", duration=args.duration, interval=args.interval)
            with concurrent.futures.ThreadPoolExecutor(max_workers=len(lanes)) as pool:
                futures = [pool.submit(lane_run, api, journal, lane, args, start)
                           for lane in lanes if "agent_id" in lane]
                for future in futures:
                    future.result()
        elif args.command == "resume":
            conversations, _, retained = resources(journal)
            for cid in sorted(retained):
                if STOP.is_set():
                    break
                conversation = conversations[cid]
                updated, _ = probe(api, journal, conversation["lane"], "cold_resume",
                                   conversation, args.timeout, args.poll)
                journal.write("retained", id=cid, conversation=updated)
    finally:
        if args.command != "resume":
            cleanup(api, journal, args.command == "cleanup" and args.include_retained)
        report = summarize(journal)
        journal.write("finished", command=args.command, interrupted=STOP.is_set())
    print(f"Report: {args.output / 'summary.json'}")
    failures = any(status not in ("completed", "skipped_not_suspended")
                   for group in report["groups"].values() for status in group["outcomes"])
    return 1 if failures or report["cleanup_pending"] or report["agent_cleanup_pending"] else 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (APIError, ValueError, KeyError, OSError) as error:
        raise SystemExit(str(error))
