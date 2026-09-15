#!/usr/bin/env python3
"""Probe a synthetic additive field through real SDK/CLI HTTP paths.

Only a loopback server is used. SDK create returns a deliberate 422 after
recording the body: run/stream behavior remains covered by conformance.
Swift's typed probe compiles against a temporary regenerated contract/model;
no fake field or generated test model is written into production sources.
"""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = Path(__file__).resolve().parents[2]
FIXTURES = ROOT / "sdk/contract/propagation"
FIXTURE = json.loads((FIXTURES / "fixture.json").read_text())


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"))


class Recorder(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def reply(self, status, value):
        body = json.dumps(value).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        self.server.recorded.append(("POST", self.path, body))
        if self.path != "/api/conversations":
            self.reply(404, {"error": "unexpected_path"})
        elif self.server.cli:
            self.reply(201, {"data": FIXTURE["response"]})
        else:
            self.reply(422, {"error": "fixture_stop"})

    def do_GET(self):
        self.server.recorded.append(("GET", self.path, None))
        self.reply(200 if self.path == "/api/conversations/c1" else 404,
                   {"data": FIXTURE["response"]})


def swift_package(directory):
    package = Path(directory)
    sources = package / "Sources"
    shutil.copytree(ROOT / "sdk/swift/Sources", sources)
    spec = importlib.util.spec_from_file_location("swiftgen", ROOT / "scripts/sdk-contract/generate-swift.py")
    generator = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(generator)
    contract = json.loads((ROOT / "sdk/contract/contract.json").read_text())
    contract["schemas"].update(FIXTURE["schemas"])
    for owner in ["ConversationCreateRequest", "Conversation", "Turn"]:
        contract["schemas"][owner]["properties"][FIXTURE["field"]] = FIXTURE["schema"]
    (sources / "FountainKit/Models/ConversationWire.generated.swift").write_text(generator.Generator(contract).render())
    for target, fixture in [("MapProbe", "swift-map.swift"), ("KitProbe", "swift-kit.swift")]:
        (sources / target).mkdir()
        shutil.copyfile(FIXTURES / fixture, sources / target / "main.swift")
    (package / "Package.swift").write_text('''// swift-tools-version: 6.1
import PackageDescription
let package = Package(name: "FieldPropagation", platforms: [.macOS(.v12)], targets: [
  .target(name: "Fountain"), .target(name: "FountainKit"),
  .executableTarget(name: "MapProbe", dependencies: ["Fountain"]),
  .executableTarget(name: "KitProbe", dependencies: ["FountainKit"])
])
''')
    return package


def run(command, cwd, env, server, cli=False, stdin=None):
    server.recorded = []
    server.cli = cli
    result = subprocess.run(command, cwd=cwd, env=env, input=stdin, text=True,
                            capture_output=True, timeout=180)
    if result.returncode:
        raise RuntimeError(f"{' '.join(map(str, command))}\n{result.stdout}\n{result.stderr}")
    expected = [("POST", "/api/conversations", FIXTURE["request"])]
    if not cli:
        expected.append(("GET", "/api/conversations/c1", None))
    if canonical(server.recorded) != canonical(expected):
        raise AssertionError(f"Wire mismatch: {server.recorded!r}; expected {expected!r}")
    if cli and json.loads(result.stdout) != {"data": FIXTURE["response"]}:
        raise AssertionError(f"CLI response field lost: {result.stdout}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--client", choices=["all", "typescript", "python", "elixir", "cli", "swift"], default="all")
    args = parser.parse_args()
    clients = ["typescript", "python", "elixir", "cli", "swift"] if args.client == "all" else [args.client]
    server = ThreadingHTTPServer(("127.0.0.1", 0), Recorder)
    server.recorded, server.cli = [], False
    worker = threading.Thread(target=server.serve_forever, daemon=True)
    worker.start()
    env = {key: value for key, value in os.environ.items() if not key.startswith("FOUNTAIN_")}
    env.update(FOUNTAIN_BASE_URL=f"http://127.0.0.1:{server.server_port}", FOUNTAIN_API_KEY="fixture",
               FOUNTAIN_CREDENTIALS_FILE="/nonexistent/fountain-propagation-credentials",
               PYTHONPATH=str(ROOT / "sdk/python/src"))
    try:
        for client in clients:
            if client == "typescript":
                run(["node", str(FIXTURES / "typescript.mjs")], ROOT, env, server)
            elif client == "python":
                run([sys.executable, str(FIXTURES / "python.py")], ROOT, env, server)
            elif client == "elixir":
                run(["mix", "run", str(FIXTURES / "elixir.exs")], ROOT / "sdk/elixir", env, server)
            elif client == "cli":
                run(["go", "run", "-mod=readonly", "./cmd/fountain", "conv", "create", "--file", "-"],
                    ROOT / "cli", env, server, cli=True, stdin=json.dumps(FIXTURE["request"]))
            else:
                with tempfile.TemporaryDirectory(prefix="fountain-propagation-") as directory:
                    package = swift_package(directory)
                    for target in ["MapProbe", "KitProbe"]:
                        run(["swift", "run", "-Xswiftc", "-warnings-as-errors", target, str(FIXTURES / "fixture.json")], package, env, server)
            print(f"{client}: additive request/response field preserved", flush=True)
    finally:
        server.shutdown()
        server.server_close()
        worker.join()
    return 0


if __name__ == "__main__":
    sys.exit(main())
