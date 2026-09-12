#!/usr/bin/env python3
"""Capture synthetic ACP/Codex HTTP request metadata; never use real credentials.

Install the versions separately, then pass --adapter and --codex executable paths.
See apps/fountain/test/fixtures/codex_protected/README.md for scope and gates.
"""
import argparse
import base64
import datetime
import http.server
import json
import os
import pathlib
import queue
import signal
import subprocess
import tempfile
import threading

requests = []
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--adapter", required=True, type=pathlib.Path)
parser.add_argument("--codex", required=True, type=pathlib.Path)
args = parser.parse_args()
adapter = str(args.adapter.resolve())
codex = str(args.codex.resolve())


class Origin(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        length = self.headers.get("content-length")
        body = self.rfile.read(int(length or 0))
        record = {
            "method": self.command,
            "target": self.path,
            "header_names": sorted(name.lower() for name in self.headers),
            "content_type": self.headers.get("content-type"),
            "content_encoding": self.headers.get("content-encoding"),
            "accept": self.headers.get("accept"),
            "content_length_matches": length is not None
            and int(length) == len(body)
            and len(body) > 0,
            "synthetic_auth_matches": self.headers.get("authorization")
            == "Bearer synthetic-managed-token",
            "synthetic_identity_matches": self.headers.get("chatgpt-account-id")
            == "account-fixture",
        }
        requests.append(record)
        output = {
            "id": "msg_fixture",
            "type": "message",
            "role": "assistant",
            "status": "completed",
            "content": [
                {"type": "output_text", "text": "fixture ok", "annotations": []}
            ],
        }
        events = [
            {
                "type": "response.created",
                "response": {"id": "resp_fixture", "status": "in_progress"},
            },
            {
                "type": "response.output_item.added",
                "output_index": 0,
                "item": {**output, "status": "in_progress", "content": []},
            },
            {
                "type": "response.output_text.delta",
                "output_index": 0,
                "content_index": 0,
                "item_id": "msg_fixture",
                "delta": "fixture ok",
            },
            {"type": "response.output_item.done", "output_index": 0, "item": output},
            {
                "type": "response.completed",
                "response": {
                    "id": "resp_fixture",
                    "status": "completed",
                    "output": [output],
                    "usage": {
                        "input_tokens": 10,
                        "output_tokens": 2,
                        "total_tokens": 12,
                    },
                },
            },
        ]
        payload = "".join(
            "event: " + e["type"] + "\ndata: " + json.dumps(e) + "\n\n" for e in events
        ).encode()
        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.send_header("content-length", str(len(payload)))
        self.send_header("x-codex-turn-state", "synthetic-turn-state")
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):
        requests.append({"method": self.command, "target": self.path})
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.end_headers()
        self.wfile.write(b'{"models": []}')

    def log_message(self, *args):
        pass


def jwt(claims):
    def enc(value):
        return base64.urlsafe_b64encode(json.dumps(value).encode()).decode().rstrip("=")

    return enc({"alg": "none"}) + "." + enc(claims) + ".fixture"


with tempfile.TemporaryDirectory(prefix="adr52-codex-probe-") as temp:
    root = pathlib.Path(temp)
    home = root / "codex"
    home.mkdir()
    token = "synthetic-managed-token"
    account = "account-fixture"
    (home / "auth.json").write_text(
        json.dumps(
            {
                "auth_mode": "chatgptAuthTokens",
                "tokens": {
                    "access_token": token,
                    "refresh_token": "",
                    "account_id": account,
                    "id_token": jwt(
                        {
                            "sub": "fixture",
                            "email": "fixture@example.invalid",
                            "https://api.openai.com/auth": {
                                "chatgpt_account_id": account,
                                "chatgpt_plan_type": "plus",
                            },
                        }
                    ),
                },
                "last_refresh": datetime.datetime.now(
                    datetime.timezone.utc
                ).isoformat(),
            }
        )
    )
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Origin)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    provider = {
        "name": "OpenAI",
        "base_url": f"http://127.0.0.1:{server.server_port}/backend-api/codex",
        "wire_api": "responses",
        "requires_openai_auth": True,
        "supports_websockets": False,
    }
    config = {
        "model": "gpt-5.4",
        "model_provider": "fountain_openai_http",
        "model_providers": {"fountain_openai_http": provider},
        "features": {"respect_system_proxy": True},
        "approval_policy": "never",
    }
    # CODEX_HOME is the client's documented auth/config directory, isolated
    # here so this synthetic probe never reads the operator's credentials.
    env = {
        "PATH": os.environ["PATH"],
        "TMPDIR": temp,
        "LANG": "en_US.UTF-8",
        "CODEX_HOME": str(home),
        "CODEX_CONFIG": json.dumps(config),
        "CODEX_PATH": codex,
    }
    versions = {
        "adapter": subprocess.check_output(
            [adapter, "--version"], env=env, text=True, timeout=10
        ).strip(),
        "codex": subprocess.check_output(
            [codex, "--version"], env=env, text=True, timeout=10
        ).strip(),
    }
    if versions != {
        "adapter": "@agentclientprotocol/codex-acp 1.10.0",
        "codex": "codex-cli 0.153.4",
    }:
        raise RuntimeError(
            "This fixture requires codex-acp 1.10.0 and codex-cli 0.153.4"
        )
    proc = subprocess.Popen(
        [adapter],
        env=env,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        cwd=temp,
        start_new_session=True,
    )
    messages = queue.Queue()

    def read():
        for line in proc.stdout:
            messages.put(json.loads(line))

    threading.Thread(target=read, daemon=True).start()

    def call(id, method, params):
        proc.stdin.write(
            json.dumps({"jsonrpc": "2.0", "id": id, "method": method, "params": params})
            + "\n"
        )
        proc.stdin.flush()
        while True:
            msg = messages.get(timeout=45)
            if msg.get("id") == id:
                if "error" in msg:
                    raise RuntimeError(msg)
                return msg["result"]

    try:
        call(
            1,
            "initialize",
            {
                "protocolVersion": 1,
                "clientCapabilities": {},
                "clientInfo": {"name": "fountain-fixture", "version": "1"},
            },
        )
        session = call(2, "session/new", {"cwd": temp, "mcpServers": []})
        turns = []
        for id in [3, 4]:
            result = call(
                id,
                "session/prompt",
                {
                    "sessionId": session["sessionId"],
                    "prompt": [
                        {"type": "text", "text": "Reply fixture ok. Do not call tools."}
                    ],
                },
            )
            if result["stopReason"] != "end_turn":
                raise RuntimeError("Synthetic turn did not complete")
            turns.append(result["stopReason"])
        if len(requests) != 2 or any(
            r["method"] != "POST"
            or r["target"] != "/backend-api/codex/responses"
            or not r.get("content_length_matches")
            or not r.get("synthetic_auth_matches")
            or not r.get("synthetic_identity_matches")
            or "transfer-encoding" in r["header_names"]
            for r in requests
        ):
            raise RuntimeError("Unexpected client request contract")
        print(
            json.dumps(
                {"versions": versions, "turns": turns, "requests": requests}, indent=2
            )
        )
    finally:
        os.killpg(proc.pid, signal.SIGTERM)
        proc.communicate(timeout=10)
        server.shutdown()
