"""Load-test runner regressions; never contact a provider or spend tokens."""

import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import urllib.error


SPEC = importlib.util.spec_from_file_location(
    "load_test", Path(__file__).resolve().parents[1] / "load-test" / "run.py")
runner = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(runner)

LANE = {"name": "e2b-haiku-1", "provider": "e2b", "runtime": "claude",
        "model": "anthropic/haiku", "agent_id": "agent"}


def stage(number, name, state, second=0, detail="{}"):
    return {"id": number, "kind": "stage", "stage": name, "state": state,
            "turn_id": "turn" if name == "turn" else None, "data": detail,
            "ts": f"2026-10-16T10:00:{second:02d}Z", "blocks": []}


def text(number, body, second=2, kind="text"):
    return {"id": number, "kind": "output", "stage": "turn", "turn_id": "turn",
            "ts": f"2026-10-16T10:00:{second:02d}Z", "blocks": [{"kind": kind, "body": body}]}


def page(events, more=False):
    return {"data": events, "meta": {"next_cursor": events[-1]["id"] if events else None,
                                     "has_more": more}}


class FakeAPI:
    base = "https://test.example"

    def __init__(self, pages=None):
        self.pages = list(pages if pages is not None else [page([
            stage(1, "turn", "started"), text(2, "orange"), stage(3, "turn", "done", 3)])])
        self.calls = []
        self.sandbox_status = "ready"
        self.agent_id = "agent"
        self.post_error = None

    def call(self, method, path, body=None, timeout=15):
        self.calls.append((method, path, body))
        if method == "POST" and self.post_error:
            raise self.post_error
        if method == "POST" and path == "/conversations":
            return {"data": {"id": "conversation", "sandbox_id": "sandbox"}}
        if method == "GET" and "/events?" in path:
            result = self.pages.pop(0) if self.pages else page([])
            if isinstance(result, Exception):
                raise result
            return result
        if path == "/conversations/conversation" and method == "GET":
            return {"data": {"agent_id": self.agent_id, "sandbox_id": "sandbox"}}
        if path == "/sandboxes/sandbox":
            return {"data": {"status": self.sandbox_status}}
        if path.endswith("/turns"):
            return {"data": []}
        return {}


class LoadTest(unittest.TestCase):
    def setUp(self):
        runner.STOP.clear()
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.journal = runner.Journal(self.root)
        self.quiet = patch("sys.stdout", new_callable=io.StringIO)
        self.quiet.start()
        self.addCleanup(self.quiet.stop)

    def probe(self, api, kind="fresh", conversation=None, timeout=1):
        return runner.probe(api, self.journal, LANE, kind, conversation, timeout, .001)

    def conversation(self):
        return {"id": "conversation", "agent_id": "agent", "lane": LANE, "cursor": None}

    def test_failure_before_turn_exists_is_not_a_generic_timeout(self):
        api = FakeAPI([page([stage(1, "provision", "failed", detail='{"reason":"install exit 1"}')])])
        conversation, result = self.probe(api)
        self.assertEqual(result["status"], "stage_failed")
        self.assertEqual(result["failed_stage"], "provision")
        self.assertIn("install exit 1", result["detail"])
        self.assertEqual(conversation["id"], "conversation")
        self.assertIsNone(result["request_to_first_text_observed_ms"])

    def test_paginated_text_ignores_reasoning_and_counts_server_latency(self):
        api = FakeAPI([page([stage(1, "turn", "started"), text(2, "secret reasoning", kind="thinking")], True),
                       page([text(3, "or"), text(4, "ange"), stage(5, "turn", "done", 3)])])
        conversation, result = self.probe(api)
        self.assertEqual(result["status"], "completed")
        self.assertEqual(result["text"], "orange")
        self.assertEqual(result["turn_to_first_text_server_ms"], 2000)
        self.assertEqual(conversation["cursor"], 5)
        self.assertTrue(any("after=2" in path for _, path, _ in api.calls))

    def test_completed_without_expected_answer_is_failure(self):
        for output in ([], [text(2, "banana")]):
            with self.subTest(output=output):
                _, result = self.probe(FakeAPI([page([stage(1, "turn", "started"), *output,
                                                    stage(3, "turn", "done", 3)])]))
                self.assertEqual(result["status"], "unexpected_output")

    def test_post_is_never_retried_after_503(self):
        api = FakeAPI()
        api.post_error = runner.APIError(503, "no available server")
        _, result = self.probe(api)
        self.assertEqual(result["status"], "http_error")
        self.assertEqual(result["http_status"], 503)
        self.assertTrue(result["write_may_have_succeeded"])
        self.assertEqual(len(api.calls), 1)
        self.assertEqual(runner.summarize(self.journal)["unresolved_launches"],
                         [result["client_request_id"]])

    def test_get_503_is_recorded_and_retried_without_reposting_prompt(self):
        api = FakeAPI([runner.APIError(503, "rollout"), page([
            stage(1, "turn", "started"), text(2, "orange"), stage(3, "turn", "done", 3)])])
        _, result = self.probe(api)
        self.assertEqual(result["status"], "completed")
        self.assertEqual(result["read_errors"], 1)
        self.assertEqual(sum(method == "POST" for method, _, _ in api.calls), 1)

    def test_resume_does_not_wake_a_ready_sandbox(self):
        api = FakeAPI([page([])])
        _, result = self.probe(api, "cold_resume", self.conversation())
        self.assertEqual(result["status"], "skipped_not_suspended")
        self.assertFalse(any(method == "POST" for method, _, _ in api.calls))

    def test_resume_checks_suspension_and_ignores_old_transcript(self):
        api = FakeAPI([page([text(10, "old reply")]), page([
            stage(11, "turn", "started"), text(12, "orange"), stage(13, "turn", "done", 3)])])
        api.sandbox_status = "suspended"
        _, result = self.probe(api, "cold_resume", self.conversation())
        self.assertEqual(result["status"], "completed")
        self.assertEqual(result["text"], "orange")
        self.assertEqual(result["sandbox_before"], "suspended")
        self.assertTrue(any("after=10" in path for _, path, _ in api.calls))

    def test_poll_timeout_keeps_conversation_id_for_cleanup(self):
        conversation, result = self.probe(FakeAPI([]), timeout=.01)
        self.assertEqual(result["status"], "timeout")
        self.assertEqual(conversation["id"], "conversation")
        self.assertEqual(runner.resources(self.journal)[0]["conversation"]["id"], "conversation")

    def test_stop_prevents_new_posts(self):
        runner.STOP.set()
        api = FakeAPI()
        _, result = self.probe(api)
        self.assertEqual(result["status"], "interrupted")
        self.assertEqual(api.calls, [])

    def test_cleanup_preserves_retained_until_explicitly_included(self):
        c = self.conversation()
        self.journal.write("agent", id="agent", lane=LANE)
        self.journal.write("created", **c)
        self.journal.write("retained", id=c["id"], conversation=c)
        api = FakeAPI()
        runner.cleanup(api, self.journal)
        self.assertEqual(api.calls, [])
        self.assertEqual(len(runner.summarize(self.journal)["retained"]), 1)
        runner.cleanup(api, self.journal, include_retained=True)
        self.assertEqual([method for method, _, _ in api.calls], ["GET", "POST", "DELETE"])
        self.assertEqual(runner.resources(self.journal), ({}, {}, set()))

    def test_cleanup_refuses_agent_mismatch(self):
        api = FakeAPI()
        api.agent_id = "some-other-agent"
        self.assertFalse(runner.terminate(api, self.journal, self.conversation()))
        self.assertFalse(any(method == "POST" for method, _, _ in api.calls))

    def test_failed_cleanup_is_recoverable_from_journal(self):
        c = self.conversation()
        self.journal.write("created", **c)
        api = FakeAPI()
        api.post_error = runner.APIError(503, "rollout")
        runner.cleanup(api, self.journal)
        self.assertEqual(len(runner.summarize(self.journal)["cleanup_pending"]), 1)
        api.post_error = None
        runner.cleanup(api, self.journal)
        self.assertEqual(runner.summarize(self.journal)["cleanup_pending"], [])

    def test_ambiguous_launch_keeps_agent_for_manual_reconciliation(self):
        api = FakeAPI()
        self.journal.write("agent", id="agent", lane=LANE)
        self.journal.write("result", lane=LANE["name"], kind="fresh", status="transport_error",
                           agent_id="agent", conversation_id=None, client_request_id="request",
                           write_may_have_succeeded=True)
        runner.cleanup(api, self.journal)
        self.assertFalse(any(method == "DELETE" for method, _, _ in api.calls))
        self.assertEqual(runner.summarize(self.journal)["agent_cleanup_pending"], ["agent"])

    def test_summary_does_not_hide_failures_or_turn_them_into_latency_samples(self):
        for status, value in [("completed", 100), ("completed", 200), ("http_error", 10000)]:
            self.journal.write("result", lane="lane", kind="fresh", status=status,
                               request_to_first_text_observed_ms=value)
        self.journal.write("skipped_busy", count=3)
        report = runner.summarize(self.journal)
        self.assertEqual(report["operations"], 3)
        self.assertEqual(report["completed"], 2)
        self.assertEqual(report["skipped_busy"], 3)
        group = report["groups"]["lane/fresh"]
        self.assertEqual(group["outcomes"]["http_error"], 1)
        self.assertEqual(group["latencies"]["request_to_first_text_observed_ms"],
                         {"n": 2, "median": 150, "p95": 200, "max": 200})

    def test_stalled_pagination_fails_instead_of_looping(self):
        api = FakeAPI([{"data": [], "meta": {"has_more": True, "next_cursor": None}}])
        _, result = self.probe(api)
        self.assertEqual(result["status"], "protocol_error")

    def test_config_rejects_duplicate_lanes_and_unbounded_concurrency(self):
        config = self.root / "config.json"
        for lanes in ([LANE, LANE], [{**LANE, "copies": 33}], [{**LANE, "copies": 1.5}], []):
            config.write_text(json.dumps({"lanes": lanes}))
            with self.assertRaises(ValueError):
                runner.load_config(config)

    def test_resume_rejects_a_different_instance_before_any_request(self):
        (self.root / "run.json").write_text(json.dumps({"base_url": "https://other.example"}))
        with patch.dict("os.environ", {"MANAGOAT_BASE_URL": FakeAPI.base, "MANAGOAT_API_KEY": "test"}), \
                patch("sys.stderr", new_callable=io.StringIO):
            with self.assertRaises(SystemExit) as error:
                runner.main(["resume", "--output", str(self.root)])
        self.assertEqual(error.exception.code, 2)

    def test_redirects_are_not_followed_with_the_api_key(self):
        self.assertIsNone(runner.NoRedirect().redirect_request(None, None, 302, "", {}, "https://other.example"))

    def test_transport_encodes_json_and_redacts_the_key_from_error_bodies(self):
        api = runner.API("https://test.example/", "test-secret")
        failure = urllib.error.HTTPError("https://test.example/api/conversations", 503,
                                         "Unavailable", {}, io.BytesIO(b"failed test-secret"))
        with patch.object(runner.urllib.request, "build_opener") as opener:
            opener.return_value.open.side_effect = failure
            with self.assertRaises(runner.APIError) as caught:
                api.call("POST", "/conversations", {"prompt": "orange"}, timeout=3)
        request = opener.return_value.open.call_args.args[0]
        self.assertEqual(request.full_url, "https://test.example/api/conversations")
        self.assertEqual(json.loads(request.data), {"prompt": "orange"})
        self.assertEqual(request.get_header("Authorization"), "Bearer test-secret")
        self.assertEqual(caught.exception.status, 503)
        self.assertNotIn("test-secret", str(caught.exception))
        self.assertIn("[redacted]", str(caught.exception))

    def test_busy_lane_skips_slots_instead_of_catching_up(self):
        clock = [0.0]
        args = runner.argparse.Namespace(duration=120, interval=30, timeout=240,
                                        poll=1, keep_idle=False)
        calls = []

        def fake_probe(*_):
            calls.append(clock[0])
            clock[0] += 95
            return None, {"status": "timeout"}

        def wait(seconds):
            clock[0] += seconds
            return False

        with patch.object(runner.time, "monotonic", side_effect=lambda: clock[0]), \
                patch.object(runner.STOP, "wait", side_effect=wait), \
                patch.object(runner, "probe", side_effect=fake_probe):
            runner.lane_run(FakeAPI(), self.journal, LANE, args, 0)
        self.assertEqual(calls, [0, 95])
        self.assertEqual(runner.summarize(self.journal)["skipped_busy"], 2)

    def test_run_executes_fresh_then_warm_and_preserves_requested_ids(self):
        config = self.root / "config.json"
        config.write_text(json.dumps({"lanes": [LANE]}))
        api = FakeAPI()
        original = api.call

        def call(method, path, body=None, timeout=15):
            if path == "/agents" and method == "POST":
                return {"data": {"id": "agent"}}
            if path.endswith("/prompts") and method == "POST":
                api.pages.append(page([stage(4, "turn", "started"), text(5, "orange"),
                                       stage(6, "turn", "done", 3)]))
            return original(method, path, body, timeout)

        api.call = call
        out = self.root / "run"
        clock = [0.0]

        def wait(seconds):
            clock[0] += seconds
            return False

        with patch.dict("os.environ", {"MANAGOAT_BASE_URL": FakeAPI.base, "MANAGOAT_API_KEY": "test"}), \
                patch.object(runner, "API", return_value=api), \
                patch.object(runner.time, "monotonic", side_effect=lambda: clock[0]), \
                patch.object(runner.STOP, "wait", side_effect=wait):
            code = runner.main(["run", "--config", str(config), "--output", str(out),
                                "--interval", ".05", "--duration", ".09", "--keep-idle"])
        report = json.loads((out / "summary.json").read_text())
        self.assertEqual(code, 0)
        self.assertEqual(report["operations"], 2)
        self.assertEqual(report["completed"], 2)
        self.assertEqual(len(report["retained"]), 1)
        self.assertEqual(report["cleanup_pending"], [])
        self.assertFalse(any(path.endswith("/terminate") for _, path, _ in api.calls))


if __name__ == "__main__":
    unittest.main()
