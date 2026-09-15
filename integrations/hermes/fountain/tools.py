"""Tool handlers: run a Fountain agent, wait for its turn, read the answer.

A Fountain conversation is a sandbox running an agent; a turn is one prompt and
everything the agent did in response. Fountain's log feed (`/events?blocks=true`)
is the read-model these handlers consume: `output` rows carry server-parsed
`blocks` (`text`, `tool_use`, ...), and `stage` rows mark the turn lifecycle
(`turn/started`, `turn/done`, `turn/failed`, `turn/interrupted`).

Waiting is bounded: every blocking tool returns after `timeout_seconds` with
`done: false` and whatever text has arrived, and `fountain_wait` picks up where
it left off. Hermes deadlines a tool call at 420s by default (see
`timeouts.tools.sequential_call`), so the plugin never sits inside one call for
the whole life of a long turn.
"""

from __future__ import annotations

import json
import os
import threading
import time
from typing import Any, Callable

from .client import FountainClient, FountainError

# The standalone conversations app Fountain sends people to for a transcript.
DEFAULT_APP_URL = "https://fountain-conversations.demo.managoat.com/"

TERMINAL_TURN_STATES = ("done", "failed", "interrupted")
TERMINAL_CONVERSATION_STATUSES = ("failed", "terminated")
POLL_INTERVAL_S = 2.0
MAX_OUTPUT_CHARS = 60_000


class TurnTracker:
    """Per-conversation cursor into the log feed, and the turn currently being followed."""

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._state: dict[str, dict[str, Any]] = {}

    def get(self, conversation_id: str) -> dict[str, Any]:
        with self._lock:
            return self._state.setdefault(
                conversation_id,
                {
                    "cursor": 0,  # last event id consumed
                    "turn_number": None,  # the turn being followed
                    "turn_id": None,
                    "started": False,
                    "state": None,  # terminal turn state once seen
                    "exit_code": None,
                    "reason": None,
                    "text": [],  # accumulated answer fragments
                    "tools": [],  # tool names used, for the summary
                    "break_before_text": False,
                },
            )

    def follow(self, conversation_id: str, turn_number: int) -> dict[str, Any]:
        st = self.get(conversation_id)
        with self._lock:
            st.update(
                {
                    "turn_number": turn_number,
                    "turn_id": None,
                    "started": False,
                    "state": None,
                    "exit_code": None,
                    "reason": None,
                    "text": [],
                    "tools": [],
                    "break_before_text": False,
                }
            )
        return st

    def forget(self, conversation_id: str) -> None:
        with self._lock:
            self._state.pop(conversation_id, None)


class FountainTools:
    def __init__(
        self,
        client_factory: Callable[[], FountainClient],
        *,
        default_timeout: float = 300.0,
        poll_interval: float = POLL_INTERVAL_S,
        sleep: Callable[[float], None] = time.sleep,
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        self._client_factory = client_factory
        self.default_timeout = default_timeout
        self.poll_interval = poll_interval
        self._sleep = sleep
        self._clock = clock
        self.tracker = TurnTracker()

    # ── handlers (each returns a JSON string, never raises) ────────────────

    def agents(self, args: dict, **_: Any) -> str:
        return self._guard(lambda: self._agents(args))

    def run(self, args: dict, **_: Any) -> str:
        return self._guard(lambda: self._run(args))

    def send(self, args: dict, **_: Any) -> str:
        return self._guard(lambda: self._send(args))

    def wait(self, args: dict, **_: Any) -> str:
        return self._guard(lambda: self._wait(args))

    def status(self, args: dict, **_: Any) -> str:
        return self._guard(lambda: self._status(args))

    def conversations(self, args: dict, **_: Any) -> str:
        return self._guard(lambda: self._conversations(args))

    def terminate(self, args: dict, **_: Any) -> str:
        return self._guard(lambda: self._terminate(args))

    # ── implementations ────────────────────────────────────────────────────

    def _agents(self, args: dict) -> dict:
        client = self._client_factory()
        agents = client.list_agents(search=(args.get("search") or None))
        return {
            "agents": [
                {
                    "id": a.get("id"),
                    "name": a.get("name"),
                    "runtime": a.get("runtime"),
                    "model": a.get("model"),
                    "description": a.get("description"),
                    "environment_id": a.get("environment_id"),
                }
                for a in agents
            ],
            "count": len(agents),
        }

    def _run(self, args: dict) -> dict:
        prompt = _required(args, "prompt")
        client = self._client_factory()
        agent = client.resolve_agent(_required(args, "agent"))
        vault_id = client.resolve_vault(args.get("vault"))
        environment_id = client.resolve_environment(args.get("environment"))
        request = {"agent_id": agent["id"], "prompt": prompt}
        if vault_id:
            request["vault_id"] = vault_id
        if environment_id:
            request["environment_id"] = environment_id
        conv = client.create_conversation(request)
        conv_id = conv.get("id")
        if not conv_id:
            raise FountainError(f"POST /api/conversations returned no id: {conv!r}")
        self.tracker.follow(conv_id, 1)
        base = {
            "conversation_id": conv_id,
            "agent": {"id": agent.get("id"), "name": agent.get("name"), "runtime": agent.get("runtime")},
            "turn_number": 1,
            "url": conversation_url(conv_id, client.base_url),
        }
        if args.get("wait") is False:
            return {**base, "status": conv.get("status"), "done": False,
                    "note": "Not waiting. Call fountain_wait with this conversation_id to collect the answer."}
        return {**base, **self._follow(client, conv_id, self._timeout(args))}

    def _send(self, args: dict) -> dict:
        conv_id = _required(args, "conversation_id")
        prompt = _required(args, "prompt")
        client = self._client_factory()
        turns = client.list_turns(conv_id)
        next_turn = 1 + max((int(t.get("turn_number") or 0) for t in turns), default=0)
        client.send_prompt(conv_id, prompt)
        self.tracker.follow(conv_id, next_turn)
        base = {"conversation_id": conv_id, "turn_number": next_turn,
                "url": conversation_url(conv_id, client.base_url)}
        if args.get("wait") is False:
            return {**base, "status": "queued", "done": False,
                    "note": "Not waiting. Call fountain_wait with this conversation_id to collect the answer."}
        return {**base, **self._follow(client, conv_id, self._timeout(args))}

    def _wait(self, args: dict) -> dict:
        conv_id = _required(args, "conversation_id")
        client = self._client_factory()
        st = self.tracker.get(conv_id)
        if st["turn_number"] is None:
            # A conversation this process did not start: follow its latest turn.
            turns = client.list_turns(conv_id)
            latest = max((int(t.get("turn_number") or 0) for t in turns), default=0)
            if latest == 0:
                return {"conversation_id": conv_id, "done": False, "status": "no_turns",
                        "output": "", "note": "This conversation has no turns yet."}
            self.tracker.follow(conv_id, latest)
        return {"conversation_id": conv_id, "turn_number": st["turn_number"],
                "url": conversation_url(conv_id, client.base_url),
                **self._follow(client, conv_id, self._timeout(args))}

    def _status(self, args: dict) -> dict:
        conv_id = _required(args, "conversation_id")
        client = self._client_factory()
        conv = client.get_conversation(conv_id)
        turns = client.list_turns(conv_id)
        return {
            "conversation": _conversation_summary(conv, client.base_url),
            "turns": [
                {k: t.get(k) for k in ("turn_number", "status", "exit_code", "started_at", "ended_at")}
                | {"prompt": _clip(t.get("prompt") or "", 200)}
                for t in turns
            ],
        }

    def _conversations(self, args: dict) -> dict:
        client = self._client_factory()
        convs = client.list_conversations(roots_only=True)
        active_only = args.get("active_only", True)
        if active_only:
            convs = [c for c in convs if c.get("status") not in TERMINAL_CONVERSATION_STATUSES]
        limit = int(args.get("limit") or 20)
        convs = convs[:limit]
        return {"conversations": [_conversation_summary(c, client.base_url) for c in convs],
                "count": len(convs)}

    def _terminate(self, args: dict) -> dict:
        conv_id = _required(args, "conversation_id")
        client = self._client_factory()
        client.terminate(conv_id)
        self.tracker.forget(conv_id)
        return {"conversation_id": conv_id, "status": "terminated"}

    # ── following a turn ───────────────────────────────────────────────────

    def _follow(self, client: FountainClient, conv_id: str, timeout: float) -> dict:
        """Poll the log feed until the followed turn ends or `timeout` elapses."""
        st = self.tracker.get(conv_id)
        deadline = self._clock() + timeout
        conv_status = None
        while True:
            self._consume(client, conv_id, st)
            if st["state"] in TERMINAL_TURN_STATES:
                break
            conv = client.get_conversation(conv_id)
            conv_status = conv.get("status")
            if conv_status in TERMINAL_CONVERSATION_STATUSES:
                # One more drain so a failure written just before the status flip is not lost.
                self._consume(client, conv_id, st)
                break
            if self._clock() >= deadline:
                break
            self._sleep(self.poll_interval)

        # Report the status as of the end of the wait, not the last poll's.
        conv_status = (client.get_conversation(conv_id) or {}).get("status") or conv_status
        output = "".join(st["text"]).strip()
        done = st["state"] in TERMINAL_TURN_STATES or conv_status in TERMINAL_CONVERSATION_STATUSES
        result: dict[str, Any] = {
            "done": done,
            "turn_state": st["state"],
            "output": _clip(output, MAX_OUTPUT_CHARS),
            "tools_used": sorted(set(st["tools"])),
        }
        if conv_status:
            result["status"] = conv_status
        if st["exit_code"] is not None:
            result["exit_code"] = st["exit_code"]
        if st["reason"]:
            result["reason"] = st["reason"]
        if not done:
            result["note"] = (
                "The turn is still running. Call fountain_wait with this conversation_id "
                "to keep waiting; the output so far is above."
            )
        return result

    def _consume(self, client: FountainClient, conv_id: str, st: dict[str, Any]) -> None:
        """Drain new events into the tracker state."""
        while True:
            events, next_cursor, has_more = client.events(conv_id, after=st["cursor"])
            for ev in events:
                self._apply(ev, st)
            if next_cursor:
                st["cursor"] = next_cursor
            if not has_more or not events:
                return

    def _apply(self, ev: dict, st: dict[str, Any]) -> None:
        kind = ev.get("kind")
        if kind == "stage":
            if ev.get("stage") != "turn":
                return
            meta = _parse_json(ev.get("data")) or {}
            if meta.get("turn_number") != st["turn_number"] and not (
                st["turn_id"] and meta.get("turn_id") == st["turn_id"]
            ):
                return
            state = ev.get("state")
            if state == "started":
                st["started"] = True
                st["turn_id"] = meta.get("turn_id") or st["turn_id"]
            elif state in TERMINAL_TURN_STATES:
                st["state"] = state
                st["turn_id"] = st["turn_id"] or meta.get("turn_id")
                if meta.get("exit_code") is not None:
                    st["exit_code"] = meta.get("exit_code")
                if meta.get("reason"):
                    st["reason"] = meta.get("reason")
            return

        if kind != "output" or ev.get("stream") != "acp":
            return
        turn_id = ev.get("turn_id")
        if st["turn_id"] and turn_id and turn_id != st["turn_id"]:
            return
        if not st["started"] and not st["turn_id"]:
            # Output from before our turn started (history of an older turn).
            return
        blocks = ev.get("blocks") or []
        # ACP text chunks join into one message. A tool call or other
        # non-text block separates the next message with a paragraph break.
        for block in blocks:
            bkind = block.get("kind")
            if bkind == "text":
                body = block.get("body") or ""
                if body:
                    if st["text"] and st.get("break_before_text") and not st["text"][-1].endswith("\n"):
                        st["text"].append("\n\n")
                    st["text"].append(body)
                    st["break_before_text"] = False
                continue
            if bkind in ("thinking", "raw", "init"):
                continue
            st["break_before_text"] = True
            if bkind == "tool_use":
                name = block.get("name")
                if name:
                    st["tools"].append(name)
            elif bkind == "result" and not st["text"]:
                body = block.get("body") or ""
                if body:
                    st["text"].append(body)
            elif bkind == "error":
                body = block.get("body") or ""
                if body:
                    st["text"].append(f"\n[error] {body}\n")

    # ── helpers ────────────────────────────────────────────────────────────

    def _timeout(self, args: dict) -> float:
        raw = args.get("timeout_seconds")
        try:
            t = float(raw) if raw is not None else self.default_timeout
        except (TypeError, ValueError):
            t = self.default_timeout
        return max(1.0, t)

    @staticmethod
    def _guard(fn: Callable[[], dict]) -> str:
        try:
            return json.dumps(fn(), ensure_ascii=False, default=str)
        except FountainError as exc:
            return json.dumps({"error": str(exc)})
        except Exception as exc:  # a tool handler must never raise
            return json.dumps({"error": f"{type(exc).__name__}: {exc}"})


def _required(args: dict, key: str) -> str:
    val = args.get(key)
    if val is None or (isinstance(val, str) and not val.strip()):
        raise FountainError(f"{key} is required")
    return str(val).strip() if isinstance(val, str) else val


def _parse_json(raw: Any) -> Any:
    if isinstance(raw, (dict, list)):
        return raw
    if not isinstance(raw, str) or not raw.strip():
        return None
    try:
        return json.loads(raw)
    except ValueError:
        return None


def _clip(text: str, limit: int) -> str:
    if len(text) <= limit:
        return text
    head = limit // 2
    tail = limit - head
    return text[:head] + f"\n…[{len(text) - limit} chars elided]…\n" + text[-tail:]


def conversation_url(conv_id: str, base_url: str) -> str:
    """Where a human reads this conversation.

    Fountain's own UI is a console; the transcript lives in the standalone
    conversations app, which routes on the fragment. `FOUNTAIN_APP_URL`
    points at a different deployment of it (or at "" to fall back to the
    API URL, which is at least fetchable).
    """
    app = os.environ.get("FOUNTAIN_APP_URL", DEFAULT_APP_URL).strip()
    if not app:
        return f"{base_url}/api/conversations/{conv_id}"
    return f"{app.rstrip('/')}/#/c/{conv_id}"


def _conversation_summary(c: dict, base_url: str) -> dict:
    return {
        "id": c.get("id"),
        "title": c.get("title"),
        "status": c.get("status"),
        "agent_id": c.get("agent_id"),
        "runtime": c.get("runtime"),
        "turn_count": c.get("turn_count"),
        "last_active_at": c.get("last_active_at"),
        "unread": c.get("unread"),
        "url": conversation_url(str(c.get("id")), base_url),
    }
