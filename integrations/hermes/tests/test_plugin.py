"""Tests for the Hermes Fountain plugin. Run from the repo root:

    python3 -m unittest discover -s integrations/hermes/tests -v
"""

from __future__ import annotations

import io
import json
import os
import sys
import tempfile
import unittest
import urllib.error
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))  # so `fountain` imports as a package
sys.path.insert(0, str(HERE))

import fountain as plugin  # noqa: E402
from fountain.client import FountainClient, FountainError, resolve_settings  # noqa: E402
from fountain.tools import FountainTools  # noqa: E402
from fake_fountain import TOKEN, FakeFountain  # noqa: E402


class FakeClock:
    """A clock the test advances; `sleep` advances it and runs a per-tick script."""

    def __init__(self) -> None:
        self.now = 0.0
        self.ticks = 0
        self.on_tick = None

    def __call__(self) -> float:
        return self.now

    def sleep(self, seconds: float) -> None:
        self.now += seconds
        self.ticks += 1
        if self.on_tick:
            self.on_tick(self.ticks)


def make_tools(fake: FakeFountain, clock: FakeClock, **kw) -> FountainTools:
    return FountainTools(
        lambda: FountainClient(fake.base_url, TOKEN),
        default_timeout=kw.pop("default_timeout", 300),
        poll_interval=1.0,
        sleep=clock.sleep,
        clock=clock,
        **kw,
    )


def script_turn(st, conv_id: str, turn_number: int, chunks, tools=(), state="done", exit_code=0):
    """Emit a whole turn's events at once."""
    turn = st.turns[conv_id][turn_number - 1]
    st.set_status(conv_id, "running")
    st.stage(conv_id, "started", turn_number, turn["id"], mode="acp")
    for name in tools:
        st.tool(conv_id, turn["id"], name)
    for c in chunks:
        st.text(conv_id, turn["id"], c)
    st.stage(conv_id, state, turn_number, turn["id"], exit_code=exit_code)
    st.set_status(conv_id, "idle")


class SettingsTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.creds = Path(self.tmp.name) / "credentials"
        self.creds.write_text('[default]\napi_key = "from_file"\nbase_url = "https://file.example"\n\n[work]\napi_key = work_key\n')
        self.env = mock.patch.dict(os.environ, {"FOUNTAIN_CREDENTIALS_FILE": str(self.creds)}, clear=False)
        self.env.start()
        for k in ("FOUNTAIN_API_KEY", "FOUNTAIN_TOKEN", "FOUNTAIN_BASE_URL", "FOUNTAIN_PROFILE"):
            os.environ.pop(k, None)

    def tearDown(self):
        self.env.stop()
        self.tmp.cleanup()

    def test_credentials_file_is_the_fallback(self):
        self.assertEqual(resolve_settings(), ("https://file.example", "from_file"))

    def test_env_beats_file_and_settings_beat_env(self):
        os.environ["FOUNTAIN_API_KEY"] = "from_env"
        os.environ["FOUNTAIN_BASE_URL"] = "https://env.example/"
        self.assertEqual(resolve_settings(), ("https://env.example", "from_env"))
        self.assertEqual(resolve_settings(api_key="cfg", base_url="https://cfg.example"), ("https://cfg.example", "cfg"))

    def test_fountain_token_is_the_in_sandbox_name(self):
        os.environ["FOUNTAIN_TOKEN"] = "sandbox_token"
        _, key = resolve_settings()
        self.assertEqual(key, "sandbox_token")

    def test_profile_selects_a_section(self):
        _, key = resolve_settings(profile="work")
        self.assertEqual(key, "work_key")
        os.environ["FOUNTAIN_PROFILE"] = "work"
        self.assertEqual(resolve_settings()[1], "work_key")

    def test_no_key_anywhere(self):
        self.creds.unlink()
        self.assertEqual(resolve_settings(), ("https://managoat.com", ""))
        with self.assertRaises(FountainError):
            FountainClient("https://x", "")


class ClientTests(unittest.TestCase):
    def test_validation_errors_keep_field_details(self):
        body = {"error": "validation_failed", "errors": {"prompt": ["can't be blank"]}}
        response = urllib.error.HTTPError(
            "https://fountain.test/api/conversations", 422, "rejected", {},
            io.BytesIO(json.dumps(body).encode()),
        )
        with mock.patch("urllib.request.urlopen", side_effect=response):
            with self.assertRaises(FountainError) as caught:
                FountainClient("https://fountain.test", TOKEN).create_conversation({"agent_id": "a-1", "prompt": ""})
        self.assertEqual(caught.exception.status, 422)
        self.assertEqual(caught.exception.body, body)
        self.assertIn('"prompt": ["can\'t be blank"]', str(caught.exception))

    def test_create_forwards_api_fields_without_a_projection(self):
        body = {"agent_id": "a-1", "prompt": "hello", "future_field": {"zero": 0},
                "vault_id": None, "fresh": False, "labels": {}, "images": [], "title": ""}
        with FakeFountain() as fake:
            client = FountainClient(fake.base_url, TOKEN)
            self.assertTrue(client.create_conversation(body)["id"])
            sent = [(method, path, payload) for method, path, payload, _ in fake.state.requests]
            self.assertEqual(sent, [("POST", "/api/conversations", body)])

    def test_agent_resolution(self):
        with FakeFountain() as fake:
            c = FountainClient(fake.base_url, TOKEN)
            self.assertEqual(c.resolve_agent("a-2")["name"], "Builder")
            self.assertEqual(c.resolve_agent("REVIEWER")["id"], "a-1")
            self.assertEqual(c.resolve_agent("builder")["id"], "a-2")  # exact (ci) beats prefix
            self.assertEqual(c.resolve_agent("builder-t")["id"], "a-3")  # unique prefix
            with self.assertRaises(FountainError) as cm:
                c.resolve_agent("nope")
            self.assertIn("Builder, builder-two, reviewer", str(cm.exception))

    def test_http_errors_become_fountain_errors(self):
        with FakeFountain() as fake:
            c = FountainClient(fake.base_url, "wrong")
            with self.assertRaises(FountainError) as cm:
                c.list_agents()
            self.assertEqual(cm.exception.status, 401)
            self.assertIn("unauthorized", str(cm.exception))
            c = FountainClient(fake.base_url, TOKEN)
            with self.assertRaises(FountainError) as cm:
                c.get_conversation("missing")
            self.assertEqual(cm.exception.status, 404)

    def test_parent_conversation_header_when_inside_a_sandbox(self):
        with FakeFountain() as fake, mock.patch.dict(os.environ, {"FOUNTAIN_CONVERSATION_ID": "parent-1"}):
            FountainClient(fake.base_url, TOKEN).list_agents()
            _, _, _, headers = fake.state.requests[-1]
            self.assertEqual(headers.get("X-Fountain-Parent-Conversation-Id"), "parent-1")


class RunTests(unittest.TestCase):
    def test_run_waits_for_the_turn_and_concatenates_acp_chunks(self):
        with FakeFountain() as fake:
            st = fake.state
            clock = FakeClock()
            tools = make_tools(fake, clock)

            def on_tick(n):
                if n == 2:  # sandbox comes up, agent works, turn ends
                    script_turn(st, "c-1", 1, ["Hello", ", ", "world."], tools=["read_file", "terminal"])

            clock.on_tick = on_tick
            out = json.loads(tools.run({"agent": "reviewer", "prompt": "say hi", "vault": "prod-keys"}))
            self.assertNotIn("error", out)
            self.assertEqual(out["conversation_id"], "c-1")
            self.assertTrue(out["done"])
            self.assertEqual(out["turn_state"], "done")
            self.assertEqual(out["output"], "Hello, world.")
            self.assertEqual(out["tools_used"], ["read_file", "terminal"])
            self.assertEqual(out["exit_code"], 0)
            self.assertEqual(out["agent"]["name"], "reviewer")
            self.assertEqual(out["url"], "https://fountain-conversations.demo.managoat.com/#/c/c-1")
            create = next(b for m, p, b, _ in st.requests if m == "POST" and p == "/api/conversations")
            self.assertEqual(create, {"agent_id": "a-1", "prompt": "say hi", "vault_id": "v-1"})

    def test_acp_text_after_a_tool_call_starts_a_new_paragraph(self):
        with FakeFountain() as fake:
            st = fake.state
            clock = FakeClock()
            tools = make_tools(fake, clock)

            def on_tick(n):
                if n == 1:
                    turn = st.turns["c-1"][0]
                    st.set_status("c-1", "running")
                    st.stage("c-1", "started", 1, turn["id"])
                    st.text("c-1", turn["id"], "smoke ")
                    st.text("c-1", turn["id"], "ok")
                    st.tool("c-1", turn["id"], "Terminal")
                    st.add_event("c-1", kind="output", stream="acp", turn_id=turn["id"],
                                 blocks=[{"kind": "tool_result", "tool_id": "t1", "body": "Linux", "error": False}])
                    st.text("c-1", turn["id"], "The kernel ")
                    st.text("c-1", turn["id"], "is Linux.")
                    st.stage("c-1", "done", 1, turn["id"], exit_code=0)
                    st.set_status("c-1", "idle")

            clock.on_tick = on_tick
            out = json.loads(tools.run({"agent": "reviewer", "prompt": "x"}))
            self.assertEqual(out["output"], "smoke ok\n\nThe kernel is Linux.")
            self.assertEqual(out["tools_used"], ["Terminal"])

    def test_raw_history_is_available_without_entering_the_acp_reply(self):
        with FakeFountain() as fake:
            st = fake.state
            clock = FakeClock()
            tools = make_tools(fake, clock)

            def on_tick(n):
                if n == 1:
                    turn = st.turns["c-1"][0]
                    st.set_status("c-1", "running")
                    st.stage("c-1", "started", 1, turn["id"])
                    st.add_event("c-1", stream="stdout", turn_id=turn["id"],
                                 data='{"type":"assistant","message":{"content":[]}}')
                    st.add_event("c-1", stream="stderr", turn_id=turn["id"], data="diagnostic")
                    # Even an older server's interpreted stdout blocks are ignored.
                    st.text("c-1", turn["id"], "old parsed output", stream="stdout")
                    st.text("c-1", turn["id"], "current ")
                    st.text("c-1", turn["id"], "reply")
                    st.stage("c-1", "done", 1, turn["id"], exit_code=0)
                    st.set_status("c-1", "idle")

            clock.on_tick = on_tick
            out = json.loads(tools.run({"agent": "reviewer", "prompt": "x"}))
            self.assertEqual(out["output"], "current reply")
            events, _, _ = FountainClient(fake.base_url, TOKEN).events("c-1")
            raw = [ev["data"] for ev in events if ev.get("stream") in ("stdout", "stderr")]
            self.assertEqual(raw[:2], ['{"type":"assistant","message":{"content":[]}}', "diagnostic"])

    def test_timeout_returns_partial_and_wait_resumes_from_the_cursor(self):
        with FakeFountain() as fake:
            st = fake.state
            clock = FakeClock()
            tools = make_tools(fake, clock)

            def on_tick(n):
                if n == 1:
                    turn = st.turns["c-1"][0]
                    st.set_status("c-1", "running")
                    st.stage("c-1", "started", 1, turn["id"])
                    st.text("c-1", turn["id"], "part one. ")

            clock.on_tick = on_tick
            out = json.loads(tools.run({"agent": "reviewer", "prompt": "x", "timeout_seconds": 3}))
            self.assertFalse(out["done"])
            self.assertEqual(out["status"], "running")
            self.assertEqual(out["output"], "part one.")
            self.assertIn("fountain_wait", out["note"])
            self.assertLessEqual(clock.now, 4)

            turn = st.turns["c-1"][0]
            st.text("c-1", turn["id"], "part two.")
            st.stage("c-1", "done", 1, turn["id"], exit_code=0)
            st.set_status("c-1", "idle")
            clock.on_tick = None
            out2 = json.loads(tools.wait({"conversation_id": "c-1"}))
            self.assertTrue(out2["done"])
            self.assertEqual(out2["output"], "part one. part two.")

    def test_send_follows_only_the_new_turn(self):
        with FakeFountain() as fake:
            st = fake.state
            clock = FakeClock()
            tools = make_tools(fake, clock)
            clock.on_tick = lambda n: script_turn(st, "c-1", 1, ["answer one"]) if n == 1 else None
            out = json.loads(tools.run({"agent": "Builder", "prompt": "one"}))
            self.assertEqual(out["output"], "answer one")

            def on_tick2(n):
                if n == 1:
                    script_turn(st, "c-1", 2, ["answer two"], tools=["write_file"])

            clock.ticks = 0
            clock.on_tick = on_tick2
            out2 = json.loads(tools.send({"conversation_id": "c-1", "prompt": "two"}))
            self.assertEqual(out2["turn_number"], 2)
            self.assertEqual(out2["output"], "answer two")
            self.assertEqual(out2["tools_used"], ["write_file"])
            self.assertTrue(out2["done"])

    def test_wait_on_a_conversation_this_process_did_not_start(self):
        with FakeFountain() as fake:
            st = fake.state
            clock = FakeClock()
            # Another client created it and ran turn 1; turn 2 is in flight.
            other = FountainClient(fake.base_url, TOKEN)
            conv = other.create_conversation({"agent_id": "a-1", "prompt": "one"})
            script_turn(st, conv["id"], 1, ["old answer"])
            st.add_turn(conv["id"], "two")
            turn2 = st.turns[conv["id"]][1]
            st.set_status(conv["id"], "running")
            st.stage(conv["id"], "started", 2, turn2["id"])
            st.text(conv["id"], turn2["id"], "new answer")
            st.stage(conv["id"], "done", 2, turn2["id"], exit_code=0)
            st.set_status(conv["id"], "idle")

            tools = make_tools(fake, clock)
            out = json.loads(tools.wait({"conversation_id": conv["id"]}))
            self.assertTrue(out["done"])
            self.assertEqual(out["turn_number"], 2)
            self.assertEqual(out["output"], "new answer")

    def test_failed_turn_and_failed_conversation(self):
        with FakeFountain() as fake:
            st = fake.state
            clock = FakeClock()
            tools = make_tools(fake, clock)

            def on_tick(n):
                if n == 1:
                    turn = st.turns["c-1"][0]
                    st.set_status("c-1", "running")
                    st.stage("c-1", "started", 1, turn["id"])
                    st.stage("c-1", "failed", 1, turn["id"], reason="sprite connection lost")
                    st.set_status("c-1", "failed")

            clock.on_tick = on_tick
            out = json.loads(tools.run({"agent": "reviewer", "prompt": "x"}))
            self.assertTrue(out["done"])
            self.assertEqual(out["turn_state"], "failed")
            self.assertEqual(out["reason"], "sprite connection lost")
            self.assertEqual(out["status"], "failed")

        with FakeFountain() as fake:  # provisioning fails before any turn stage
            st = fake.state
            clock = FakeClock()
            tools = make_tools(fake, clock)
            clock.on_tick = lambda n: st.set_status("c-1", "failed") if n == 1 else None
            out = json.loads(tools.run({"agent": "reviewer", "prompt": "x"}))
            self.assertTrue(out["done"])
            self.assertIsNone(out["turn_state"])
            self.assertEqual(out["status"], "failed")

    def test_no_wait_and_status_and_terminate(self):
        with FakeFountain() as fake:
            st = fake.state
            clock = FakeClock()
            tools = make_tools(fake, clock)
            out = json.loads(tools.run({"agent": "reviewer", "prompt": "x", "wait": False}))
            self.assertFalse(out["done"])
            self.assertEqual(clock.ticks, 0)
            status = json.loads(tools.status({"conversation_id": "c-1"}))
            self.assertEqual(status["conversation"]["status"], "pending")
            self.assertEqual(status["turns"][0]["prompt"], "x")
            convs = json.loads(tools.conversations({}))
            self.assertEqual(convs["count"], 1)
            term = json.loads(tools.terminate({"conversation_id": "c-1"}))
            self.assertEqual(term["status"], "terminated")
            self.assertEqual(st.conversations["c-1"]["status"], "terminated")
            self.assertEqual(json.loads(tools.conversations({}))["count"], 0)

    def test_errors_are_json_not_exceptions(self):
        with FakeFountain() as fake:
            tools = make_tools(fake, FakeClock())
            self.assertIn("agent is required", json.loads(tools.run({"prompt": "x"}))["error"])
            self.assertIn("No agent named", json.loads(tools.run({"agent": "zzz", "prompt": "x"}))["error"])
            self.assertIn("HTTP 404", json.loads(tools.status({"conversation_id": "nope"}))["error"])
            self.assertIn("No vault named", json.loads(tools.run({"agent": "reviewer", "prompt": "x", "vault": "zz"}))["error"])
        # transport failure (server gone)
        tools = FountainTools(lambda: FountainClient("http://127.0.0.1:9", TOKEN))
        self.assertIn("failed", json.loads(tools.agents({}))["error"])


class FakeCtx:
    def __init__(self, config=None):
        self.config = config or {}
        self.tools = {}
        self.skills = {}
        self.commands = {}

    def get_config(self, key, default=None):
        return self.config.get(key, default)

    def register_tool(self, *, name, toolset, schema, handler, check_fn=None, requires_env=None,
                      is_async=False, description="", emoji="", override=False):
        self.tools[name] = {"toolset": toolset, "schema": schema, "handler": handler, "check_fn": check_fn}

    def register_skill(self, name, path, description="", frontmatter=None):
        self.skills[name] = Path(path)

    def register_command(self, name, handler, description="", args_hint=""):
        self.commands[name] = handler


class RegisterTests(unittest.TestCase):
    def test_register_wires_tools_skill_and_command(self):
        with FakeFountain() as fake:
            ctx = FakeCtx({"base_url": fake.base_url, "api_key": TOKEN})
            plugin.register(ctx)
            self.assertEqual(
                sorted(ctx.tools),
                ["fountain_agents", "fountain_conversations", "fountain_run", "fountain_send",
                 "fountain_status", "fountain_terminate", "fountain_wait"],
            )
            for name, entry in ctx.tools.items():
                self.assertEqual(entry["toolset"], "fountain")
                self.assertEqual(entry["schema"]["name"], name)
                self.assertTrue(entry["check_fn"]())
            self.assertTrue(ctx.skills["fountain"].is_file())
            out = json.loads(ctx.tools["fountain_agents"]["handler"]({"search": "build"}))
            self.assertEqual([a["name"] for a in out["agents"]], ["Builder", "builder-two"])
            self.assertIn("reviewer", ctx.commands["fountain"]("agents"))
            self.assertIn("instance:", ctx.commands["fountain"]("whoami"))
            self.assertIn("usage:", ctx.commands["fountain"]("run"))
            self.assertIn("/fountain", ctx.commands["fountain"](""))

    def test_tools_hidden_without_a_key(self):
        with tempfile.TemporaryDirectory() as tmp, mock.patch.dict(
            os.environ, {"FOUNTAIN_CREDENTIALS_FILE": str(Path(tmp) / "none")}
        ):
            for k in ("FOUNTAIN_API_KEY", "FOUNTAIN_TOKEN"):
                os.environ.pop(k, None)
            ctx = FakeCtx()
            plugin.register(ctx)
            self.assertFalse(ctx.tools["fountain_run"]["check_fn"]())
            self.assertIn("No Fountain API key", json.loads(ctx.tools["fountain_run"]["handler"]({"agent": "a", "prompt": "b"}))["error"])


if __name__ == "__main__":
    unittest.main()
