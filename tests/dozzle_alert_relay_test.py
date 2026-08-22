#!/usr/bin/env python3
"""Behavior and security tests for the private Dozzle alert relay."""

from __future__ import annotations

import contextlib
from datetime import datetime, timezone
import fcntl
import http.client
import importlib.util
import io
import json
import os
from pathlib import Path
import socket
import stat
import tempfile
import threading
import time
import unittest
from unittest import mock
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


ROOT = Path(__file__).resolve().parents[1]
RELAY_PATH = ROOT / "services" / "dozzle" / "alert_relay.py"
RELAY_TOKEN = "relay-secret-that-must-not-leak"
NTFY_TOKEN = "ntfy-secret-that-must-not-leak"
CONTAINER_ID = "a" * 64
# The listener port the deployment declares today, in roles/dozzle/defaults.
# Nothing here depends on the number staying current: these tests only need a
# port that differs from any literal the relay itself could have kept, so a
# stale value would still select a usable one.
DEPLOYED_PORT = 8081


def reserve_local_port():
    """Return a free local TCP port, deliberately never the deployed default."""
    while True:
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
            probe.bind(("127.0.0.1", 0))
            port = probe.getsockname()[1]
        if port != DEPLOYED_PORT:
            return port


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


class RedirectHandler(BaseHTTPRequestHandler):
    def do_POST(self):  # noqa: N802 - BaseHTTPRequestHandler API
        self.send_response(302)
        self.send_header("Location", self.server.target_url)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def log_message(self, _format, *_args):
        pass


class RedirectTargetHandler(BaseHTTPRequestHandler):
    def capture(self):
        self.server.requests.append(
            {
                "method": self.command,
                "path": self.path,
                "authorization": self.headers.get("Authorization"),
            }
        )
        self.send_response(204)
        self.send_header("Content-Length", "0")
        self.end_headers()

    do_GET = capture  # noqa: N815 - BaseHTTPRequestHandler API
    do_POST = capture  # noqa: N815 - BaseHTTPRequestHandler API

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
                "ALERT_RELAY_PORT": str(DEPLOYED_PORT),
                "NTFY_PUBLISH_URL": f"http://127.0.0.1:{self.ntfy.server_port}/",
                "NTFY_TOPIC": "nas-critical",
                "NTFY_CONTAINERS_TOPIC": "nas-containers",
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

    def write_state(self, document):
        self.state_path.write_text(
            json.dumps(document, ensure_ascii=False, separators=(",", ":")) + "\n",
            encoding="utf-8",
        )
        self.state_path.chmod(0o600)

    def write_ascii_state(self, document):
        self.state_path.write_bytes(
            json.dumps(document, ensure_ascii=True, separators=(",", ":")).encode(
                "ascii"
            )
            + b"\n"
        )
        self.state_path.chmod(0o600)

    def request_with_fifo_guard(
        self, fifo_path, method, path, body=b"", token=RELAY_TOKEN
    ):
        outcome = {}

        def run_request():
            try:
                outcome["response"] = self.request(method, path, body, token=token)
            except Exception as error:  # captured for the calling test thread
                outcome["error"] = error

        started = time.monotonic()
        request_thread = threading.Thread(target=run_request, daemon=True)
        request_thread.start()
        request_thread.join(timeout=0.3)
        blocked = request_thread.is_alive()
        unblock_fd = None
        if blocked:
            unblock_fd = os.open(fifo_path, os.O_RDWR | os.O_NONBLOCK)
            request_thread.join(timeout=3)
        if unblock_fd is not None:
            os.close(unblock_fd)
        self.assertFalse(
            request_thread.is_alive(), "FIFO request could not be unblocked"
        )
        if "error" in outcome:
            raise outcome["error"]
        return blocked, time.monotonic() - started, outcome["response"]

    @staticmethod
    def state_entry(container_id, state, timestamp, host="nas"):
        return {
            "identity": f"{host}\0{container_id}",
            "state": state,
            "timestamp": timestamp,
        }

    def test_health_and_route_surface_are_exact(self):
        self.assertEqual(self.request("GET", "/healthz", token=None)[0], 200)
        self.assertEqual(self.request("GET", "/alerts", token=None)[0], 404)
        self.assertEqual(self.request("GET", "/unknown", token=None)[0], 404)
        self.assertEqual(self.request("POST", "/healthz", {}, token=RELAY_TOKEN)[0], 404)

    def test_health_validates_state_without_waiting_for_an_active_lock(self):
        self.assertEqual(
            self.request("GET", "/healthz", token=None), (200, b"ok\n")
        )
        self.assertEqual(self.post(self.envelope()), (204, b""))
        self.assertEqual(
            self.request("GET", "/healthz", token=None), (200, b"ok\n")
        )

        self.state_path.write_text("not-json", encoding="utf-8")
        self.state_path.chmod(0o600)
        self.assertEqual(
            self.request("GET", "/healthz", token=None),
            (503, b"state unavailable\n"),
        )

        self.write_state({"version": 2, "entries": []})
        self.state_path.chmod(0o640)
        self.assertEqual(self.request("GET", "/healthz", token=None)[0], 503)
        self.state_path.chmod(0o600)

        self.state_path.unlink()
        target = self.state_directory / "health-target"
        target.write_text('{"version":2,"entries":[]}', encoding="utf-8")
        target.chmod(0o600)
        self.state_path.symlink_to(target)
        self.assertEqual(self.request("GET", "/healthz", token=None)[0], 503)
        self.state_path.unlink()

        self.state_directory.chmod(0o755)
        self.assertEqual(self.request("GET", "/healthz", token=None)[0], 503)
        self.state_directory.chmod(0o700)

        lock_path = self.state_directory / f".{self.state_path.name}.lock"
        with contextlib.suppress(FileNotFoundError):
            lock_path.unlink()
        lock_target = self.state_directory / "lock-target"
        lock_target.write_text("", encoding="utf-8")
        lock_target.chmod(0o600)
        lock_path.symlink_to(lock_target)
        self.assertEqual(self.request("GET", "/healthz", token=None)[0], 503)
        lock_path.unlink()

        self.write_state({"version": 2, "entries": []})
        lock_fd = os.open(lock_path, os.O_RDWR | os.O_CREAT, 0o600)
        self.addCleanup(os.close, lock_fd)
        fcntl.flock(lock_fd, fcntl.LOCK_EX)
        started = time.monotonic()
        self.assertEqual(
            self.request("GET", "/healthz", token=None), (200, b"ok\n")
        )
        self.assertLess(time.monotonic() - started, 1)
        fcntl.flock(lock_fd, fcntl.LOCK_UN)

    def test_missing_and_wrong_bearer_tokens_are_rejected_without_side_effects(self):
        for token in (None, "", "wrong-token", f"{RELAY_TOKEN}extra"):
            with self.subTest(token=token):
                status_code, _body = self.post(self.envelope(), token=token)
                self.assertEqual(status_code, 401)
        self.assertEqual(self.ntfy.requests, [])
        self.assertFalse(self.state_path.exists())

    def test_non_ascii_bearer_is_rejected_without_traceback_or_side_effects(self):
        captured = io.StringIO()
        with contextlib.redirect_stderr(captured):
            status_code, response_body = self.post(self.envelope(), token="\xff")

        self.assertEqual((status_code, response_body), (401, b"unauthorized\n"))
        self.assertNotIn("Traceback", captured.getvalue())
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

    def test_unpaired_surrogates_are_rejected_in_every_string_field(self):
        string_fields = (
            "rule",
            "containerId",
            "container",
            "host",
            "event",
            "healthStatus",
            "exitCode",
            "timestamp",
        )
        captured = io.StringIO()
        with contextlib.redirect_stderr(captured):
            for field in string_fields:
                with self.subTest(field=field):
                    payload = self.envelope()
                    payload[field] = "\ud800"
                    raw = json.dumps(
                        payload, ensure_ascii=True, separators=(",", ":")
                    ).encode("ascii")
                    try:
                        result = self.request("POST", "/alerts", raw)
                    except http.client.RemoteDisconnected:
                        result = (None, b"connection closed")
                    self.assertEqual(result, (400, b"invalid request\n"))
                    self.assertEqual(self.ntfy.requests, [])
                    self.assertFalse(self.state_path.exists())
        self.assertNotIn("Traceback", captured.getvalue())

    def test_unexpected_exit_requires_canonical_nonzero_decimal_code(self):
        for exit_code in ("00", "000", "01", "0130", "0137", "0143", "1\u0662"):
            with self.subTest(exit_code=exit_code):
                status_code, response_body = self.post(
                    self.envelope("Unexpected exit", exitCode=exit_code)
                )
                self.assertEqual((status_code, response_body), (400, b"invalid request\n"))

        self.assertEqual(self.ntfy.requests, [])
        self.assertFalse(self.state_path.exists())

    def test_timestamp_is_a_real_canonical_utc_instant(self):
        leap_day = self.envelope("OOM", timestamp="2024-02-29T23:59:59Z")
        self.assertEqual(self.post(leap_day), (204, b""))
        fractional_leap_day = self.envelope(
            "OOM", timestamp="2024-02-29T23:59:59.123456789Z"
        )
        self.assertEqual(self.post(fractional_leap_day), (204, b""))
        request_count = len(self.ntfy.requests)

        invalid_timestamps = (
            "2023-02-29T23:59:59Z",
            "2026-04-31T01:22:13Z",
            "2026-08-15T24:00:00Z",
            "2026-08-15T01:60:00Z",
            "2026-08-15T01:22:60Z",
            "2024-02-29T23:59:59+00:00",
            "\u0662\u0660\u0662\u0664-02-29T23:59:59Z",
        )
        for timestamp in invalid_timestamps:
            with self.subTest(timestamp=timestamp):
                status_code, response_body = self.post(
                    self.envelope("OOM", timestamp=timestamp)
                )
                self.assertEqual((status_code, response_body), (400, b"invalid request\n"))

        self.assertEqual(len(self.ntfy.requests), request_count)
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

    def test_every_problem_rule_stays_on_the_critical_topic(self):
        """Only a recovery is routed away; a problem must never be downgraded."""

        for rule, changes in (
            ("Unexpected exit", {"exitCode": "23"}),
            ("OOM", {}),
            ("Unhealthy", {}),
        ):
            with self.subTest(rule=rule):
                self.assertEqual(self.post(self.envelope(rule, **changes))[0], 204)
                self.assertEqual(
                    self.ntfy.requests[-1]["json"]["topic"], "nas-critical"
                )

    def test_config_requires_two_distinct_topics(self):
        base = {
            "ALERT_RELAY_TOKEN": RELAY_TOKEN,
            "ALERT_RELAY_PORT": str(DEPLOYED_PORT),
            "NTFY_PUBLISH_URL": "http://127.0.0.1:1/",
            "NTFY_TOPIC": "nas-critical",
            "NTFY_CONTAINERS_TOPIC": "nas-containers",
            "NTFY_TOKEN": NTFY_TOKEN,
            "ALERT_STATE_PATH": str(self.state_path),
        }
        self.relay_module.Config.from_mapping(base)

        for label, mutation in (
            ("missing", {"NTFY_CONTAINERS_TOPIC": ""}),
            ("invalid", {"NTFY_CONTAINERS_TOPIC": "nas events"}),
            # One topic under two names silently reunites the two streams.
            ("identical", {"NTFY_CONTAINERS_TOPIC": "nas-critical"}),
        ):
            with self.subTest(label=label):
                with self.assertRaises(self.relay_module.ConfigurationError):
                    self.relay_module.Config.from_mapping({**base, **mutation})

    def test_config_requires_a_usable_listener_port(self):
        base = {
            "ALERT_RELAY_TOKEN": RELAY_TOKEN,
            "ALERT_RELAY_PORT": str(DEPLOYED_PORT),
            "NTFY_PUBLISH_URL": "http://127.0.0.1:1/",
            "NTFY_TOPIC": "nas-critical",
            "NTFY_CONTAINERS_TOPIC": "nas-containers",
            "NTFY_TOKEN": NTFY_TOKEN,
            "ALERT_STATE_PATH": str(self.state_path),
        }
        self.assertEqual(
            self.relay_module.Config.from_mapping(base).alert_relay_port, DEPLOYED_PORT
        )

        for label, value in (
            # There is no fallback on purpose: a default here would be a second
            # copy of a value that has exactly one home in the Ansible defaults.
            ("missing", None),
            ("empty", ""),
            ("zero", "0"),
            ("padded", f" {DEPLOYED_PORT}"),
            ("leading zero", f"0{DEPLOYED_PORT}"),
            ("out of range", "65536"),
            ("not a number", "eighty-eighty-one"),
        ):
            with self.subTest(label=label):
                mutated = dict(base)
                if value is None:
                    del mutated["ALERT_RELAY_PORT"]
                else:
                    mutated["ALERT_RELAY_PORT"] = value
                with self.assertRaises(self.relay_module.ConfigurationError):
                    self.relay_module.Config.from_mapping(mutated)

    def test_entry_point_serves_on_the_configured_listener_port(self):
        # The port is read back from a live listener rather than from the relay's
        # source text: a main() that ignored ALERT_RELAY_PORT and bound its own
        # number would leave nothing answering here.
        port = reserve_local_port()
        self.assertNotEqual(port, DEPLOYED_PORT)
        created = []
        real_create_server = self.relay_module.create_server

        def capture(address, config):
            server = real_create_server(address, config)
            created.append(server)
            return server

        environment = {
            "ALERT_RELAY_TOKEN": RELAY_TOKEN,
            "ALERT_RELAY_PORT": str(port),
            "NTFY_PUBLISH_URL": f"http://127.0.0.1:{self.ntfy.server_port}/",
            "NTFY_TOPIC": "nas-critical",
            "NTFY_CONTAINERS_TOPIC": "nas-containers",
            "NTFY_TOKEN": NTFY_TOKEN,
            "ALERT_STATE_PATH": str(self.state_path),
        }
        with mock.patch.object(self.relay_module, "create_server", capture), \
                mock.patch.dict(os.environ, environment):
            thread = threading.Thread(target=self.relay_module.main, daemon=True)
            thread.start()
            try:
                deadline = time.monotonic() + 5
                while not created and time.monotonic() < deadline:
                    time.sleep(0.01)
                self.assertTrue(created, "the entry point started no listener")
                self.assertEqual(created[0].server_address[1], port)
                connection = http.client.HTTPConnection("127.0.0.1", port, timeout=3)
                connection.request("GET", "/healthz")
                response = connection.getresponse()
                body = response.read()
                connection.close()
                self.assertEqual((response.status, body), (200, b"ok\n"))
            finally:
                if created:
                    created[0].shutdown()
                thread.join(timeout=5)
        self.assertFalse(thread.is_alive())

    def test_unhealthy_recovery_transition_and_duplicate_suppression(self):
        healthy = self.envelope(
            "Recovery",
            container="immich_server",
            containerId="b" * 64,
            timestamp="2026-08-15T01:22:12Z",
        )
        unhealthy = self.envelope(
            "Unhealthy",
            container="immich_server",
            containerId="b" * 64,
            timestamp="2026-08-15T01:22:13Z",
        )

        self.assertEqual(self.post(healthy)[0], 204)
        self.assertEqual(len(self.ntfy.requests), 0)
        self.assertEqual(
            self.read_state(),
            {
                "version": 2,
                "entries": [
                    self.state_entry("b" * 64, "healthy", "2026-08-15T01:22:12Z")
                ],
            },
        )

        self.assertEqual(self.post(unhealthy)[0], 204)
        self.assertEqual(self.post(unhealthy)[0], 204)
        self.assertEqual(
            self.read_state(),
            {
                "version": 2,
                "entries": [
                    self.state_entry("b" * 64, "unhealthy", "2026-08-15T01:22:13Z")
                ],
            },
        )
        self.assertEqual(len(self.ntfy.requests), 2)

        recovered = dict(healthy, timestamp="2026-08-15T01:22:14Z")
        self.assertEqual(self.post(recovered)[0], 204)
        self.assertEqual(
            self.ntfy.requests[-1]["json"],
            {
                # A recovery is a record, not an emergency: events topic.
                "topic": "nas-containers",
                "title": "Recovered · immich_server",
                "message": "**Host:** `nas`\n**Container:** `immich_server`\n**Status:** `healthy`",
                "priority": 3,
                "tags": ["white_check_mark"],
                "markdown": True,
            },
        )
        self.assertEqual(
            self.read_state(),
            {
                "version": 2,
                "entries": [
                    self.state_entry("b" * 64, "healthy", "2026-08-15T01:22:14Z")
                ],
            },
        )
        self.assertEqual(self.post(recovered)[0], 204)
        self.assertEqual(len(self.ntfy.requests), 3)

    def test_later_recovery_wins_when_older_unhealthy_arrives_late(self):
        identity = "b" * 64
        recovery = self.envelope(
            "Recovery", containerId=identity, timestamp="2026-08-15T01:22:14.000000001Z"
        )
        stale_unhealthy = self.envelope(
            "Unhealthy", containerId=identity, timestamp="2026-08-15T01:22:13.999999999Z"
        )

        self.assertEqual(self.post(recovery), (204, b""))
        self.assertEqual(self.post(stale_unhealthy), (204, b""))
        self.assertEqual(self.ntfy.requests, [])
        expected = {
            "version": 2,
            "entries": [
                self.state_entry(identity, "healthy", "2026-08-15T01:22:14.000000001Z")
            ],
        }
        self.assertEqual(self.read_state(), expected)

        restarted = self.relay_module.create_server(("127.0.0.1", 0), self.config)
        restarted_thread = threading.Thread(target=restarted.serve_forever, daemon=True)
        restarted_thread.start()
        self.addCleanup(self.stop_server, restarted, restarted_thread)
        original_relay = self.relay
        self.relay = restarted
        try:
            self.assertEqual(self.post(stale_unhealthy), (204, b""))
        finally:
            self.relay = original_relay
        self.assertEqual(self.ntfy.requests, [])
        self.assertEqual(self.read_state(), expected)

    def test_equal_timestamp_health_ordering_is_deterministic(self):
        timestamp = "2026-08-15T01:22:14.123456789Z"
        recovery_first_id = "b" * 64
        recovery_first = self.envelope(
            "Recovery", containerId=recovery_first_id, timestamp=timestamp
        )
        unhealthy_after = self.envelope(
            "Unhealthy", containerId=recovery_first_id, timestamp=timestamp
        )
        self.assertEqual(self.post(recovery_first), (204, b""))
        self.assertEqual(self.post(unhealthy_after), (204, b""))
        self.assertEqual(self.ntfy.requests, [])

        unhealthy_id = "c" * 64
        repeated_unhealthy = self.envelope(
            "Unhealthy", containerId=unhealthy_id, timestamp=timestamp
        )
        equal_recovery = self.envelope(
            "Recovery", containerId=unhealthy_id, timestamp=timestamp
        )
        self.assertEqual(self.post(repeated_unhealthy), (204, b""))
        self.assertEqual(self.post(repeated_unhealthy), (204, b""))
        self.assertEqual(self.post(equal_recovery), (204, b""))
        self.assertEqual(self.post(repeated_unhealthy), (204, b""))
        self.assertEqual(len(self.ntfy.requests), 3)
        entries = {entry["identity"]: entry for entry in self.read_state()["entries"]}
        self.assertEqual(entries[f"nas\0{recovery_first_id}"]["state"], "healthy")
        self.assertEqual(entries[f"nas\0{unhealthy_id}"]["state"], "healthy")

    def test_version_one_state_migrates_without_discarding_unhealthy(self):
        first_id = "b" * 64
        second_id = "c" * 64
        self.write_state(
            {
                "version": 1,
                "unhealthy": sorted([f"nas\0{first_id}", f"nas\0{second_id}"]),
            }
        )

        recovery = self.envelope(
            "Recovery", containerId=first_id, timestamp="2026-08-15T01:22:14Z"
        )
        self.assertEqual(self.post(recovery), (204, b""))

        self.assertEqual(len(self.ntfy.requests), 1)
        self.assertEqual(
            self.read_state(),
            {
                "version": 2,
                "entries": [
                    self.state_entry(first_id, "healthy", "2026-08-15T01:22:14Z"),
                    self.state_entry(second_id, "unhealthy", "0001-01-01T00:00:00Z"),
                ],
            },
        )

    def test_healthy_tombstone_retention_is_bounded(self):
        now = datetime(2026, 8, 15, 12, 0, tzinfo=timezone.utc)
        old_id = "b" * 64
        recent_id = "c" * 64
        unhealthy_id = "d" * 64
        entries = [
            self.state_entry(old_id, "healthy", "2026-07-15T11:59:59Z"),
            self.state_entry(recent_id, "healthy", "2026-07-17T12:00:00Z"),
            self.state_entry(unhealthy_id, "unhealthy", "2026-01-01T00:00:00Z"),
        ]
        self.write_state({"version": 2, "entries": sorted(entries, key=lambda item: item["identity"])})

        new_id = "e" * 64
        with mock.patch.object(
            self.relay_module, "utc_now", return_value=now, create=True
        ):
            self.assertEqual(
                self.post(
                    self.envelope(
                        "Recovery", containerId=new_id, timestamp="2026-08-15T12:00:00Z"
                    )
                ),
                (204, b""),
            )
        identities = {entry["identity"] for entry in self.read_state()["entries"]}
        self.assertNotIn(f"nas\0{old_id}", identities)
        self.assertIn(f"nas\0{recent_id}", identities)
        self.assertIn(f"nas\0{unhealthy_id}", identities)
        self.assertIn(f"nas\0{new_id}", identities)
        self.assertEqual(self.ntfy.requests, [])

        capped_entries = [
            self.state_entry(
                f"{index:064x}",
                "healthy",
                f"2026-08-15T11:{index // 60:02d}:{index % 60:02d}Z",
            )
            for index in range(128)
        ]
        self.write_state(
            {"version": 2, "entries": sorted(capped_entries, key=lambda item: item["identity"])}
        )
        with mock.patch.object(
            self.relay_module, "utc_now", return_value=now, create=True
        ):
            self.assertEqual(
                self.post(
                    self.envelope(
                        "Recovery", containerId="f" * 64, timestamp="2026-08-15T12:00:00Z"
                    )
                )[0],
                204,
            )
        bounded = self.read_state()["entries"]
        self.assertEqual(len(bounded), 128)
        self.assertNotIn(f"nas\0{0:064x}", {entry["identity"] for entry in bounded})

    def test_unprunable_migration_over_size_limit_fails_before_publish(self):
        identities = [f"{'\u00e9' * 256}\0{index:064x}" for index in range(100)]
        self.write_state({"version": 1, "unhealthy": sorted(identities)})
        original = self.state_path.read_bytes()

        status_code, response_body = self.post(self.envelope("OOM"))

        self.assertEqual((status_code, response_body), (500, b"state unavailable\n"))
        self.assertEqual(self.ntfy.requests, [])
        self.assertEqual(self.state_path.read_bytes(), original)

    def test_exit_and_oom_always_publish_without_changing_state(self):
        for _iteration in range(2):
            self.assertEqual(self.post(self.envelope("Unexpected exit"))[0], 204)
            self.assertEqual(self.post(self.envelope("OOM"))[0], 204)
        self.assertEqual(len(self.ntfy.requests), 4)
        self.assertFalse(self.state_path.exists())

    def test_state_is_atomic_versioned_and_mode_0600(self):
        self.assertEqual(self.post(self.envelope())[0], 204)
        state = self.read_state()
        self.assertEqual(
            state,
            {
                "version": 2,
                "entries": [
                    self.state_entry(
                        CONTAINER_ID, "unhealthy", "2026-08-15T01:22:13Z"
                    )
                ],
            },
        )
        self.assertEqual(stat.S_IMODE(self.state_path.stat().st_mode), 0o600)
        self.assertEqual(self.state_path.stat().st_uid, os.geteuid())
        leftovers = [path.name for path in self.state_directory.iterdir() if path.name.endswith(".tmp")]
        self.assertEqual(leftovers, [])

    def test_state_replace_uses_random_exclusive_names_and_cleans_failures(self):
        collision = self.state_directory / f".{self.state_path.name}.collision.tmp"
        collision.write_text("sentinel", encoding="utf-8")
        collision.chmod(0o600)
        random_source = mock.Mock()
        random_source.token_hex.side_effect = ["collision", "fresh"]

        with mock.patch.object(
            self.relay_module, "secrets", random_source, create=True
        ):
            self.assertEqual(self.post(self.envelope()), (204, b""))

        self.assertEqual(random_source.token_hex.call_count, 2)
        self.assertEqual(collision.read_text(encoding="utf-8"), "sentinel")
        self.assertFalse(
            (self.state_directory / f".{self.state_path.name}.fresh.tmp").exists()
        )
        collision.unlink()

        failed_source = mock.Mock()
        failed_source.token_hex.return_value = "replace-failure"
        with (
            mock.patch.object(self.relay_module, "secrets", failed_source, create=True),
            mock.patch.object(self.relay_module.os, "replace", side_effect=OSError),
        ):
            status_code, response_body = self.post(
                self.envelope(timestamp="2026-08-15T01:22:14Z")
            )
        self.assertEqual((status_code, response_body), (500, b"state unavailable\n"))
        self.assertFalse(
            (
                self.state_directory
                / f".{self.state_path.name}.replace-failure.tmp"
            ).exists()
        )

    def test_publish_refuses_redirects_without_forwarding_token(self):
        target = ThreadingHTTPServer(("127.0.0.1", 0), RedirectTargetHandler)
        target.requests = []
        target_thread = threading.Thread(target=target.serve_forever, daemon=True)
        target_thread.start()
        self.addCleanup(self.stop_server, target, target_thread)

        redirector = ThreadingHTTPServer(("127.0.0.1", 0), RedirectHandler)
        redirector.target_url = f"http://127.0.0.1:{target.server_port}/capture"
        redirect_thread = threading.Thread(
            target=redirector.serve_forever, daemon=True
        )
        redirect_thread.start()
        self.addCleanup(self.stop_server, redirector, redirect_thread)
        self.config.ntfy_publish_url = f"http://127.0.0.1:{redirector.server_port}/"

        status_code, response_body = self.post(self.envelope())

        self.assertEqual((status_code, response_body), (502, b"upstream unavailable\n"))
        self.assertEqual(target.requests, [])
        self.assertFalse(self.state_path.exists())

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

    def test_malformed_version_two_values_fail_closed_without_traceback(self):
        base_entry = self.state_entry(
            CONTAINER_ID, "unhealthy", "2026-08-15T01:22:13Z"
        )
        fixtures = {
            "surrogate identity": dict(base_entry, identity=f"\ud800\0{CONTAINER_ID}"),
            "list state": dict(base_entry, state=[]),
            "mapping state": dict(base_entry, state={}),
        }
        captured = io.StringIO()
        with contextlib.redirect_stderr(captured):
            for name, entry in fixtures.items():
                with self.subTest(name=name):
                    self.write_ascii_state({"version": 2, "entries": [entry]})
                    original = self.state_path.read_bytes()
                    try:
                        health = self.request("GET", "/healthz", token=None)
                    except http.client.RemoteDisconnected:
                        health = (None, b"connection closed")
                    try:
                        posted = self.post(self.envelope("OOM"))
                    except http.client.RemoteDisconnected:
                        posted = (None, b"connection closed")
                    self.assertEqual(health, (503, b"state unavailable\n"))
                    self.assertEqual(posted, (500, b"state unavailable\n"))
                    self.assertEqual(self.ntfy.requests, [])
                    self.assertEqual(self.state_path.read_bytes(), original)
        self.assertNotIn("Traceback", captured.getvalue())

    def test_health_rejects_parseable_state_that_cannot_be_reconciled(self):
        too_many = {
            "version": 1,
            "unhealthy": [f"nas\0{index:064x}" for index in range(129)],
        }
        expanded_too_large = {
            "version": 1,
            "unhealthy": sorted(
                f"{'é' * 256}\0{index:064x}" for index in range(100)
            ),
        }
        for name, document in (
            ("entry bound", too_many),
            ("expanded byte bound", expanded_too_large),
        ):
            with self.subTest(name=name):
                self.write_state(document)
                original = self.state_path.read_bytes()
                self.assertLessEqual(len(original), self.relay_module.MAX_STATE_BYTES)
                health = self.request("GET", "/healthz", token=None)
                posted = self.post(self.envelope("OOM"))
                self.assertEqual(health, (503, b"state unavailable\n"))
                self.assertEqual(posted, (500, b"state unavailable\n"))
                self.assertEqual(self.ntfy.requests, [])
                self.assertEqual(self.state_path.read_bytes(), original)

    @unittest.skipUnless(hasattr(os, "mkfifo"), "FIFO support is required")
    def test_state_and_lock_fifos_fail_promptly_without_side_effects(self):
        captured = io.StringIO()
        with contextlib.redirect_stderr(captured):
            os.mkfifo(self.state_path, 0o600)
            state_results = [
                self.request_with_fifo_guard(
                    self.state_path, "GET", "/healthz", token=None
                ),
                self.request_with_fifo_guard(
                    self.state_path, "POST", "/alerts", self.envelope("OOM")
                ),
            ]
            self.assertTrue(stat.S_ISFIFO(self.state_path.stat().st_mode))
            self.state_path.unlink()

            lock_path = self.state_directory / f".{self.state_path.name}.lock"
            with contextlib.suppress(FileNotFoundError):
                lock_path.unlink()
            os.mkfifo(lock_path, 0o600)
            lock_results = [
                self.request_with_fifo_guard(
                    lock_path, "GET", "/healthz", token=None
                ),
                self.request_with_fifo_guard(
                    lock_path, "POST", "/alerts", self.envelope("OOM")
                ),
            ]
            self.assertTrue(stat.S_ISFIFO(lock_path.stat().st_mode))

        expected = (
            (503, b"state unavailable\n"),
            (500, b"state unavailable\n"),
        )
        for fixture, results in (("state", state_results), ("lock", lock_results)):
            with self.subTest(fixture=fixture):
                self.assertEqual(tuple(result[2] for result in results), expected)
                self.assertFalse(
                    any(result[0] for result in results), "FIFO request hung"
                )
                self.assertTrue(all(result[1] < 1 for result in results))
        self.assertEqual(self.ntfy.requests, [])
        self.assertFalse(self.state_path.exists())
        self.assertNotIn("Traceback", captured.getvalue())

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
        self.assertEqual(published["title"], "Unhealthy · svc`_*[]()\\")
        self.assertIn("`svc\\`\\_\\*\\[\\]\\(\\)\\\\`", published["message"])
        combined = captured.getvalue() + response_body.decode() + wrong_body.decode()
        for secret in (RELAY_TOKEN, NTFY_TOKEN, "request-secret"):
            self.assertNotIn(secret, combined)


if __name__ == "__main__":
    unittest.main()
