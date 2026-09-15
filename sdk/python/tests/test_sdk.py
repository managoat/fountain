from __future__ import annotations

import asyncio
import json
import re
import sys
import threading
import time
import unittest
from unittest.mock import patch
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

sys.path.insert(0, str(Path(__file__).parents[1] / "src"))

from fountain import (  # noqa: E402
    AuthError,
    Fountain,
    QuotaExceededError,
    ResolutionError,
    TimeoutError,
    parse_credentials,
    resolve_config,
)
import fountain  # noqa: E402
from fountain.http import USER_AGENT  # noqa: E402
from fountain.sse import parse_sse  # noqa: E402
from fountain.turn import TurnFollower  # noqa: E402


AGENT_ID = "11111111-1111-1111-1111-111111111111"
VAULT_ID = "aaaaaaaa-1111-1111-1111-111111111111"
ENVIRONMENT_ID = "bbbbbbbb-1111-1111-1111-111111111111"


class State:
    def __init__(self) -> None:
        self.requests = []
        self.next_event = 1
        self.resume_channel = False
        self.fail = None
        self.events = []
        self.cut_first_stream = False
        self.truncate_first_stream = False
        self.stream_count = 0
        self.stream_failures = 0
        self.stream_failure_status = 502
        self.hang_stream = False
        self.hang_stream_prefix = False
        self.stream_opened = threading.Event()
        self.release_stream = threading.Event()

    def event(self, **values):
        item = {"id": self.next_event, **values}
        self.next_event += 1
        self.events.append(item)

    def script_turn(self, turn_number=1):
        self.event(
            kind="stage",
            stream="stage",
            stage="turn",
            state="started",
            data=json.dumps({"turn_number": turn_number, "turn_id": "turn-%s" % turn_number}),
        )
        self.event(
            kind="output",
            stream="acp",
            turn_id="turn-%s" % turn_number,
            blocks=[{"kind": "tool_use", "name": "Read"}],
        )
        self.event(
            kind="output",
            stream="acp",
            turn_id="turn-%s" % turn_number,
            blocks=[{"kind": "text", "body": "Found "}],
        )
        self.event(
            kind="output",
            stream="acp",
            turn_id="turn-%s" % turn_number,
            blocks=[{"kind": "text", "body": "it."}],
        )
        self.event(
            kind="stage",
            stream="stage",
            stage="turn",
            state="done",
            data=json.dumps(
                {"turn_number": turn_number, "turn_id": "turn-%s" % turn_number, "stop_reason": "end_turn"}
            ),
        )


def _frame(event):
    return (
        "id: %s\nevent: %s\ndata: %s\n\n"
        % (event["id"], event["kind"], json.dumps(event))
    ).encode()


class Handler(BaseHTTPRequestHandler):
    state: State

    def log_message(self, *args):
        pass

    def _json(self, status, value, **headers):
        raw = json.dumps(value).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        for key, value in headers.items():
            self.send_header(key, str(value))
        self.end_headers()
        self.wfile.write(raw)

    def _body(self):
        length = int(self.headers.get("Content-Length", "0"))
        return json.loads(self.rfile.read(length)) if length else None

    def _begin(self):
        parsed = urlparse(self.path)
        body = self._body() if self.command in ("POST", "PATCH") else None
        self.state.requests.append(
            (
                self.command,
                parsed.path,
                parse_qs(parsed.query),
                body,
                dict(self.headers),
            )
        )
        if self.state.fail:
            status, value = self.state.fail
            self.state.fail = None
            self._json(status, value, **{"Retry-After": "3"})
            return parsed, body, False
        return parsed, body, True

    def do_GET(self):
        parsed, _, proceed = self._begin()
        if not proceed:
            return
        if parsed.path == "/api/agents":
            return self._json(
                200,
                {
                    "data": [
                        {"id": AGENT_ID, "name": "reposage"},
                        {"id": "2", "name": "reporter"},
                    ]
                },
            )
        if parsed.path == "/api/vaults":
            return self._json(200, {"data": [{"id": VAULT_ID, "name": "github-bot"}]})
        if parsed.path == "/api/environments":
            return self._json(
                200, {"data": [{"id": ENVIRONMENT_ID, "name": "monorepo"}]}
            )
        if parsed.path == "/api/conversations/c-1":
            return self._json(
                200, {"data": {"id": "c-1", "status": "ready", "turn_count": 1}}
            )
        if parsed.path == "/api/conversations/c-1/turns":
            return self._json(200, {"data": [{"turn_number": 1}]})
        if parsed.path in ("/api/events/stream", "/api/team/stream"):
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if parsed.path == "/api/conversations/c-1/stream":
            self.state.stream_count += 1
            if self.state.stream_failures > 0:
                self.state.stream_failures -= 1
                return self._json(
                    self.state.stream_failure_status, {"error": "bad_gateway"}
                )
            if self.state.hang_stream:
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.end_headers()
                if self.state.hang_stream_prefix:
                    self.wfile.write(_frame(self.state.events[0]))
                    self.wfile.flush()
                self.state.stream_opened.set()
                self.state.release_stream.wait(15)
                return
            after = int(self.headers.get("Last-Event-ID", "0"))
            rows = [event for event in self.state.events if event["id"] > after]
            if self.state.cut_first_stream and self.state.stream_count == 1:
                rows = rows[:2]
            if self.state.truncate_first_stream and self.state.stream_count == 1:
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.end_headers()
                self.wfile.write(_frame(rows[0]))
                # Cut after the id line, before its data lands: the shape a
                # dropped connection leaves in the client's parser.
                return self.wfile.write(
                    (
                        "id: %s\nevent: %s\ndata: " % (rows[1]["id"], rows[1]["kind"])
                    ).encode()
                )
            raw = b"".join(_frame(event) for event in rows)
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Content-Length", str(len(raw)))
            self.end_headers()
            return self.wfile.write(raw)
        return self._json(404, {"error": "not_found"})

    def do_POST(self):
        parsed, body, proceed = self._begin()
        if not proceed:
            return
        if parsed.path == "/api/conversations":
            if body.get("channel_id") and self.state.resume_channel and not body.get("fresh"):
                return self._json(200, {
                    "data": {"id": "c-1", "status": "ready", "turn_count": 1},
                    "meta": {"resumed": True},
                })
            self.state.events = []
            self.state.script_turn()
            return self._json(
                201, {"data": {"id": "c-1", "status": "running", "turn_count": 1}}
            )
        if parsed.path == "/api/conversations/c-1/prompts":
            self.state.script_turn(2)
            return self._json(200, {"status": "queued"})
        if parsed.path == "/api/conversations/c-1/reapply":
            return self._json(200, {"data": {"id": "c-1", **(body or {})}})
        return self._json(404, {"error": "not_found"})


class FakeFountain:
    def __enter__(self):
        self.state = State()
        handler = type("BoundHandler", (Handler,), {"state": self.state})
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        host, port = self.server.server_address[:2]
        self.base_url = "http://%s:%s" % (host, port)
        return self

    def __exit__(self, *args):
        self.state.release_stream.set()
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()


class ConfigTests(unittest.TestCase):
    def test_public_credit_error_replaces_subscription_export(self):
        self.assertIn("InsufficientCreditsError", fountain.__all__)
        self.assertTrue(issubclass(fountain.InsufficientCreditsError, fountain.FountainError))
        self.assertNotIn("SubscriptionRequiredError", fountain.__all__)
        self.assertFalse(hasattr(fountain, "SubscriptionRequiredError"))

    def test_version_tokens_match_package_metadata(self):
        metadata = (Path(__file__).parents[1] / "pyproject.toml").read_text()
        version = re.search(r'^version = "([^"]+)"$', metadata, re.MULTILINE)
        self.assertIsNotNone(version)
        assert version is not None
        self.assertEqual(fountain.__version__, version.group(1))
        self.assertEqual(USER_AGENT, "fountain-sdk-python/%s" % version.group(1))

    def test_credentials_parser_and_precedence(self):
        raw = "[default]\napi_key = 'from-file'\nbase_url = https://file.example/\n[work]\napi_key=x\n"
        self.assertEqual(parse_credentials(raw, "default")["api_key"], "from-file")
        config = resolve_config(
            api_key="explicit",
            app_url="",
            environ={
                "FOUNTAIN_API_KEY": "environment",
                "FOUNTAIN_BASE_URL": "https://env.example/",
            },
        )
        self.assertEqual(config.api_key, "explicit")
        self.assertEqual(config.base_url, "https://env.example")
        self.assertEqual(config.app_url, "")

    def test_sse_parser_handles_crlf_comments_and_multiline_data(self):
        messages = list(
            parse_sse(
                [
                    b": heartbeat\r\n",
                    b"id: 7\r\n",
                    b"event: output\r\n",
                    b"data: one\r\n",
                    b"data: two\r\n",
                    b"\r\n",
                ]
            )
        )
        self.assertEqual(messages, [{"id": "7", "event": "output", "data": "one\ntwo"}])


class TurnTests(unittest.TestCase):
    def test_turn_follower_filters_and_joins(self):
        follower = TurnFollower(2)
        old = {
            "kind": "stage",
            "stage": "turn",
            "state": "started",
            "data": '{"turn_number":1,"turn_id":"old"}',
        }
        self.assertEqual(follower.apply(old), [])
        follower.apply(
            {
                "kind": "stage",
                "stage": "turn",
                "state": "started",
                "data": '{"turn_number":2,"turn_id":"mine"}',
            }
        )
        follower.apply(
            {
                "kind": "output",
                "stream": "acp",
                "turn_id": "mine",
                "blocks": [{"kind": "text", "body": "Reading."}],
            }
        )
        follower.apply(
            {
                "kind": "output",
                "stream": "acp",
                "turn_id": "mine",
                "blocks": [{"kind": "tool_use", "name": "Read"}],
            }
        )
        follower.apply(
            {
                "kind": "output",
                "stream": "acp",
                "turn_id": "mine",
                "blocks": [{"kind": "text", "body": "Done."}],
            }
        )
        self.assertEqual(follower.text, "Reading.\n\nDone.")
        self.assertEqual(follower.tools_used, ["Read"])

    def test_permission_request_is_answerable(self):
        follower = TurnFollower(1)
        follower.apply(
            {
                "kind": "stage",
                "stage": "turn",
                "state": "started",
                "data": '{"turn_number":1,"turn_id":"mine"}',
            }
        )
        output = follower.apply(
            {
                "kind": "output",
                "stream": "acp",
                "turn_id": "mine",
                "blocks": [
                    {
                        "kind": "permission_request",
                        "request_id": "request-1",
                        "summary": "Run a command",
                        "options": [{"optionId": "allow", "kind": "allow_once"}],
                    }
                ],
            }
        )
        permission = next(event for event in output if event["type"] == "permission")
        self.assertEqual(permission["request"]["request_id"], "request-1")
        self.assertEqual(permission["request"]["options"][0]["option_id"], "allow")


class ClientTests(unittest.TestCase):
    def test_run_request_preserves_wire_fields_and_separates_local_options(self):
        with FakeFountain() as fake:
            client = Fountain(base_url=fake.base_url, api_key="fk_test")
            body = {
                "agent_id": AGENT_ID, "prompt": "find it", "title": "",
                "vault_id": None, "images": [], "fresh": False, "queue": False,
                "labels": {"attempt": "0"}, "permission_policy": {"ask_timeout": 0},
                "sandbox_api_access": "none",
            }
            result = client.run_request(body, timeout=1, collect_events=True).result()
            self.assertEqual(result.text, "Found it.")
            create = next(r for r in fake.state.requests if r[:2] == ("POST", "/api/conversations"))
            self.assertEqual(create[3], body)
            self.assertNotIn("environment_id", create[3])
            self.assertFalse(any(r[1] == "/api/agents" for r in fake.state.requests))

    def test_run_request_refuses_unsupported_lifecycles_before_http(self):
        with FakeFountain() as fake:
            client = Fountain(base_url=fake.base_url, api_key="fk_test")
            for prompt in (None, "", "  "):
                with self.assertRaisesRegex(ValueError, "non-empty prompt"):
                    client.run_request({"agent_id": AGENT_ID, "prompt": prompt})
            with self.assertRaisesRegex(ValueError, "queued"):
                client.run_request({"agent_id": AGENT_ID, "prompt": "hi", "queue": True})
            self.assertEqual(fake.state.requests, [])

    def test_run_request_follows_initial_turn_for_new_and_fresh_channels(self):
        for fresh in (False, True):
            with self.subTest(fresh=fresh), FakeFountain() as fake:
                fake.state.resume_channel = fresh
                client = Fountain(base_url=fake.base_url, api_key="fk_test")
                result = client.run_request({
                    "agent_id": AGENT_ID, "prompt": "hi", "channel_id": "raw", "fresh": fresh,
                }, timeout=1).result()
                self.assertEqual(result.turn_number, 1)
                self.assertEqual(result.text, "Found it.")
                self.assertFalse(any(r[1].endswith("/prompts") for r in fake.state.requests))

    def test_run_request_submits_prompt_and_images_to_resumed_channel(self):
        with FakeFountain() as fake:
            fake.state.resume_channel = True
            fake.state.script_turn()
            client = Fountain(base_url=fake.base_url, api_key="fk_test")
            images = [{"data": "aGVsbG8=", "media_type": "image/png"}]
            result = client.run_request({
                "agent_id": AGENT_ID, "prompt": "next", "channel_id": "raw", "images": images,
            }, timeout=1, collect_events=True).result()
            self.assertEqual(result.conversation_id, "c-1")
            self.assertEqual(result.turn_number, 2)
            self.assertEqual(result.text, "Found it.")
            prompts = [r for r in fake.state.requests if r[1].endswith("/prompts")]
            self.assertEqual(len(prompts), 1)
            self.assertEqual(prompts[0][3], {"prompt": "next", "images": images})
            history = next(r for r in fake.state.requests if r[1].endswith("/turns"))
            self.assertLess(fake.state.requests.index(history), fake.state.requests.index(prompts[0]))

    def test_run_sends_explicit_sandbox_api_access_and_omits_the_default(self):
        for access in (None, "none", "owner"):
            with self.subTest(access=access), FakeFountain() as fake:
                client = Fountain(base_url=fake.base_url, api_key="fk_test")
                client.run(
                    "find it", agent="reposage", sandbox_api_access=access
                ).result()
                create = next(
                    request for request in fake.state.requests
                    if request[:2] == ("POST", "/api/conversations")
                )
                if access is None:
                    self.assertNotIn("sandbox_api_access", create[3])
                else:
                    self.assertEqual(create[3]["sandbox_api_access"], access)

    def test_run_resolves_names_streams_and_returns_result(self):
        with FakeFountain() as fake:
            client = Fountain(
                base_url=fake.base_url, api_key="fk_test", app_url="https://app.example"
            )
            run = client.run(
                "find it", agent="reposage", vault="github-bot", environment="monorepo"
            )
            chunks = list(run.text_stream)
            result = run.result()
            self.assertEqual(chunks, ["Found ", "it."])
            self.assertEqual(result.text, "Found it.")
            self.assertEqual(result.tools_used, ["Read"])
            self.assertEqual(result.state, "done")
            self.assertEqual(result.reason, "end_turn")
            self.assertEqual(result.url, "https://app.example/#/c/c-1")
            create = next(
                request
                for request in fake.state.requests
                if request[:2] == ("POST", "/api/conversations")
            )
            self.assertEqual(
                create[3],
                {
                    "agent_id": AGENT_ID,
                    "prompt": "find it",
                    "vault_id": VAULT_ID,
                    "environment_id": ENVIRONMENT_ID,
                },
            )
            self.assertEqual(create[4]["User-Agent"], USER_AGENT)

    # An omitted value keeps a binding and an explicit None clears it, so the
    # two have to stay distinguishable all the way to the wire.
    def test_reapply_sends_only_the_fields_it_was_given(self):
        with FakeFountain() as fake:
            client = fountain.Fountain(api_key="k", base_url=fake.base_url)
            conversation = client.resume("c-1")

            self.assertEqual(conversation.reapply(), {"id": "c-1"})
            self.assertEqual(fake.state.requests[-1][3], {})

            conversation.reapply(agent_id="a-1", vault_id=None)
            self.assertEqual(
                fake.state.requests[-1][3], {"agent_id": "a-1", "vault_id": None}
            )

    def test_resolution_error_lists_available_names(self):
        with FakeFountain() as fake:
            run = Fountain(base_url=fake.base_url, api_key="fk_test").run(
                "hi", agent="missing"
            )
            with self.assertRaisesRegex(ResolutionError, "reporter, reposage"):
                run.result()

    def test_error_classes_use_api_code_and_retry_after(self):
        with FakeFountain() as fake:
            fake.state.fail = (
                429,
                {"error": "sandbox_quota_exceeded", "active_sandboxes": 2, "limit": 2},
            )
            with self.assertRaises(QuotaExceededError) as caught:
                Fountain(base_url=fake.base_url, api_key="fk_test").sandboxes()
            self.assertTrue(caught.exception.retryable)
            self.assertEqual(caught.exception.retry_after, 3)
            self.assertEqual(caught.exception.active_sandboxes, 2)

    def test_stream_reconnects_from_the_last_event(self):
        with FakeFountain() as fake:
            fake.state.cut_first_stream = True
            client = Fountain(base_url=fake.base_url, api_key="fk_test")
            result = client.run("find it", agent="reposage").result()
            self.assertEqual(result.text, "Found it.")
            streams = [
                request
                for request in fake.state.requests
                if request[1].endswith("/stream")
            ]
            self.assertEqual(len(streams), 2)
            self.assertEqual(streams[1][4]["Last-Event-Id"], "2")

    def test_stream_reconnects_through_a_transient_5xx(self):
        with FakeFountain() as fake:
            fake.state.stream_failures = 1
            client = Fountain(base_url=fake.base_url, api_key="fk_test")
            result = client.run("find it", agent="reposage").result()
            self.assertEqual(result.text, "Found it.")
            self.assertEqual(fake.state.stream_count, 2)

    def test_stream_surfaces_a_4xx_instead_of_retrying_it(self):
        with FakeFountain() as fake:
            fake.state.stream_failures = 5
            fake.state.stream_failure_status = 401
            client = Fountain(base_url=fake.base_url, api_key="fk_test")
            with self.assertRaises(AuthError):
                client.run("find it", agent="reposage").result()
            self.assertEqual(fake.state.stream_count, 1)

    def test_a_truncated_final_message_is_replayed_not_skipped(self):
        with FakeFountain() as fake:
            fake.state.truncate_first_stream = True
            client = Fountain(base_url=fake.base_url, api_key="fk_test")
            result = client.run("find it", agent="reposage").result()
            streams = [
                request
                for request in fake.state.requests
                if request[1].endswith("/stream")
            ]
            # Event 2 arrived headless, so the cursor stays on event 1.
            self.assertEqual(streams[1][4]["Last-Event-Id"], "1")
            self.assertEqual(result.tools_used, ["Read"])
            self.assertEqual(result.text, "Found it.")

    def test_blocks_defaults_to_true_and_the_caller_can_turn_it_off(self):
        with FakeFountain() as fake:
            client = Fountain(base_url=fake.base_url, api_key="fk_test")
            list(client.events(wait=False))
            list(client.events(blocks=False, wait=False))
            list(client.team.stream(blocks=False, wait=False))
            queries = [
                request[2]
                for request in fake.state.requests
                if request[1].endswith("/stream")
            ]
            self.assertEqual(queries[0]["blocks"], ["true"])
            self.assertNotIn("blocks", queries[1])
            self.assertNotIn("blocks", queries[2])

    def test_a_finish_callback_registered_from_a_callback_fires_once(self):
        with FakeFountain() as fake:
            client = Fountain(base_url=fake.base_url, api_key="fk_test")
            run = client.run("find it", agent="reposage")
            calls = []
            run._after_finish(lambda handle: handle._after_finish(calls.append))
            run.result()
            self.assertEqual(calls, [run])
            self.assertEqual(run._on_finish, [])

    def test_cancel_interrupts_a_silent_stream_without_a_run_deadline(self):
        with FakeFountain() as fake:
            fake.state.hang_stream = True
            client = Fountain(base_url=fake.base_url, api_key="fk_test")
            run = client.run("wait", agent="reposage")
            self.assertTrue(fake.state.stream_opened.wait(2))
            requests_before = len(fake.state.requests)
            run.cancel()
            result = run.result(timeout=7)
            self.assertEqual(result.conversation_id, "c-1")
            self.assertFalse(fake.state.release_stream.is_set())
            self.assertEqual(len(fake.state.requests), requests_before)

    def test_an_idle_read_timeout_reconnects_and_can_complete(self):
        with FakeFountain() as fake, patch("fountain.sse.STREAM_READ_TIMEOUT", 0.1):
            fake.state.hang_stream = True
            fake.state.hang_stream_prefix = True
            client = Fountain(base_url=fake.base_url, api_key="fk_test")
            run = client.run("wait", agent="reposage")
            self.assertTrue(fake.state.stream_opened.wait(2))
            # Leave this connection silent. Only a reconnect can read the turn.
            fake.state.hang_stream = False
            result = run.result(timeout=3)
            self.assertEqual(result.text, "Found it.")
            self.assertEqual(fake.state.stream_count, 2)
            streams = [r for r in fake.state.requests if r[1].endswith("/stream")]
            self.assertEqual(streams[1][4]["Last-Event-Id"], "1")

    def test_run_timeout_leaves_the_agent_running(self):
        with FakeFountain() as fake:
            fake.state.hang_stream = True
            client = Fountain(base_url=fake.base_url, api_key="fk_test")
            with self.assertRaises(TimeoutError) as caught:
                client.run("wait", agent="reposage", timeout=0.05).result()
            self.assertEqual(caught.exception.conversation_id, "c-1")
            self.assertIn("still running", str(caught.exception))


class AsyncClientTests(unittest.IsolatedAsyncioTestCase):
    async def test_run_is_awaitable_and_async_iterable(self):
        fake = FakeFountain().__enter__()
        try:
            client = Fountain(base_url=fake.base_url, api_key="fk_test")
            result = await client.run("find it", agent="reposage")
            self.assertEqual(result.text, "Found it.")

            run = client.run("find it", agent="reposage")
            event_types = []
            async for event in run:
                event_types.append(event["type"])
            self.assertIn("turn-start", event_types)
            self.assertIn("turn-end", event_types)
        finally:
            await asyncio.to_thread(fake.__exit__)


if __name__ == "__main__":
    unittest.main()
