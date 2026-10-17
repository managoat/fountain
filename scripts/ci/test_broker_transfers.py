"""Exercise real curl redirects/reuse against disposable local HTTP fixtures."""

import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import importlib.util
import json
from pathlib import Path
import shutil
import threading
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location(
    "broker_transfers", Path(__file__).resolve().parents[1] / "load-test" / "broker_transfers.py"
)
transfers = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(transfers)
BODY = b"verified public fixture\n"


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_args):
        pass

    def do_GET(self):
        body = BODY
        if self.path == "/chunked":
            self.send_response(200)
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            self.wfile.write(b"16\r\n" + BODY + b"\r\n0\r\n\r\n")
            return
        if self.path == "/redirect":
            self.send_response(302)
            self.send_header("Location", "/file?signature=must-not-appear")
            body = b""
        elif self.path == "/loop":
            self.send_response(302)
            self.send_header("Location", "/loop")
            body = b""
        elif self.path == "/denied":
            self.send_response(403)
        else:
            self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


@unittest.skipUnless(shutil.which("curl"), "curl required")
class TransfersTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join()

    def case(self, path, digest=None):
        return {"name": "fixture", "url": f"http://127.0.0.1:{self.server.server_port}{path}",
                "sha256": digest or hashlib.sha256(BODY).hexdigest()}

    def test_redirect_and_reuse_do_not_export_location_or_proxy_environment(self):
        with patch.dict("os.environ", {"http_proxy": "http://invalid.invalid:1",
                                       "ALL_PROXY": "http://invalid.invalid:1"}):
            rows = transfers.transfer(self.case("/redirect"), "direct", 2)
        self.assertEqual([row["num_redirects"] for row in rows], [1, 1])
        self.assertEqual([row["num_connects"] for row in rows], [1, 0])
        self.assertTrue(all(row["ok"] for row in rows))
        self.assertEqual(rows[1]["connection_context"], "reuse_eligible")
        self.assertNotIn("signature", json.dumps(rows))
        self.assertNotIn("127.0.0.1", json.dumps(rows))

    def test_integrity_and_http_failure_remain_failures(self):
        wrong = transfers.transfer(self.case("/file", "0" * 64), "direct", 1)[0]
        self.assertFalse(wrong["ok"])
        self.assertFalse(wrong["integrity_ok"])
        denied = transfers.transfer(self.case("/denied"), "direct", 1)[0]
        self.assertFalse(denied["ok"])
        self.assertEqual(denied["response_code"], 403)

    def test_redirect_loop_is_bounded_and_retained(self):
        row = transfers.transfer(self.case("/loop"), "direct", 1)[0]
        self.assertFalse(row["ok"])
        self.assertEqual(row["exitcode"], 47)
        self.assertEqual(row["num_redirects"], 10)

    def test_unknown_length_download_limit_is_enforced(self):
        row = transfers.transfer(self.case("/chunked"), "direct", 1, max_bytes=5)[0]
        self.assertFalse(row["ok"])
        self.assertEqual(row["exitcode"], 63)

    def test_proxy_route_does_not_honor_no_proxy_bypass(self):
        with patch.dict("os.environ", {"NO_PROXY": "*"}):
            row = transfers.transfer(self.case("/file"), "proxy", 1,
                                     proxy="http://127.0.0.1:1")[0]
        self.assertFalse(row["ok"])
        self.assertNotEqual(row["exitcode"], 0)

    def test_config_cannot_inject_headers_and_metrics_errors_are_redacted(self):
        with self.assertRaises(ValueError):
            transfers.quote('https://example.test/\nheader="secret"')
        with patch.object(transfers.subprocess, "run") as run:
            run.return_value.stdout = "https://private.test/?secret=abc"
            rows = transfers.transfer(self.case("/file"), "direct", 1)
        self.assertEqual(rows[0]["error"], "invalid_curl_metrics")
        self.assertNotIn("secret", json.dumps(rows))
        self.assertEqual(run.call_args.args[0], ["curl", "-q", "--config", "-"])


if __name__ == "__main__":
    unittest.main()
