#!/usr/bin/env python3
"""Behavior and security tests for the private Dozzle alert relay."""

from __future__ import annotations

import contextlib
import http.client
import importlib.util
import io
import json
import os
from pathlib import Path
import stat
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


ROOT = Path(__file__).resolve().parents[1]
RELAY_PATH = ROOT / "services" / "dozzle" / "alert_relay.py"
RELAY_TOKEN = "relay-secret-that-must-not-leak"
NTFY_TOKEN = "ntfy-secret-that-must-not-leak"
CONTAINER_ID = "a" * 64


def load_relay_module():
    spec = importlib.util.spec_from_file_location("dozzle_alert_relay", RELAY_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError("could not load relay module")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class RecordingNtfyHandler(BaseHTTPRequestHandler):
    server_version = "FakeNtfy/1"

    def do_POST(self):  # noqa: N802 - BaseHTTPRequestHandler API
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length)
        self.server.requests.append(
            {
                "path": self.path,
                "authorization": self.headers.get("Authorization"),
                "content_type": self.headers.get("Content-Type"),
                "json": json.loads(body.decode("utf-8")),
            }
        )
        self.send_response(self.server.response_status)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def log_message(self, _format, *_args):
        pass


class DozzleAlertRelayTest(unittest.TestCase):
    def setUp(self):
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary_directory.cleanup)
        self.state_directory = Path(self.temporary_directory.name) / "state"
        self.state_directory.mkdir(mode=0o700)
        self.state_path = self.state_directory / "alert-relay.json"

        self.ntfy = ThreadingHTTPServer(("127.0.0.1", 0), RecordingNtfyHandler)
        self.ntfy.requests = []
        self.ntfy.response_status = 200
        self.ntfy_thread = threading.Thread(target=self.ntfy.serve_forever, daemon=True)
        self.ntfy_thread.start()
        self.addCleanup(self.stop_server, self.ntfy, self.ntfy_thread)

        self.relay_module = load_relay_module()
        self.config = self.relay_module.Config.from_mapping(
            {
                "ALERT_RELAY_TOKEN": RELAY_TOKEN,
                "NTFY_PUBLISH_URL": f"http://127.0.0.1:{self.ntfy.server_port}/",
                "NTFY_TOPIC": "nas-critical",
                "NTFY_TOKEN": NTFY_TOKEN,
                "ALERT_STATE_PATH": str(self.state_path),
            }
        )
        self.relay = self.relay_module.create_server(("127.0.0.1", 0), self.config)
        self.relay_thread = threading.Thread(target=self.relay.serve_forever, daemon=True)
        self.relay_thread.start()
        self.addCleanup(self.stop_server, self.relay, self.relay_thread)

    @staticmethod
    def stop_server(server, thread):
        server.shutdown()
        server.server_close()
        thread.join(timeout=3)

    @staticmethod
    def envelope(rule="Unhealthy", **changes):
        relationships = {
            "OOM": ("oom", "", ""),
            "Unexpected exit": ("die", "", "1"),
            "Unhealthy": ("health_status", "unhealthy", ""),
            "Recovery": ("health_status", "healthy", ""),
        }
        event, health_status, exit_code = relationships[rule]
        payload = {
            "version": 1,
            "rule": rule,
            "containerId": CONTAINER_ID,
            "container": "paperless_webserver",
            "host": "nas",
            "event": event,
            "healthStatus": health_status,
            "exitCode": exit_code,
            "timestamp": "2026-08-15T01:22:13Z",
        }
        payload.update(changes)
        return payload

    def request(self, method, path, body=b"", token=RELAY_TOKEN, headers=None):
        if isinstance(body, dict):
            body = json.dumps(body, separators=(",", ":")).encode("utf-8")
        request_headers = dict(headers or {})
        if token is not None:
            request_headers["Authorization"] = f"Bearer {token}"
        if body:
            request_headers.setdefault("Content-Type", "application/json")
            request_headers["Content-Length"] = str(len(body))
        connection = http.client.HTTPConnection("127.0.0.1", self.relay.server_port, timeout=3)
        connection.request(method, path, body=body, headers=request_headers)
        response = connection.getresponse()
        response_body = response.read()
        connection.close()
        return response.status, response_body

    def post(self, payload, **kwargs):
        return self.request("POST", "/alerts", payload, **kwargs)

    def read_state(self):
        return json.loads(self.state_path.read_text(encoding="utf-8"))

    def test_health_and_route_surface_are_exact(self):
        self.assertEqual(self.request("GET", "/healthz", token=None)[0], 200)
        self.assertEqual(self.request("GET", "/alerts", token=None)[0], 404)
        self.assertEqual(self.request("GET", "/unknown", token=None)[0], 404)
        self.assertEqual(self.request("POST", "/healthz", {}, token=RELAY_TOKEN)[0], 404)

    def test_missing_and_wrong_bearer_tokens_are_rejected_without_side_effects(self):
        for token in (None, "", "wrong-token", f"{RELAY_TOKEN}extra"):
            with self.subTest(token=token):
                status_code, _body = self.post(self.envelope(), token=token)
                self.assertEqual(status_code, 401)
        self.assertEqual(self.ntfy.requests, [])
        self.assertFalse(self.state_path.exists())

    def test_schema_and_encoding_are_strict(self):
        cases = {
            "unknown version": {"version": 2},
            "missing key": {"remove": "host"},
            "unknown key": {"extra": "value"},
            "unknown rule": {"rule": "Started"},
            "bad relationship": {"healthStatus": "healthy"},
            "bad exit": {"exitCode": "not-a-number"},
            "control character": {"container": "bad\nname"},
            "long display value": {"host": "x" * 257},
            "bad container id": {"containerId": "../escape"},
            "bad timestamp": {"timestamp": "today"},
        }
        for name, mutation in cases.items():
            payload = self.envelope()
            removed = mutation.pop("remove", None)
            if removed:
                payload.pop(removed)
            payload.update(mutation)
            with self.subTest(name=name):
                status_code, _body = self.post(payload)
                self.assertEqual(status_code, 400)

        invalid_utf8 = b'{"version":1,"rule":"\xff"}'
        self.assertEqual(self.request("POST", "/alerts", invalid_utf8)[0], 400)
        duplicate_key = (
            json.dumps(self.envelope(), separators=(",", ":"))[:-1]
            + ',"host":"duplicate"}'
        ).encode("utf-8")
        self.assertEqual(self.request("POST", "/alerts", duplicate_key)[0], 400)
        oversized = b"{" + (b" " * (16 * 1024)) + b"}"
        self.assertEqual(self.request("POST", "/alerts", oversized)[0], 413)
        self.assertEqual(self.ntfy.requests, [])
        self.assertFalse(self.state_path.exists())

    def test_unhealthy_renders_exact_structured_ntfy_root_request(self):
        status_code, body = self.post(self.envelope())

        self.assertEqual((status_code, body), (204, b""))
        self.assertEqual(
            self.ntfy.requests,
            [
                {
                    "path": "/",
                    "authorization": f"Bearer {NTFY_TOKEN}",
                    "content_type": "application/json",
                    "json": {
                        "topic": "nas-critical",
                        "title": "Unhealthy · paperless_webserver",
                        "message": "**Host:** `nas`\n**Container:** `paperless_webserver`\n**Status:** `unhealthy`",
                        "priority": 5,
                        "tags": ["rotating_light", "warning"],
                        "markdown": True,
                    },
                }
            ],
        )

    def test_all_rule_renderings_are_human_readable_and_fixed(self):
        cases = [
            (
                "Unexpected exit",
                "Unexpected exit · service",
                "**Host:** `nas`\n**Container:** `service`\n**Exit code:** `23`",
                5,
                ["warning", "skull"],
                {"container": "service", "exitCode": "23"},
            ),
            (
                "OOM",
                "Out of memory · service",
                "**Host:** `nas`\n**Container:** `service`\n**Status:** `out of memory`",
                5,
                ["rotating_light", "skull"],
                {"container": "service"},
            ),
        ]
        for rule, title, message, priority, tags, changes in cases:
            with self.subTest(rule=rule):
                self.assertEqual(self.post(self.envelope(rule, **changes))[0], 204)
                published = self.ntfy.requests[-1]["json"]
                self.assertEqual(published["title"], title)
                self.assertEqual(published["message"], message)
                self.assertEqual(published["priority"], priority)
                self.assertEqual(published["tags"], tags)
                self.assertIs(published["markdown"], True)

    def test_unhealthy_recovery_transition_and_duplicate_suppression(self):
        healthy = self.envelope(
            "Recovery", container="immich_server", containerId="b" * 64
        )
        unhealthy = self.envelope(
            "Unhealthy", container="immich_server", containerId="b" * 64
        )

        self.assertEqual(self.post(healthy)[0], 204)
        self.assertEqual(len(self.ntfy.requests), 0)
        self.assertFalse(self.state_path.exists())

        self.assertEqual(self.post(unhealthy)[0], 204)
        self.assertEqual(self.post(unhealthy)[0], 204)
        self.assertEqual(
            self.read_state(),
            {"version": 1, "unhealthy": [f"nas\0{'b' * 64}"]},
        )
        self.assertEqual(len(self.ntfy.requests), 2)

        self.assertEqual(self.post(healthy)[0], 204)
        self.assertEqual(
            self.ntfy.requests[-1]["json"],
            {
                "topic": "nas-critical",
                "title": "Recovered · immich_server",
                "message": "**Host:** `nas`\n**Container:** `immich_server`\n**Status:** `healthy`",
                "priority": 3,
                "tags": ["white_check_mark"],
                "markdown": True,
            },
        )
        self.assertEqual(self.read_state(), {"version": 1, "unhealthy": []})
        self.assertEqual(self.post(healthy)[0], 204)
        self.assertEqual(len(self.ntfy.requests), 3)

    def test_exit_and_oom_always_publish_without_changing_state(self):
        for _iteration in range(2):
            self.assertEqual(self.post(self.envelope("Unexpected exit"))[0], 204)
            self.assertEqual(self.post(self.envelope("OOM"))[0], 204)
        self.assertEqual(len(self.ntfy.requests), 4)
        self.assertFalse(self.state_path.exists())

    def test_state_is_atomic_versioned_and_mode_0600(self):
        self.assertEqual(self.post(self.envelope())[0], 204)
        state = self.read_state()
        self.assertEqual(state, {"version": 1, "unhealthy": [f"nas\0{CONTAINER_ID}"]})
        self.assertEqual(stat.S_IMODE(self.state_path.stat().st_mode), 0o600)
        self.assertEqual(self.state_path.stat().st_uid, os.geteuid())
        leftovers = [path.name for path in self.state_directory.iterdir() if path.name.endswith(".tmp")]
        self.assertEqual(leftovers, [])

    def test_corrupt_symlink_and_unsafe_state_fail_closed(self):
        fixtures = ("corrupt", "corrupt-entry", "symlink", "unsafe-mode")
        for fixture in fixtures:
            with self.subTest(fixture=fixture):
                with contextlib.suppress(FileNotFoundError):
                    self.state_path.unlink()
                if fixture == "corrupt":
                    self.state_path.write_text("not-json", encoding="utf-8")
                    self.state_path.chmod(0o600)
                elif fixture == "corrupt-entry":
                    self.state_path.write_text(
                        '{"version":1,"unhealthy":[{}]}', encoding="utf-8"
                    )
                    self.state_path.chmod(0o600)
                elif fixture == "symlink":
                    target = self.state_directory / "target"
                    target.write_text('{"version":1,"unhealthy":[]}', encoding="utf-8")
                    target.chmod(0o600)
                    self.state_path.symlink_to(target)
                else:
                    self.state_path.write_text('{"version":1,"unhealthy":[]}', encoding="utf-8")
                    self.state_path.chmod(0o666)

                before = len(self.ntfy.requests)
                status_code, response_body = self.post(self.envelope())
                self.assertEqual(status_code, 500)
                self.assertEqual(response_body, b"state unavailable\n")
                self.assertEqual(len(self.ntfy.requests), before)

    def test_upstream_failure_does_not_commit_transition(self):
        self.ntfy.response_status = 503
        status_code, response_body = self.post(self.envelope())
        self.assertEqual(status_code, 502)
        self.assertEqual(response_body, b"upstream unavailable\n")
        self.assertFalse(self.state_path.exists())

        self.ntfy.response_status = 200
        self.assertEqual(self.post(self.envelope())[0], 204)
        expected_state = self.read_state()
        self.ntfy.response_status = 503
        self.assertEqual(self.post(self.envelope("Recovery"))[0], 502)
        self.assertEqual(self.read_state(), expected_state)

    def test_markdown_is_escaped_and_diagnostics_are_redacted(self):
        payload = self.envelope(container="svc`_*[]()\\", host="nas`host")
        captured = io.StringIO()
        with contextlib.redirect_stderr(captured):
            status_code, response_body = self.post(payload)
            wrong_status, wrong_body = self.post(payload, token="request-secret")
        self.assertEqual(status_code, 204)
        self.assertEqual(wrong_status, 401)
        published = self.ntfy.requests[0]["json"]
        self.assertEqual(published["title"], "Unhealthy · svc\\`\\_\\*\\[\\]\\(\\)\\\\")
        self.assertIn("`svc\\`\\_\\*\\[\\]\\(\\)\\\\`", published["message"])
        combined = captured.getvalue() + response_body.decode() + wrong_body.decode()
        for secret in (RELAY_TOKEN, NTFY_TOKEN, "request-secret"):
            self.assertNotIn(secret, combined)


if __name__ == "__main__":
    unittest.main()
