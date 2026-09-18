"""The shared conformance suite, run against this client."""

from __future__ import annotations

import json
import os
import socket
import sys
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any, Dict, List, Mapping, Optional
from unittest.mock import patch
from urllib.parse import parse_qsl, urlparse

sys.path.insert(0, str(Path(__file__).parents[1] / "src"))

from fountain import (  # noqa: E402
    AuthError,
    ConnectionError,
    ConversationBusyError,
    Fountain,
    FountainError,
    NotFoundError,
    NotReadyError,
    QuotaExceededError,
    RateLimitError,
    ResolutionError,
    InsufficientCreditsError,
    TimeoutError,
    ValidationError,
)


SDK = "python"
CONFORMANCE = Path(__file__).resolve().parents[2] / "conformance"


def _deep_subset(expected: Any, actual: Any) -> bool:
    if isinstance(expected, list):
        return (
            isinstance(actual, list)
            and len(expected) == len(actual)
            and all(
                _deep_subset(item, actual[index])
                for index, item in enumerate(expected)
            )
        )
    if isinstance(expected, dict):
        return isinstance(actual, dict) and all(
            key in actual and _deep_subset(value, actual[key])
            for key, value in expected.items()
        )
    return expected == actual


def _subset(expected: Mapping[str, Any], actual: Mapping[str, Any]) -> bool:
    return all(
        key in actual and _deep_subset(value, actual[key])
        for key, value in expected.items()
    )


def _safe_json(raw: str) -> Any:
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        return raw


class _ScenarioServer(ThreadingHTTPServer):
    daemon_threads = True


class ScriptedServer:
    """Serve one scenario's exchanges over a real loopback socket."""

    def __init__(self, exchanges: List[Dict[str, Any]]) -> None:
        self.exchanges = exchanges
        self.consumed = [False for _ in exchanges]
        self.requests: List[Dict[str, Any]] = []
        self.unmatched: List[Dict[str, Any]] = []
        self._lock = threading.Lock()
        self._server: Optional[_ScenarioServer] = None
        self._thread: Optional[threading.Thread] = None

    def start(self) -> str:
        owner = self

        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, *args: Any) -> None:
                pass

            def do_GET(self) -> None:
                owner._handle(self)

            def do_POST(self) -> None:
                owner._handle(self)

            def do_PATCH(self) -> None:
                owner._handle(self)

            def do_DELETE(self) -> None:
                owner._handle(self)

        self._server = _ScenarioServer(("127.0.0.1", 0), Handler)
        self._thread = threading.Thread(
            target=self._server.serve_forever,
            kwargs={"poll_interval": 0.01},
            name="fountain-conformance-server",
            daemon=True,
        )
        self._thread.start()
        host, port = self._server.server_address[:2]
        return "http://%s:%s" % (host, port)

    def stop(self) -> None:
        if self._server is None:
            return
        self._server.shutdown()
        self._server.server_close()
        if self._thread is not None:
            self._thread.join()
        self._server = None
        self._thread = None

    def _pick(self, recorded: Dict[str, Any]) -> Optional[Dict[str, Any]]:
        for index, exchange in enumerate(self.exchanges):
            if self.consumed[index]:
                continue
            match = exchange["match"]
            if match["method"].upper() != recorded["method"]:
                continue
            if match["path"] != recorded["path"]:
                continue
            if not _subset(match.get("query", {}), recorded["query"]):
                continue
            if not _subset(match.get("headers", {}), recorded["headers"]):
                continue
            self.consumed[index] = True
            return exchange
        return None

    def _handle(self, handler: BaseHTTPRequestHandler) -> None:
        parsed = urlparse(handler.path)
        length = int(handler.headers.get("Content-Length", "0"))
        raw = handler.rfile.read(length).decode("utf-8", errors="replace")
        headers = {
            name.lower(): ",".join(handler.headers.get_all(name, []))
            for name in handler.headers.keys()
        }
        recorded = {
            "method": handler.command.upper(),
            "path": parsed.path,
            "query": dict(parse_qsl(parsed.query, keep_blank_values=True)),
            "headers": headers,
            "body": None if raw == "" else _safe_json(raw),
        }
        with self._lock:
            self.requests.append(recorded)
            exchange = self._pick(recorded)
            if exchange is None:
                self.unmatched.append(recorded)

        if exchange is None:
            self._whole(
                handler,
                {
                    "status": 599,
                    "json": {"error": "conformance_unmatched_request"},
                },
            )
            return

        response = exchange["respond"]
        if "sse" in response:
            self._stream(handler, response)
        else:
            self._whole(handler, response)

    @staticmethod
    def _whole(handler: BaseHTTPRequestHandler, response: Dict[str, Any]) -> None:
        headers = dict(response.get("headers", {}))
        payload: Optional[bytes] = None
        if "json" in response:
            payload = json.dumps(
                response["json"], separators=(",", ":")
            ).encode("utf-8")
            if not any(name.lower() == "content-type" for name in headers):
                headers["content-type"] = "application/json"
        elif "body" in response:
            payload = response["body"].encode("utf-8")

        handler.send_response(response["status"])
        for name, value in headers.items():
            handler.send_header(name, str(value))
        if not any(name.lower() == "content-length" for name in headers):
            handler.send_header("Content-Length", str(len(payload or b"")))
        handler.end_headers()
        if payload:
            try:
                handler.wfile.write(payload)
                handler.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                pass

    @staticmethod
    def _stream(handler: BaseHTTPRequestHandler, response: Dict[str, Any]) -> None:
        chunks = response.get("sse", [])
        abort = response.get("close") == "abort"
        headers = {
            "cache-control": "no-cache",
            "connection": "keep-alive",
            **response.get("headers", {}),
        }
        content_length = sum(
            len((chunk if isinstance(chunk, str) else chunk["text"]).encode("utf-8"))
            for chunk in chunks
        ) + (1 if abort else 0)
        handler.send_response(response["status"])
        for name, value in headers.items():
            handler.send_header(name, str(value))
        if not any(name.lower() == "content-length" for name in headers):
            handler.send_header("Content-Length", str(content_length))
        handler.end_headers()

        try:
            for chunk in chunks:
                delay_ms = 0 if isinstance(chunk, str) else chunk.get("delay_ms", 0)
                if delay_ms:
                    time.sleep(delay_ms / 1000.0)
                raw = (chunk if isinstance(chunk, str) else chunk["text"]).encode(
                    "utf-8"
                )
                handler.wfile.write(raw)
                handler.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            return

        if abort:
            handler.close_connection = True
            try:
                handler.connection.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            handler.connection.close()


ERROR_KINDS = [
    (ConversationBusyError, "busy"),
    (InsufficientCreditsError, "insufficient_credits"),
    (QuotaExceededError, "quota"),
    (NotReadyError, "not_ready"),
    (RateLimitError, "rate_limited"),
    (ValidationError, "validation"),
    (NotFoundError, "not_found"),
    (AuthError, "auth"),
    (TimeoutError, "timeout"),
    (ConnectionError, "connection"),
    (ResolutionError, "resolution"),
    (FountainError, "server"),
]


def _normalise_error(error: BaseException) -> Dict[str, Any]:
    kind = next(
        (label for error_type, label in ERROR_KINDS if isinstance(error, error_type)),
        "unknown",
    )
    output: Dict[str, Any] = {"kind": kind}
    if isinstance(error, FountainError):
        output.update(
            {
                "status": error.status,
                "code": error.code,
                "retryable": error.retryable,
                "retry_after": error.retry_after,
                "field_errors": error.field_errors,
                "upgrade_url": getattr(error, "upgrade_url", None),
            }
        )
    if isinstance(error, TimeoutError):
        output["partial_text"] = error.partial_text
    if kind == "unknown":
        output["message"] = str(error)
    return output


def _normalise_event(event: Dict[str, Any]) -> Dict[str, Any]:
    event_type = event.get("type")
    if event_type == "conversation":
        return {
            "type": "conversation",
            "conversation_id": event.get("conversation_id"),
        }
    if event_type == "turn-start":
        return {
            "type": "turn-start",
            "turn_number": event.get("turn_number"),
            "turn_id": event.get("turn_id"),
        }
    if event_type in ("text", "thinking"):
        return {"type": event_type, "text": event.get("text")}
    if event_type == "tool":
        return {"type": "tool", "name": event.get("name")}
    if event_type == "permission":
        request = event.get("request", {})
        return {
            "type": "permission",
            "request_id": request.get("request_id"),
            "options": [
                option.get("option_id")
                for option in request.get("options", [])
                if isinstance(option, dict)
            ],
        }
    if event_type == "turn-end":
        return {
            "type": "turn-end",
            "state": event.get("state"),
            "exit_code": event.get("exit_code"),
            "reason": event.get("reason"),
        }
    return {"type": event_type}


def _normalise_result(result: Any) -> Dict[str, Any]:
    return {
        "state": result.state,
        "text": result.text,
        "tools_used": result.tools_used,
        "turn_number": result.turn_number,
        "exit_code": result.exit_code,
        "reason": result.reason,
        "conversation_id": result.conversation_id,
        "status": result.status,
    }


def _drive(scenario: Dict[str, Any], base_url: str) -> Dict[str, Any]:
    config = scenario["client"]
    environment = {
        "FOUNTAIN_API_KEY": "",
        "FOUNTAIN_TOKEN": "",
        "FOUNTAIN_CREDENTIALS_FILE": os.devnull,
    }
    with patch.dict(os.environ, environment):
        client = Fountain(
            api_key=config.get("api_key"),
            base_url=base_url + config.get("base_url_suffix", ""),
            timeout=config.get("timeout_ms", 5000) / 1000.0,
        )

    output: Dict[str, Any] = {}
    for step in scenario["steps"]:
        operation = step["op"]
        if operation == "me":
            output["value"] = client.me()
        elif operation == "list":
            output["value"] = getattr(client, step["resource"]).list()
        elif operation == "create_agent":
            output["value"] = client.agents.create(step["attrs"])
        elif operation == "get_conversation":
            output["value"] = client.resume(step["conversation_id"]).get()
        elif operation == "history":
            output["event_ids"] = [
                int(event["id"])
                for event in client.resume(step["conversation_id"]).history()
            ]
        elif operation == "send":
            run = client.resume(step["conversation_id"]).send(step["prompt"])
            output["result"] = _normalise_result(run.result())
        elif operation == "run":
            options: Dict[str, Any] = {"agent": step["agent"]}
            for key in ("channel_id", "client_request_id"):
                if key in step:
                    options[key] = step[key]
            if step.get("timeout_ms") is not None:
                options["timeout"] = step["timeout_ms"] / 1000.0
            run = client.run(step["prompt"], **options)
            events: List[Dict[str, Any]] = []
            output["events"] = events
            answers = step.get("answer_permissions", {})
            for event in run:
                events.append(_normalise_event(event))
                if event.get("type") == "permission":
                    request_id = event["request"]["request_id"]
                    option_id = answers.get(request_id, answers.get("*"))
                    if option_id:
                        run.answer(request_id, option_id)
            output["result"] = _normalise_result(run.result())
        else:
            raise RuntimeError("conformance: this adapter has no op %s" % operation)
    return output


def _show(value: Any) -> str:
    return json.dumps(value, indent=2, sort_keys=True)


def _check(scenario: Dict[str, Any], observed: Dict[str, Any]) -> List[str]:
    problems: List[str] = []
    expect = scenario["expect"]

    def fail(what: str, detail: str) -> None:
        problems.append("%s\n      %s" % (what, detail))

    for request in observed["unmatched"]:
        fail(
            "unmatched request",
            "the client sent %s %s, which no exchange in the scenario anticipated. "
            "Either the client should not have sent it, or the scenario needs it."
            % (request["method"], request["path"]),
        )

    if "error" in expect:
        if observed["error"] is None:
            fail("error", "expected %s but the call succeeded" % _show(expect["error"]))
        elif not _subset(expect["error"], observed["error"]):
            fail(
                "error",
                "expected %s\n      got %s"
                % (_show(expect["error"]), _show(observed["error"])),
            )
    elif observed["error"] is not None:
        fail(
            "error",
            "the call was not supposed to fail, and raised %s"
            % _show(observed["error"]),
        )

    if "requests" in expect:
        wanted = expect["requests"]
        if expect.get("requests_exactly") and len(observed["requests"]) != len(wanted):
            fail(
                "requests",
                "expected exactly %s request(s), saw %s: %s"
                % (
                    len(wanted),
                    len(observed["requests"]),
                    ", ".join(
                        "%s %s" % (request["method"], request["path"])
                        for request in observed["requests"]
                    ),
                ),
            )
        for index, want in enumerate(wanted):
            if index >= len(observed["requests"]):
                fail(
                    "requests[%s]" % index,
                    "expected %s %s, saw nothing" % (want["method"], want["path"]),
                )
                continue
            got = observed["requests"][index]
            if want["method"] != got["method"] or want["path"] != got["path"]:
                fail(
                    "requests[%s]" % index,
                    "expected %s %s, saw %s %s"
                    % (want["method"], want["path"], got["method"], got["path"]),
                )
                continue
            if "query" in want and not _subset(want["query"], got["query"]):
                fail(
                    "requests[%s].query" % index,
                    "expected %s\n      got %s"
                    % (_show(want["query"]), _show(got["query"])),
                )
            if "headers" in want and not _subset(want["headers"], got["headers"]):
                fail(
                    "requests[%s].headers" % index,
                    "expected %s\n      got %s"
                    % (_show(want["headers"]), _show(got["headers"])),
                )
            for header, prefix in want.get("header_prefixes", {}).items():
                value = got["headers"].get(header, "")
                if not value.startswith(str(prefix)):
                    fail(
                        "requests[%s].headers.%s" % (index, header),
                        "expected it to start with %s, got %s"
                        % (_show(prefix), _show(value)),
                    )
            for header in want.get("headers_absent", []):
                if header in got["headers"]:
                    fail(
                        "requests[%s].headers.%s" % (index, header),
                        "expected no such header, got %s"
                        % _show(got["headers"][header]),
                    )
            if want.get("body") and not _deep_subset(want["body"], got["body"]):
                fail(
                    "requests[%s].body" % index,
                    "expected %s\n      got %s"
                    % (_show(want["body"]), _show(got["body"])),
                )

    if "events" in expect:
        cursor = 0
        for want in expect["events"]:
            found = next(
                (
                    index
                    for index in range(cursor, len(observed["events"]))
                    if _subset(want, observed["events"][index])
                ),
                None,
            )
            if found is None:
                fail(
                    "events",
                    "expected %s after index %s, and the run emitted:\n      %s"
                    % (_show(want), cursor, _show(observed["events"])),
                )
                break
            cursor = found + 1

    if "result" in expect:
        if observed["result"] is None:
            fail("result", "expected %s but there was no result" % _show(expect["result"]))
        elif not _subset(expect["result"], observed["result"]):
            fail(
                "result",
                "expected %s\n      got %s"
                % (_show(expect["result"]), _show(observed["result"])),
            )

    if "value" in expect and not _deep_subset(expect["value"], observed["value"]):
        fail(
            "value",
            "expected %s\n      got %s"
            % (_show(expect["value"]), _show(observed["value"])),
        )

    if "event_ids" in expect and not _deep_subset(
        expect["event_ids"], observed["event_ids"]
    ):
        fail(
            "event_ids",
            "expected %s\n      got %s"
            % (_show(expect["event_ids"]), _show(observed["event_ids"])),
        )

    return problems


class ConformanceTests(unittest.TestCase):
    """Run every shared scenario against the public Python client."""


def _run_scenario(test_case: unittest.TestCase, scenario: Dict[str, Any]) -> None:
    server = ScriptedServer(scenario["http"])
    base_url = server.start()
    observed = {
        "requests": server.requests,
        "unmatched": server.unmatched,
        "events": [],
        "result": None,
        "error": None,
        "value": None,
        "event_ids": None,
    }
    try:
        observed.update(_drive(scenario, base_url))
    except BaseException as error:
        observed["error"] = _normalise_error(error)
    finally:
        server.stop()

    problems = _check(scenario, observed)
    if problems:
        message = (
            "conformance FAILED for %s / %s\n  %s\n\n%s"
            % (
                SDK,
                scenario["name"],
                scenario["title"],
                "\n\n".join("  " + problem for problem in problems),
            )
        )
        test_case.fail(message)


with (CONFORMANCE / "matrix.json").open(encoding="utf-8") as matrix_file:
    MATRIX = json.load(matrix_file)["scenarios"]

for scenario_file in sorted((CONFORMANCE / "scenarios").glob("*.json")):
    with scenario_file.open(encoding="utf-8") as source:
        scenario = json.load(source)

    def test(self: unittest.TestCase, item: Dict[str, Any] = scenario) -> None:
        _run_scenario(self, item)

    test.__name__ = "test_%s" % scenario["name"].replace("-", "_")
    test.__doc__ = scenario["title"]
    verdict = MATRIX[scenario["name"]][SDK]
    if verdict != "yes":
        test = unittest.skip("#%s: %s" % (verdict["issue"], verdict["skip"]))(test)
    setattr(ConformanceTests, test.__name__, test)


if __name__ == "__main__":
    unittest.main()
