#!/usr/bin/env python3
"""Behavior and security tests for the private Dozzle alert relay."""

from __future__ import annotations

import ast
import contextlib
from datetime import datetime, timedelta, timezone
import fcntl
import http.client
import importlib.util
import io
import json
import os
import re
from pathlib import Path
import signal
import socket
import stat
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import urllib.parse
from unittest import mock
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


ROOT = Path(__file__).resolve().parents[1]
RELAY_PATH = ROOT / "services" / "dozzle" / "alert_relay.py"
RELAY_TOKEN = "relay-secret-that-must-not-leak"
PUSHOVER_TOKEN = "pushover-app-secret-that-must-not-leak"
PUSHOVER_USER_KEY = "pushover-user-secret-that-must-not-leak"
CONTAINER_ID = "a" * 64
# A name rather than 127.0.0.1, so a relay that substituted its own host shows.
LINK_BASE = "http://nas.tailnet.example:8080"
# Beszel's app URL as inventory renders it, and a PocketBase record id.
BESZEL_LINK_BASE = "http://nas.tailnet.example:8090"
BESZEL_SYSTEM_ID = "a1b2c3d4e5f6g7h"
ALERTS_TOKEN = "pushover-alerts-secret-that-must-not-leak"
GOLEM_TOKEN = "pushover-golem-secret-that-must-not-leak"
# Deliberately not the deployment's 10/25/200, so a relay ignoring its
# configuration cannot pass on a literal.
CONTAINER_CEILING = 3
OOM_CONTAINER_CEILING = 5
GLOBAL_CEILING = 9
# An `&` that does not begin one of the five entities html.escape writes.
HALF_ENTITY = re.compile(r"&(?!amp;|lt;|gt;|quot;|#x27;)")


def message_shape(message):
    """A message's lead line, its detail labels in order, and its closing line."""
    blocks = message.split("\n\n")
    closing = blocks.pop() if len(blocks) > 1 and blocks[-1].startswith("<i>") else ""
    details = blocks[1].split("\n") if len(blocks) > 1 else []
    labels = []
    for line in details:
        matched = re.fullmatch(r"\S+ <b>([^<]+)</b> .+", line)
        if matched is None:
            raise AssertionError(f"not an `emoji <b>Label</b> value` detail line: {line!r}")
        labels.append(matched.group(1))
    return {"lead": blocks[0], "labels": labels, "closing": closing}
# Pinned just after the fixtures' timestamps: the relay prunes against its clock,
# so the real clock would change verdicts as the date moves.
FIXED_NOW = datetime(2026, 8, 15, 12, 0, tzinfo=timezone.utc)
# Only needs to differ from any literal the relay could have kept.
DEPLOYED_PORT = 8081
# Environment inputs so the harness can shorten them: a hardcoded wait becomes a
# floor the gate cannot parallelise away (#319, #485).
RELAY_START_TIMEOUT_SECONDS = float(
    os.environ.get("PLATFORM_RELAY_START_TIMEOUT_SECONDS", "20")
)
RELAY_EXIT_TIMEOUT_SECONDS = float(
    os.environ.get("PLATFORM_RELAY_EXIT_TIMEOUT_SECONDS", "10")
)


def reserve_local_port():
    """Hold a free local TCP port, never the deployed default.

    Returns (port, holder); close the holder on the line before whatever binds the
    port, so the port is never back in the free pool during setup (#736).
    """
    while True:
        holder = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        holder.bind(("127.0.0.1", 0))
        holder.listen(1)
        port = holder.getsockname()[1]
        if port != DEPLOYED_PORT:
            return port, holder
        holder.close()


def load_relay_module():
    spec = importlib.util.spec_from_file_location("dozzle_alert_relay", RELAY_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError("could not load relay module")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class RecordingPushoverHandler(BaseHTTPRequestHandler):
    """Stands in for api.pushover.net and records the whole request, headers included."""

    server_version = "FakePushover/1"

    def do_POST(self):  # noqa: N802 - BaseHTTPRequestHandler API
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length)
        parsed = urllib.parse.parse_qs(
            body.decode("ascii"), keep_blank_values=True, strict_parsing=bool(body)
        )
        self.server.requests.append(
            {
                "path": self.path,
                "authorization": self.headers.get("Authorization"),
                "content_type": self.headers.get("Content-Type"),
                # A repeated key is kept visible as a list rather than merged.
                "form": {
                    key: values[0] if len(values) == 1 else values
                    for key, values in parsed.items()
                },
            }
        )
        # Pushover's `errors` array says which rejection it is.
        payload = getattr(self.server, "response_body", b"")
        self.send_response(self.server.response_status)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        if payload:
            self.wfile.write(payload)

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


class RecordingStderr:
    """A stderr that counts write() calls: one log line must be one write.

    list.append is atomic under the GIL, so no lock is needed.
    """

    def __init__(self):
        self.writes = []

    def write(self, text):
        self.writes.append(text)
        return len(text)

    def flush(self):
        pass

    def getvalue(self):
        return "".join(self.writes)


class DozzleAlertRelayTest(unittest.TestCase):
    def setUp(self):
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary_directory.cleanup)
        self.state_directory = Path(self.temporary_directory.name) / "state"
        self.state_directory.mkdir(mode=0o700)
        self.state_path = self.state_directory / "alert-relay.json"

        self.pushover = ThreadingHTTPServer(("127.0.0.1", 0), RecordingPushoverHandler)
        self.pushover.requests = []
        self.pushover.response_status = 200
        self.pushover.response_body = b""
        self.pushover_thread = threading.Thread(
            target=self.pushover.serve_forever, daemon=True
        )
        self.pushover_thread.start()
        self.addCleanup(self.stop_server, self.pushover, self.pushover_thread)

        self.relay_module = load_relay_module()
        # A case that patches utc_now itself nests inside this and wins.
        clock = mock.patch.object(self.relay_module, "utc_now", return_value=FIXED_NOW)
        clock.start()
        self.addCleanup(clock.stop)
        # Most cases post one envelope repeatedly to reach a ceiling, which the
        # duplicate window would drop; every server this case creates gets none.
        # The duplicate cases put the deployed window back.
        self.deployed_duplicate_window = self.relay_module.DUPLICATE_WINDOW
        self.relay_module.DUPLICATE_WINDOW = timedelta(0)
        self.config = self.relay_module.Config.from_mapping(self.environment())
        self.relay = self.relay_module.create_server(("127.0.0.1", 0), self.config)
        self.relay_thread = threading.Thread(target=self.relay.serve_forever, daemon=True)
        self.relay_thread.start()
        self.addCleanup(self.stop_server, self.relay, self.relay_thread)

    def environment(self, **changes):
        values = {
            "ALERT_RELAY_TOKEN": RELAY_TOKEN,
            "ALERT_RELAY_PORT": str(DEPLOYED_PORT),
            "PUSHOVER_API_URL":
                f"http://127.0.0.1:{self.pushover.server_port}/1/messages.json",
            "ALERT_RELAY_LINK_BASE": LINK_BASE,
            "PUSHOVER_TOKEN": PUSHOVER_TOKEN,
            "PUSHOVER_ALERTS_TOKEN": ALERTS_TOKEN,
            "PUSHOVER_GOLEM_TOKEN": GOLEM_TOKEN,
            "BESZEL_LINK_BASE": BESZEL_LINK_BASE,
            "PUSHOVER_USER_KEY": PUSHOVER_USER_KEY,
            "ALERT_STATE_PATH": str(self.state_path),
            "ALERT_DAILY_CONTAINER_CEILING": str(CONTAINER_CEILING),
            "ALERT_DAILY_OOM_CONTAINER_CEILING": str(OOM_CONTAINER_CEILING),
            "ALERT_DAILY_GLOBAL_CEILING": str(GLOBAL_CEILING),
        }
        values.update(changes)
        return {name: value for name, value in values.items() if value is not None}

    @staticmethod
    def today(now=None):
        """The day key the relay derives, spelled the way the relay spells it."""
        moment = now or FIXED_NOW
        return f"{moment.year:04d}-{moment.month:02d}-{moment.day:02d}"

    def budget(self, count=0, containers=(), notified=False, day=None):
        return {
            "day": self.today() if day is None else day,
            "count": count,
            "notified": notified,
            "containers": [
                {
                    "identity": f"{host}\0{container_id}",
                    "count": entry_count,
                    "notified": entry_notified,
                }
                for container_id, entry_count, entry_notified, host in sorted(
                    (
                        (entry[0], entry[1], entry[2], entry[3] if len(entry) > 3 else "nas")
                        for entry in containers
                    ),
                    key=lambda entry: f"{entry[3]}\0{entry[0]}",
                )
            ],
        }

    def published_forms(self):
        return [request["form"] for request in self.pushover.requests]

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
        self.assertEqual(self.pushover.requests, [])
        self.assertFalse(self.state_path.exists())

    def test_non_ascii_bearer_is_rejected_without_traceback_or_side_effects(self):
        captured = io.StringIO()
        with contextlib.redirect_stderr(captured):
            status_code, response_body = self.post(self.envelope(), token="\xff")

        self.assertEqual((status_code, response_body), (401, b"unauthorized\n"))
        self.assertNotIn("Traceback", captured.getvalue())
        self.assertEqual(self.pushover.requests, [])
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
        self.assertEqual(self.pushover.requests, [])
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
                    self.assertEqual(self.pushover.requests, [])
                    self.assertFalse(self.state_path.exists())
        self.assertNotIn("Traceback", captured.getvalue())

    def test_unexpected_exit_requires_canonical_nonzero_decimal_code(self):
        for exit_code in ("00", "000", "01", "0130", "0137", "0143", "1\u0662"):
            with self.subTest(exit_code=exit_code):
                status_code, response_body = self.post(
                    self.envelope("Unexpected exit", exitCode=exit_code)
                )
                self.assertEqual((status_code, response_body), (400, b"invalid request\n"))

        self.assertEqual(self.pushover.requests, [])
        self.assertFalse(self.state_path.exists())

    def test_sigkill_exit_pages_while_the_graceful_codes_stay_quiet(self):
        """137 is what an out-of-memory kill produces, so it must be published.

        Docker's `oom` event is cgroup-scoped, so a host-level kill is only seen here.
        """
        status_code, body = self.post(
            self.envelope("Unexpected exit", container="jellyfin", exitCode="137")
        )

        self.assertEqual((status_code, body), (204, b""))
        published = self.pushover.requests[-1]["form"]
        self.assertEqual(published["priority"], "1")
        self.assertEqual(published["title"], "\U0001f6d1 jellyfin exited (137)")
        self.assertIn(
            '\U0001f522 <b>Exit code</b> <font color="#c62828">137</font>',
            published["message"],
        )

        request_count = len(self.pushover.requests)
        for exit_code in ("0", "130", "143"):
            with self.subTest(exit_code=exit_code):
                self.assertEqual(
                    self.post(self.envelope("Unexpected exit", exitCode=exit_code)),
                    (400, b"invalid request\n"),
                )
        self.assertEqual(len(self.pushover.requests), request_count)

    def test_timestamp_is_a_real_canonical_utc_instant(self):
        leap_day = self.envelope("OOM", timestamp="2024-02-29T23:59:59Z")
        self.assertEqual(self.post(leap_day), (204, b""))
        fractional_leap_day = self.envelope(
            "OOM", timestamp="2024-02-29T23:59:59.123456789Z"
        )
        self.assertEqual(self.post(fractional_leap_day), (204, b""))
        request_count = len(self.pushover.requests)
        # The whole state document is captured, since the ceiling now writes it.
        settled = self.state_path.read_bytes()

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

        self.assertEqual(len(self.pushover.requests), request_count)
        self.assertEqual(self.state_path.read_bytes(), settled)

    def test_unhealthy_renders_exact_structured_pushover_request(self):
        status_code, body = self.post(self.envelope())

        self.assertEqual((status_code, body), (204, b""))
        self.assertEqual(
            self.pushover.requests,
            [
                {
                    "path": "/1/messages.json",
                    # Pushover authenticates by form field; a header would leak a credential.
                    "authorization": None,
                    "content_type": "application/x-www-form-urlencoded",
                    "form": {
                        "token": PUSHOVER_TOKEN,
                        "user": PUSHOVER_USER_KEY,
                        "title": "\U0001f7e0 paperless_webserver unhealthy",
                        "message": '<b>paperless_webserver</b> is <font color="#f9a825">unhealthy</font>\n'
                                   "\n"
                                   "\U0001f5a5\ufe0f <b>Host</b> nas\n"
                                   f'\U0001f4e6 <b>Container</b> <a href="{LINK_BASE}/container/{CONTAINER_ID}">'
                                   "paperless_webserver</a>\n"
                                   "\U0001f552 <b>When</b> 15 Aug 01:22 UTC\n"
                                   "\n"
                                   "<i>Open it in Dozzle to see why.</i>",
                        "html": "1",
                        "priority": "1",
                        # The container's Dozzle page, and the event time as Unix seconds.
                        "url": f"{LINK_BASE}/container/{CONTAINER_ID}",
                        "url_title": "Open in Dozzle",
                        "timestamp": "1786756933",
                    },
                }
            ],
        )

    def test_all_rule_renderings_are_human_readable_and_fixed(self):
        # (title, lead, detail labels, closing line?, priority)
        cases = [
            (
                "Unexpected exit",
                "\U0001f6d1 service exited (23)",
                '<b>service</b> <font color="#c62828">stopped unexpectedly</font>',
                ["Host", "Container", "Exit code", "When"],
                False,
                "1",
                {"container": "service", "exitCode": "23"},
            ),
            (
                "OOM",
                "\U0001f4a5 Out of memory · service",
                '<b>service</b> was <font color="#c62828">killed</font> by the kernel '
                "for running out of memory",
                ["Host", "Container", "When"],
                True,
                "2",
                {"container": "service"},
            ),
            (
                "Recovery",
                "\U0001f7e2 service recovered",
                '<b>service</b> is <font color="#2e7d32">healthy</font> again',
                ["Host", "Container", "When"],
                False,
                "-1",
                {"container": "service", "containerId": "b" * 64},
            ),
        ]
        for rule, title, lead, labels, closes, priority, changes in cases:
            with self.subTest(rule=rule):
                if rule == "Recovery":
                    # A recovery publishes only when it closes an unhealthy entry.
                    self.assertEqual(
                        self.post(
                            self.envelope(
                                "Unhealthy",
                                container="service",
                                containerId="b" * 64,
                                timestamp="2026-08-15T01:22:12Z",
                            )
                        )[0],
                        204,
                    )
                self.assertEqual(self.post(self.envelope(rule, **changes))[0], 204)
                published = self.pushover.requests[-1]["form"]
                self.assertEqual(published["title"], title)
                shape = message_shape(published["message"])
                self.assertEqual(shape["lead"], lead)
                self.assertEqual(shape["labels"], labels)
                self.assertEqual(bool(shape["closing"]), closes)
                self.assertEqual(published["priority"], priority)
                self.assertEqual(published["html"], "1")

    def test_every_title_form_is_pinned_and_stays_plain_text(self):
        """The lock screen shows the title alone, unescaped, so its form is the alert."""
        name = "a&b<c>"
        event = dict(self.envelope(container=name, containerId="c" * 64), exitCode="")
        titles = {
            "OOM": f"\U0001f4a5 Out of memory · {name}",
            "Unexpected exit": f"\U0001f6d1 {name} exited (137)",
            "Unhealthy": f"\U0001f7e0 {name} unhealthy",
            "Recovery": f"\U0001f7e2 {name} recovered",
        }
        for rule, expected in titles.items():
            with self.subTest(rule=rule):
                changes = {"rule": rule, "exitCode": "137" if rule == "Unexpected exit" else ""}
                rendered = self.relay_module.render_notification(dict(event, **changes), LINK_BASE)
                self.assertEqual(
                    rendered["title"], expected,
                    "a title is plain text on Pushover's side; escaping it shows &amp; to a person",
                )
        container_notice = self.relay_module.render_ceiling_notice(event, "container", 10, "2026-09-14", 25)
        global_notice = self.relay_module.render_ceiling_notice(event, "global", 10, "2026-09-14")
        self.assertEqual(container_notice["title"], f"\U0001f507 {name} alerts paused")
        self.assertEqual(global_notice["title"], "\U0001f507 Alerts paused")
        self.assertNotEqual(container_notice["title"], global_notice["title"])

    def test_every_message_leads_with_its_state_in_the_colour_of_that_state(self):
        """Lead, labelled details, closing; red failed, amber warning, green recovered."""
        colours = {
            "OOM": ("#c62828", ["Host", "Container", "When"]),
            "Unexpected exit": ("#c62828", ["Host", "Container", "Exit code", "When"]),
            "Unhealthy": ("#f9a825", ["Host", "Container", "When"]),
            "Recovery": ("#2e7d32", ["Host", "Container", "When"]),
        }
        for rule, (colour, labels) in colours.items():
            with self.subTest(rule=rule):
                changes = {"exitCode": "1"} if rule == "Unexpected exit" else {}
                rendered = self.relay_module.render_notification(self.envelope(rule, **changes), LINK_BASE)
                shape = message_shape(rendered["message"])
                self.assertEqual(shape["labels"], labels)
                self.assertTrue(shape["lead"].startswith("<b>paperless_webserver</b> "), shape["lead"])
                self.assertEqual(
                    re.findall(r'<font color="(#[0-9a-f]{6})">', shape["lead"]), [colour],
                    f"a {rule} lead line must colour its state {colour}, and "
                    f"{shape['lead']!r} does not",
                )
        for scope, allowance, labels in (
            ("container", 25, ["Host", "Container", "Reason"]),
            ("global", None, ["Host", "Reason"]),
        ):
            with self.subTest(scope=scope):
                notice = self.relay_module.render_ceiling_notice(
                    self.envelope(), scope, 10, "2026-09-14", allowance
                )
                shape = message_shape(notice["message"])
                self.assertEqual(shape["labels"], labels)
                self.assertIn('<font color="#f9a825">paused</font>', shape["lead"])
                self.assertTrue(shape["closing"])

    def test_an_unhealthy_alert_promises_no_recovery_it_cannot_guarantee(self):
        """State is keyed on host and container id, so a recovery is not certain.

        A recreated container never closes its predecessor's entry, so the closing
        line points at Dozzle instead, and only when there is a link.
        """
        linked = message_shape(self.relay_module.render_notification(self.envelope(), LINK_BASE)["message"])
        self.assertEqual(
            linked["closing"], "<i>Open it in Dozzle to see why.</i>",
            "an unhealthy alert's closing line must not promise a recovery: a recreated "
            "container never sends one",
        )
        unlinked = message_shape(self.relay_module.render_notification(self.envelope(), None)["message"])
        self.assertEqual(unlinked["closing"], "", "no link, so no line pointing at Dozzle")
        # Only the Unhealthy closing points at Dozzle.
        oom = message_shape(self.relay_module.render_notification(self.envelope("OOM"), None)["message"])
        self.assertIn("until acknowledged", oom["closing"])

    def test_ten_thousand_characters_of_hostile_input_render_a_message_pushover_takes(self):
        """The renderers, not only the envelope, bound what they are handed."""
        hostile = ("<b>&'\"\n\0\U0001f9e8" * 1500)[:10_000]
        rendered = [
            self.relay_module.render_notification(
                dict(self.envelope(rule, container=hostile, host=hostile), exitCode=code),
                "https://" + "l" * (self.relay_module.MAX_LINK_BASE_CHARACTERS - len("https://")),
            )
            for rule, code in (("OOM", ""), ("Unexpected exit", "255"), ("Unhealthy", ""), ("Recovery", ""))
        ] + [
            self.relay_module.render_ceiling_notice(
                self.envelope(container=hostile, host=hostile), scope, 999999, "2026-09-14", allowance
            )
            for scope, allowance in (("container", 999999), ("global", None))
        ]
        for fields in rendered:
            with self.subTest(title=fields["title"][:20]):
                message = fields["message"]
                self.assertTrue(message)
                self.assertTrue(fields["title"])
                self.assertLessEqual(len(message), self.relay_module.MAX_MESSAGE_CHARACTERS)
                self.assertLessEqual(len(fields["title"]), self.relay_module.MAX_TITLE_CHARACTERS)
                self.assertIsNone(HALF_ENTITY.search(message), message[-40:])
                for tag in ("b", "i", "font", "a"):
                    self.assertEqual(
                        len(re.findall(rf"<{tag}\b", message)), message.count(f"</{tag}>"), tag
                    )

    def test_emergency_priority_carries_the_parameters_pushover_requires(self):
        """Priority 2 without retry and expire is refused by Pushover outright."""
        self.assertEqual(self.post(self.envelope("OOM"))[0], 204)
        emergency = self.pushover.requests[-1]["form"]
        self.assertEqual(emergency["priority"], "2")
        self.assertEqual(emergency["retry"], "60")
        self.assertEqual(emergency["expire"], "3600")
        # Inside Pushover's documented bounds rather than at them.
        self.assertGreaterEqual(int(emergency["retry"]), 30)
        self.assertLessEqual(int(emergency["expire"]), 10800)

        for rule, changes in (
            ("Unhealthy", {}),
            ("Unexpected exit", {"exitCode": "23"}),
        ):
            with self.subTest(rule=rule):
                self.assertEqual(self.post(self.envelope(rule, **changes))[0], 204)
                ordinary = self.pushover.requests[-1]["form"]
                self.assertNotEqual(ordinary["priority"], "2")
                # A retry on a non-emergency is accepted and silently means nothing.
                self.assertNotIn("retry", ordinary)
                self.assertNotIn("expire", ordinary)

    def test_the_documented_escalation_window_is_the_one_that_happens(self):
        """Pushover stops an emergency at 50 retries whatever `expire` says.

        Asserted on the constants in its own case, so an earlier literal assertion
        cannot mask it.
        """
        relay = self.relay_module
        escalation = relay.EMERGENCY_RETRY_SECONDS * relay.EMERGENCY_MAX_RETRIES
        self.assertLessEqual(
            escalation,
            relay.EMERGENCY_EXPIRE_SECONDS,
            f"{relay.EMERGENCY_EXPIRE_SECONDS}s of expire cuts the escalation "
            f"short of the {escalation}s Pushover's retry cap allows, so the "
            "window documented beside these constants is not the one that runs",
        )
        # A retry below 30 or an expire above 10800 is a refused message.
        self.assertGreaterEqual(relay.EMERGENCY_RETRY_SECONDS, 30)
        self.assertLessEqual(relay.EMERGENCY_EXPIRE_SECONDS, 10800)

    def test_every_problem_rule_outranks_a_recovery(self):
        """Only a recovery is quiet; a problem must never be downgraded."""
        for rule, changes in (
            ("Unexpected exit", {"exitCode": "23"}),
            ("OOM", {}),
            ("Unhealthy", {}),
        ):
            with self.subTest(rule=rule):
                self.assertEqual(self.post(self.envelope(rule, **changes))[0], 204)
                self.assertGreaterEqual(
                    int(self.pushover.requests[-1]["form"]["priority"]), 1
                )

        recovery_id = "c" * 64
        self.assertEqual(
            self.post(
                self.envelope(
                    "Unhealthy", containerId=recovery_id, timestamp="2026-08-15T01:22:12Z"
                )
            )[0],
            204,
        )
        self.assertEqual(
            self.post(
                self.envelope(
                    "Recovery", containerId=recovery_id, timestamp="2026-08-15T01:22:13Z"
                )
            )[0],
            204,
        )
        self.assertEqual(self.pushover.requests[-1]["form"]["priority"], "-1")

    def test_config_requires_a_redirectable_endpoint_url(self):
        base = self.environment(PUSHOVER_API_URL="http://127.0.0.1:1/1/messages.json")
        self.assertEqual(
            self.relay_module.Config.from_mapping(base).pushover_api_url,
            "http://127.0.0.1:1/1/messages.json",
        )

        for label, value in (
            ("missing", None),
            ("empty", ""),
            ("not a URL", "api.pushover.net"),
            ("wrong scheme", "ftp://api.pushover.net/1/messages.json"),
            ("no host", "https:///1/messages.json"),
            ("userinfo", "https://user:pass@api.pushover.net/1/messages.json"),
            ("user only", "https://user@api.pushover.net/1/messages.json"),
            ("query", "https://api.pushover.net/1/messages.json?token=leak"),
            ("fragment", "https://api.pushover.net/1/messages.json#x"),
            # A bare root was the earlier shape.
            ("root", "https://api.pushover.net/"),
            ("control character", "https://api.pushover.net/1/messages.json\n"),
        ):
            with self.subTest(label=label):
                with self.assertRaises(self.relay_module.ConfigurationError):
                    self.relay_module.Config.from_mapping(
                        self.environment(PUSHOVER_API_URL=value)
                        if value is not None
                        else {
                            name: field
                            for name, field in base.items()
                            if name != "PUSHOVER_API_URL"
                        }
                    )

    def test_an_unusable_link_origin_costs_the_link_and_nothing_else(self):
        """The link base is validated, never repaired, and never fatal.

        Pushover caps url at 512 characters, so the bound lives at start-up. A relay
        restarted before roles/dozzle re-renders its environment must still alert.
        """
        relay = self.relay_module
        configured = relay.Config.from_mapping(self.environment())
        self.assertEqual(configured.alert_relay_link_base, LINK_BASE)
        self.assertIsNone(configured.alert_relay_link_problem)
        self.assertEqual(
            relay.Config.from_mapping(
                self.environment(ALERT_RELAY_LINK_BASE=LINK_BASE + "/")
            ).alert_relay_link_base,
            LINK_BASE,
        )
        longest = "http://" + "h" * (relay.MAX_LINK_BASE_CHARACTERS - len("http://"))
        accepted = relay.Config.from_mapping(self.environment(ALERT_RELAY_LINK_BASE=longest))
        self.assertEqual(accepted.alert_relay_link_base, longest)
        self.assertLessEqual(
            len(
                relay.render_notification(
                    self.envelope(containerId="f" * 64), accepted.alert_relay_link_base
                )["url"]
            ),
            relay.MAX_URL_CHARACTERS,
        )

        for label, value in (
            ("missing", None),
            ("empty", ""),
            ("wrong scheme", "ftp://nas.tailnet.example:8080"),
            ("no host", "http://:8080"),
            ("not a port", "http://nas.tailnet.example:http"),
            ("userinfo", "http://admin:link-secret@nas.tailnet.example:8080"),
            ("path", "http://nas.tailnet.example:8080/dozzle"),
            ("query", "http://nas.tailnet.example:8080?x=1"),
            ("empty query", "http://nas.tailnet.example:8080?"),
            ("fragment", "http://nas.tailnet.example:8080#x"),
            ("control character", LINK_BASE + "\n"),
            ("one character too long", longest + "h"),
        ):
            with self.subTest(label=label):
                mutated = self.environment(ALERT_RELAY_LINK_BASE=value)
                degraded = relay.Config.from_mapping(mutated)
                self.assertIsNone(degraded.alert_relay_link_base)
                self.assertIn("ALERT_RELAY_LINK_BASE", degraded.alert_relay_link_problem)
                self.assertIn("no Dozzle link", degraded.alert_relay_link_problem)
                if value:
                    self.assertNotIn(value, degraded.alert_relay_link_problem)
                    self.assertNotIn("link-secret", degraded.alert_relay_link_problem)
                self.assertEqual(degraded.pushover_api_url, configured.pushover_api_url)

        with self.assertRaises(relay.ConfigurationError):
            relay.validated_link_base("http://nas.tailnet.example:8080/dozzle")

    def test_the_role_default_renders_a_link_base_the_relay_accepts(self):
        """The role default must render a link base the relay's own validator accepts."""
        defaults = (ROOT / "roles" / "dozzle" / "defaults" / "main.yml").read_text()
        template = re.search(
            r'^dozzle_alert_relay_link_base: "([^"\n]*)"$', defaults, re.M
        )
        port = re.search(r"^dozzle_port: ([0-9]+)$", defaults, re.M)
        self.assertIsNotNone(template, "roles/dozzle declares no dozzle_alert_relay_link_base")
        self.assertIsNotNone(port, "roles/dozzle declares no numeric dozzle_port")
        for host in ("127.0.0.1", "as6704t-0000.tail0000.ts.net"):
            with self.subTest(host=host):
                rendered = (
                    template.group(1)
                    .replace("{{ platform_public_host }}", host)
                    .replace("{{ dozzle_port }}", port.group(1))
                )
                self.assertNotIn("{{", rendered)
                self.assertEqual(
                    self.relay_module.validated_link_base(rendered),
                    f"http://{host}:{port.group(1)}",
                )

    def test_the_link_and_event_time_fit_what_pushover_accepts(self):
        """Every rule links its container and carries its event time.

        `url_title` caps at 100 and `timestamp` is Unix seconds; a pre-1970 time is
        left off rather than sent for Pushover to refuse.
        """
        relay = self.relay_module
        for rule, changes in (
            ("Unhealthy", {}),
            ("OOM", {}),
            ("Unexpected exit", {"exitCode": "23"}),
            ("Recovery", {}),
        ):
            with self.subTest(rule=rule):
                rendered = relay.render_notification(
                    self.envelope(rule, containerId="0123456789ab", **changes), LINK_BASE
                )
                self.assertEqual(rendered["url"], f"{LINK_BASE}/container/0123456789ab")
                self.assertEqual(rendered["url_title"], "Open in Dozzle")
                self.assertLessEqual(
                    len(rendered["url_title"]), relay.MAX_URL_TITLE_CHARACTERS
                )
                self.assertEqual(rendered["timestamp"], 1786756933)

        fractional = relay.render_notification(
            self.envelope(timestamp="2026-08-15T01:22:13.999999999Z"), LINK_BASE
        )
        self.assertEqual(fractional["timestamp"], 1786756933)
        epoch = relay.render_notification(
            self.envelope(timestamp="1970-01-01T00:00:00Z"), LINK_BASE
        )
        self.assertEqual(epoch["timestamp"], 0)
        before_epoch = relay.render_notification(
            self.envelope(timestamp="1969-12-31T23:59:59Z"), LINK_BASE
        )
        self.assertNotIn("timestamp", before_epoch)

        unlinked = relay.render_notification(self.envelope(), None)
        self.assertNotIn("url", unlinked)
        self.assertNotIn("url_title", unlinked)
        self.assertEqual(unlinked["timestamp"], 1786756933)

    def test_config_requires_both_pushover_credentials(self):
        for name in ("PUSHOVER_TOKEN", "PUSHOVER_USER_KEY"):
            for label, value in (("missing", None), ("empty", "")):
                with self.subTest(name=name, label=label):
                    mutated = self.environment()
                    if value is None:
                        del mutated[name]
                    else:
                        mutated[name] = value
                    with self.assertRaises(self.relay_module.ConfigurationError):
                        self.relay_module.Config.from_mapping(mutated)

    def test_config_requires_a_coherent_ceiling(self):
        """Every ceiling is required, positive, and in a workable order.

        OOM below ordinary, or global below per-container, makes a ceiling pointless
        or unreachable.
        """
        configured = self.relay_module.Config.from_mapping(self.environment())
        self.assertEqual(configured.container_ceiling, CONTAINER_CEILING)
        self.assertEqual(configured.oom_container_ceiling, OOM_CONTAINER_CEILING)
        self.assertEqual(configured.global_ceiling, GLOBAL_CEILING)

        for label, mutation in (
            ("missing", {"ALERT_DAILY_CONTAINER_CEILING": None}),
            ("empty", {"ALERT_DAILY_CONTAINER_CEILING": ""}),
            # Zero is not "no ceiling", it is a relay that can never publish.
            ("zero", {"ALERT_DAILY_CONTAINER_CEILING": "0"}),
            ("negative", {"ALERT_DAILY_CONTAINER_CEILING": "-1"}),
            ("padded", {"ALERT_DAILY_CONTAINER_CEILING": " 10"}),
            ("leading zero", {"ALERT_DAILY_CONTAINER_CEILING": "010"}),
            ("not a number", {"ALERT_DAILY_CONTAINER_CEILING": "ten"}),
            ("missing global", {"ALERT_DAILY_GLOBAL_CEILING": None}),
            ("missing oom", {"ALERT_DAILY_OOM_CONTAINER_CEILING": None}),
            (
                "oom below ordinary",
                {
                    "ALERT_DAILY_CONTAINER_CEILING": "10",
                    "ALERT_DAILY_OOM_CONTAINER_CEILING": "9",
                },
            ),
            (
                "global below oom",
                {
                    "ALERT_DAILY_OOM_CONTAINER_CEILING": "25",
                    "ALERT_DAILY_GLOBAL_CEILING": "24",
                },
            ),
        ):
            with self.subTest(label=label):
                mutated = self.environment()
                for name, value in mutation.items():
                    if value is None:
                        del mutated[name]
                    else:
                        mutated[name] = value
                with self.assertRaises(self.relay_module.ConfigurationError):
                    self.relay_module.Config.from_mapping(mutated)

    def test_config_requires_an_absolute_state_file_path(self):
        for label, value in (
            ("relative", "state/alerts.json"),
            ("root", "/"),
            ("dot dot", "/state/.."),
        ):
            with self.subTest(label=label):
                with self.assertRaisesRegex(
                    self.relay_module.ConfigurationError,
                    r"\AALERT_STATE_PATH must be an absolute file path\Z",
                ):
                    self.relay_module.Config.from_mapping(self.environment(ALERT_STATE_PATH=value))

    def test_unusable_optional_beszel_settings_degrade_rather_than_refuse(self):
        for label, value in (("missing", None), ("empty", ""), ("control", "tok\nen")):
            with self.subTest(alerts_token=label):
                config = self.relay_module.Config.from_mapping(
                    self.environment(PUSHOVER_ALERTS_TOKEN=value)
                )
                self.assertIsNone(config.pushover_alerts_token)
            with self.subTest(golem_token=label):
                config = self.relay_module.Config.from_mapping(
                    self.environment(PUSHOVER_GOLEM_TOKEN=value)
                )
                self.assertIsNone(config.pushover_golem_token)
        for label, value in (("missing", None), ("empty", "")):
            with self.subTest(beszel_link_base=label):
                config = self.relay_module.Config.from_mapping(
                    self.environment(BESZEL_LINK_BASE=value)
                )
                self.assertIsNone(config.beszel_link_base)
                self.assertEqual(
                    config.beszel_link_problem,
                    "BESZEL_LINK_BASE is not set; Beszel alerts will carry no link",
                )

    def test_config_requires_a_usable_listener_port(self):
        base = self.environment()
        self.assertEqual(
            self.relay_module.Config.from_mapping(base).alert_relay_port, DEPLOYED_PORT
        )

        for label, value in (
            # No fallback: the value has one home, the Ansible defaults.
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
        # Read back from a live listener, so a main() binding its own number fails.
        port, holder = reserve_local_port()
        self.addCleanup(holder.close)
        self.assertNotEqual(port, DEPLOYED_PORT)
        created = []
        real_create_server = self.relay_module.create_server

        def capture(address, config):
            server = real_create_server(address, config)
            created.append(server)
            return server

        environment = self.environment(ALERT_RELAY_PORT=str(port))
        with mock.patch.object(self.relay_module, "create_server", capture), \
                mock.patch.dict(os.environ, environment):
            # Released on the line before the binding thread.
            holder.close()
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
        self.assertEqual(len(self.pushover.requests), 0)
        # A first healthy transition publishes nothing, so it charges nothing.
        self.assertEqual(
            self.read_state(),
            {
                "version": 3,
                "entries": [
                    self.state_entry("b" * 64, "healthy", "2026-08-15T01:22:12Z")
                ],
                "budget": self.budget(),
            },
        )

        self.assertEqual(self.post(unhealthy)[0], 204)
        self.assertEqual(self.post(unhealthy)[0], 204)
        self.assertEqual(
            self.read_state(),
            {
                "version": 3,
                "entries": [
                    self.state_entry("b" * 64, "unhealthy", "2026-08-15T01:22:13Z")
                ],
                "budget": self.budget(2, [("b" * 64, 2, False)]),
            },
        )
        self.assertEqual(len(self.pushover.requests), 2)

        recovered = dict(healthy, timestamp="2026-08-15T01:22:14Z")
        self.assertEqual(self.post(recovered)[0], 204)
        self.assertEqual(
            self.pushover.requests[-1]["form"],
            {
                "token": PUSHOVER_TOKEN,
                "user": PUSHOVER_USER_KEY,
                "title": "\U0001f7e2 immich_server recovered",
                "message": '<b>immich_server</b> is <font color="#2e7d32">healthy</font> again\n'
                           "\n"
                           "\U0001f5a5\ufe0f <b>Host</b> nas\n"
                           f'\U0001f4e6 <b>Container</b> <a href="{LINK_BASE}/container/{"b" * 64}">'
                           "immich_server</a>\n"
                           "\U0001f552 <b>When</b> 15 Aug 01:22 UTC",
                "html": "1",
                # A recovery is a badge and no sound.
                "priority": "-1",
                "url": f"{LINK_BASE}/container/{'b' * 64}",
                "url_title": "Open in Dozzle",
                "timestamp": "1786756934",
            },
        )
        self.assertEqual(
            self.read_state(),
            {
                "version": 3,
                "entries": [
                    self.state_entry("b" * 64, "healthy", "2026-08-15T01:22:14Z")
                ],
                "budget": self.budget(3, [("b" * 64, 3, False)]),
            },
        )
        self.assertEqual(self.post(recovered)[0], 204)
        self.assertEqual(len(self.pushover.requests), 3)
        self.assertEqual(self.read_state()["budget"]["count"], 3)

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
        self.assertEqual(self.pushover.requests, [])
        expected = {
            "version": 3,
            "entries": [
                self.state_entry(identity, "healthy", "2026-08-15T01:22:14.000000001Z")
            ],
            "budget": self.budget(),
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
        self.assertEqual(self.pushover.requests, [])
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
        self.assertEqual(self.pushover.requests, [])

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
        self.assertEqual(len(self.pushover.requests), 3)
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

        self.assertEqual(len(self.pushover.requests), 1)
        self.assertEqual(
            self.read_state(),
            {
                "version": 3,
                "entries": [
                    self.state_entry(first_id, "healthy", "2026-08-15T01:22:14Z"),
                    self.state_entry(second_id, "unhealthy", "0001-01-01T00:00:00Z"),
                ],
                # A schema that could not hold a count cannot have spent one.
                "budget": self.budget(1, [(first_id, 1, False)]),
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
        self.assertEqual(self.pushover.requests, [])

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
        self.assertEqual(self.pushover.requests, [])
        self.assertEqual(self.state_path.read_bytes(), original)

    # --- the daily ceiling (test ceilings, not the deployment's) ---

    def test_under_the_ceiling_every_alert_publishes_and_is_counted(self):
        """The passing path, so a silent relay cannot pass for a working ceiling."""
        for index in range(CONTAINER_CEILING):
            with self.subTest(index=index):
                self.assertEqual(self.post(self.envelope("Unexpected exit"))[0], 204)
                self.assertEqual(len(self.pushover.requests), index + 1)
                self.assertEqual(
                    self.read_state()["budget"],
                    self.budget(index + 1, [(CONTAINER_ID, index + 1, False)]),
                )
        titles = {form["title"] for form in self.published_forms()}
        self.assertEqual(titles, {"\U0001f6d1 paperless_webserver exited (1)"})
        self.assertNotIn(
            "\U0001f507 ",
            "".join(form["title"] for form in self.published_forms()),
        )

    def test_the_container_ceiling_trips_at_its_boundary_and_notices_once(self):
        for _index in range(CONTAINER_CEILING):
            self.assertEqual(self.post(self.envelope("Unexpected exit"))[0], 204)
        self.assertEqual(len(self.pushover.requests), CONTAINER_CEILING)

        self.assertEqual(self.post(self.envelope("Unexpected exit"))[0], 204)
        notice = self.pushover.requests[-1]["form"]
        self.assertEqual(notice["title"], "\U0001f507 paperless_webserver alerts paused")
        self.assertIn("<b>Alerts for paperless_webserver</b> are", notice["message"])
        self.assertIn(f"{CONTAINER_CEILING} alerts already sent", notice["message"])
        # Outranks any single alert, but there is nothing to acknowledge, so never 2.
        self.assertEqual(notice["priority"], "1")

        for _index in range(5):
            self.assertEqual(self.post(self.envelope("Unexpected exit"))[0], 204)
        self.assertEqual(len(self.pushover.requests), CONTAINER_CEILING + 1)
        suppressed = [
            form for form in self.published_forms()
            if form["title"].startswith("\U0001f507 ")
        ]
        self.assertEqual(len(suppressed), 1)
        # The notice itself is not charged, or the latch would depend on its own counter.
        self.assertEqual(
            self.read_state()["budget"],
            self.budget(CONTAINER_CEILING, [(CONTAINER_ID, CONTAINER_CEILING, True)]),
        )

    def test_one_noisy_container_cannot_silence_another(self):
        """The whole reason the ceiling is per container as well as global."""
        for _index in range(CONTAINER_CEILING + 3):
            self.assertEqual(self.post(self.envelope("Unexpected exit"))[0], 204)
        self.assertEqual(len(self.pushover.requests), CONTAINER_CEILING + 1)

        quiet_id = "b" * 64
        self.assertEqual(
            self.post(
                self.envelope(
                    "Unexpected exit", container="immich_server", containerId=quiet_id
                )
            )[0],
            204,
        )
        self.assertEqual(
            self.pushover.requests[-1]["form"]["title"],
            "\U0001f6d1 immich_server exited (1)",
        )

    def test_an_oom_outlives_the_ordinary_allowance_and_is_still_bounded(self):
        """OOM is not exempt: a crash loop emits an unbounded `oom` stream."""
        for _index in range(CONTAINER_CEILING):
            self.assertEqual(self.post(self.envelope("Unexpected exit"))[0], 204)
        self.assertEqual(len(self.pushover.requests), CONTAINER_CEILING)

        for index in range(OOM_CONTAINER_CEILING - CONTAINER_CEILING):
            with self.subTest(index=index):
                self.assertEqual(self.post(self.envelope("OOM"))[0], 204)
                self.assertEqual(self.pushover.requests[-1]["form"]["priority"], "2")
        self.assertEqual(len(self.pushover.requests), OOM_CONTAINER_CEILING)

        self.assertEqual(self.post(self.envelope("Unexpected exit"))[0], 204)
        self.assertTrue(
            self.pushover.requests[-1]["form"]["title"].startswith("\U0001f507 ")
        )

        self.assertEqual(self.post(self.envelope("OOM"))[0], 204)
        self.assertEqual(len(self.pushover.requests), OOM_CONTAINER_CEILING + 1)
        self.assertEqual(
            self.pushover.requests[-1]["form"]["priority"],
            "1",
            "the container's notice has already been sent, so a suppressed OOM "
            "must be silent rather than sending a second one",
        )
        for _index in range(3):
            self.assertEqual(self.post(self.envelope("OOM"))[0], 204)
        self.assertEqual(len(self.pushover.requests), OOM_CONTAINER_CEILING + 1)

    def test_the_global_ceiling_backstops_every_container_and_notices_once(self):
        published = 0
        for index in range(GLOBAL_CEILING):
            container_id = f"{index:064x}"
            self.assertEqual(
                self.post(
                    self.envelope(
                        "Unexpected exit",
                        container=f"service-{index}",
                        containerId=container_id,
                    )
                )[0],
                204,
            )
            published += 1
            self.assertEqual(len(self.pushover.requests), published)
        self.assertEqual(self.read_state()["budget"]["count"], GLOBAL_CEILING)

        # The global count is checked before any per-container allowance.
        fresh = f"{GLOBAL_CEILING:064x}"
        self.assertEqual(
            self.post(
                self.envelope(
                    "Unexpected exit", container="never-seen", containerId=fresh
                )
            )[0],
            204,
        )
        notice = self.pushover.requests[-1]["form"]
        self.assertEqual(notice["title"], "\U0001f507 Alerts paused")
        self.assertIn("<b>Every alert</b> is", notice["message"])
        self.assertIn(f"{GLOBAL_CEILING} alerts already sent", notice["message"])

        for index in range(4):
            self.assertEqual(
                self.post(
                    self.envelope(
                        "Unexpected exit",
                        container=f"later-{index}",
                        containerId=f"{GLOBAL_CEILING + 1 + index:064x}",
                    )
                )[0],
                204,
            )
        self.assertEqual(len(self.pushover.requests), GLOBAL_CEILING + 1)
        self.assertEqual(
            len(
                [
                    form for form in self.published_forms()
                    if form["title"].startswith("\U0001f507 ")
                ]
            ),
            1,
            "one global notice per day, and one only",
        )
        # No per-container notice after the global backstop trips.
        self.assertTrue(self.read_state()["budget"]["notified"])

        self.assertEqual(self.post(self.envelope("OOM"))[0], 204)
        self.assertEqual(len(self.pushover.requests), GLOBAL_CEILING + 1)

    def test_a_new_utc_day_restores_the_whole_allowance(self):
        first = datetime(2026, 8, 15, 23, 59, 0, tzinfo=timezone.utc)
        with mock.patch.object(self.relay_module, "utc_now", return_value=first):
            for _index in range(CONTAINER_CEILING + 1):
                self.assertEqual(self.post(self.envelope("Unexpected exit"))[0], 204)
        self.assertEqual(len(self.pushover.requests), CONTAINER_CEILING + 1)
        self.assertEqual(
            self.read_state()["budget"],
            self.budget(
                CONTAINER_CEILING,
                [(CONTAINER_ID, CONTAINER_CEILING, True)],
                day="2026-08-15",
            ),
        )

        second = datetime(2026, 8, 16, 0, 0, 30, tzinfo=timezone.utc)
        with mock.patch.object(self.relay_module, "utc_now", return_value=second):
            self.assertEqual(self.post(self.envelope("Unexpected exit"))[0], 204)
        self.assertEqual(len(self.pushover.requests), CONTAINER_CEILING + 2)
        self.assertEqual(
            self.pushover.requests[-1]["form"]["title"],
            "\U0001f6d1 paperless_webserver exited (1)",
        )
        self.assertEqual(
            self.read_state()["budget"],
            self.budget(1, [(CONTAINER_ID, 1, False)], day="2026-08-16"),
        )

    def test_a_clock_that_moves_backwards_cannot_wedge_the_relay_shut(self):
        """A calendar day key resets on any other day, so a backwards clock cannot wedge it."""
        later = datetime(2026, 8, 16, 12, 0, tzinfo=timezone.utc)
        with mock.patch.object(self.relay_module, "utc_now", return_value=later):
            for _index in range(CONTAINER_CEILING + 1):
                self.assertEqual(self.post(self.envelope("Unexpected exit"))[0], 204)
        self.assertEqual(len(self.pushover.requests), CONTAINER_CEILING + 1)
        self.assertEqual(self.read_state()["budget"]["day"], "2026-08-16")

        earlier = datetime(2026, 8, 15, 12, 0, tzinfo=timezone.utc)
        with mock.patch.object(self.relay_module, "utc_now", return_value=earlier):
            self.assertEqual(self.post(self.envelope("Unexpected exit"))[0], 204)
        self.assertEqual(len(self.pushover.requests), CONTAINER_CEILING + 2)
        self.assertEqual(
            self.pushover.requests[-1]["form"]["title"],
            "\U0001f6d1 paperless_webserver exited (1)",
            "a clock that moved backwards must start a fresh day, not suppress",
        )
        self.assertEqual(
            self.read_state()["budget"],
            self.budget(1, [(CONTAINER_ID, 1, False)], day="2026-08-15"),
        )

    def test_a_restart_neither_loses_nor_double_counts_the_allowance(self):
        for _index in range(CONTAINER_CEILING - 1):
            self.assertEqual(self.post(self.envelope("Unexpected exit"))[0], 204)
        self.assertEqual(len(self.pushover.requests), CONTAINER_CEILING - 1)

        restarted = self.relay_module.create_server(("127.0.0.1", 0), self.config)
        restarted_thread = threading.Thread(target=restarted.serve_forever, daemon=True)
        restarted_thread.start()
        self.addCleanup(self.stop_server, restarted, restarted_thread)
        original_relay = self.relay
        self.relay = restarted
        try:
            self.assertEqual(self.post(self.envelope("Unexpected exit"))[0], 204)
            self.assertEqual(len(self.pushover.requests), CONTAINER_CEILING)
            self.assertEqual(
                self.pushover.requests[-1]["form"]["title"],
                "\U0001f6d1 paperless_webserver exited (1)",
            )
            self.assertEqual(self.post(self.envelope("Unexpected exit"))[0], 204)
            self.assertTrue(
                self.pushover.requests[-1]["form"]["title"].startswith(
                    "\U0001f507 "
                )
            )
            self.assertEqual(self.post(self.envelope("Unexpected exit"))[0], 204)
            self.assertEqual(len(self.pushover.requests), CONTAINER_CEILING + 1)
        finally:
            self.relay = original_relay

        second_restart = self.relay_module.create_server(("127.0.0.1", 0), self.config)
        second_thread = threading.Thread(
            target=second_restart.serve_forever, daemon=True
        )
        second_thread.start()
        self.addCleanup(self.stop_server, second_restart, second_thread)
        self.relay = second_restart
        try:
            self.assertEqual(self.post(self.envelope("Unexpected exit"))[0], 204)
        finally:
            self.relay = original_relay
        self.assertEqual(
            len(
                [
                    form for form in self.published_forms()
                    if form["title"].startswith("\U0001f507 ")
                ]
            ),
            1,
        )

    def test_the_ceiling_survives_a_state_store_that_cannot_be_written(self):
        """A state write that fails must not fail the ceiling open.

        Failing closed is not the fix either: the bound degrades from durable to
        process-lifetime instead.
        """
        with mock.patch.object(
            self.relay_module.LockedState, "replace",
            side_effect=self.relay_module.StateError("state replacement failed"),
        ):
            statuses = []
            for _index in range(CONTAINER_CEILING + 12):
                statuses.append(self.post(self.envelope("Unexpected exit"))[0])

        # The alert was delivered; the 500 is about the store.
        self.assertEqual(set(statuses), {500})
        self.assertFalse(self.state_path.exists())

        titles = [form["title"] for form in self.published_forms()]
        alerts = [t for t in titles if t.startswith("\U0001f6d1 ")]
        notices = [t for t in titles if t.startswith("\U0001f507 ")]
        self.assertEqual(
            len(alerts), CONTAINER_CEILING,
            f"the ceiling failed open across a broken store: {len(alerts)} alerts",
        )
        self.assertEqual(
            len(notices), 1,
            f"the notice latch failed open across a broken store: {len(notices)} notices",
        )

    def test_the_global_ceiling_and_its_latch_survive_a_broken_store_too(self):
        """The global count and latch merge separately, so they need their own case."""
        with mock.patch.object(
            self.relay_module.LockedState, "replace",
            side_effect=self.relay_module.StateError("state replacement failed"),
        ):
            for index in range(GLOBAL_CEILING + 6):
                self.assertEqual(
                    self.post(
                        self.envelope(
                            "Unexpected exit",
                            container=f"service-{index}",
                            containerId=f"{index:064x}",
                        )
                    )[0],
                    500,
                )

        self.assertFalse(self.state_path.exists())
        titles = [form["title"] for form in self.published_forms()]
        alerts = [t for t in titles if t.startswith("\U0001f6d1 ")]
        notices = [t for t in titles if t == "\U0001f507 Alerts paused"]
        self.assertEqual(
            len(alerts), GLOBAL_CEILING,
            f"the global backstop failed open across a broken store: {len(alerts)}",
        )
        self.assertEqual(
            len(notices), 1,
            f"the global notice latch failed open across a broken store: {len(notices)}",
        )

    def test_the_whole_ceiling_decision_happens_inside_the_state_lock(self):
        """The ceiling's check-then-act, publish included, must stay inside the flock.

        Moving `publish` out of the lock is the obvious fix for a hung upstream and
        breaches the ceiling; asserted on source structure so it cannot flake.
        """
        tree = ast.parse(RELAY_PATH.read_text(encoding="utf-8"))
        # Container events and Beszel alerts charge the same counter under one lock.
        for function_name in ("process_event", "process_beszel"):
            with self.subTest(function=function_name):
                self.assert_ceiling_decision_is_locked(tree, function_name)

    def assert_ceiling_decision_is_locked(self, tree, function_name):
        function = next(
            node for node in tree.body
            if isinstance(node, ast.FunctionDef) and node.name == function_name
        )
        locked = [node for node in function.body if isinstance(node, ast.With)]
        self.assertEqual(
            len(locked), 1, f"{function_name} must hold exactly one state lock"
        )
        self.assertTrue(
            any(
                isinstance(item.context_expr, ast.Call)
                and getattr(item.context_expr.func, "id", None) == "LockedState"
                for item in locked[0].items
            ),
            f"the one with-block in {function_name} must be the state lock",
        )

        def calls_within(node):
            found = set()
            for child in ast.walk(node):
                if not isinstance(child, ast.Call):
                    continue
                target = child.func
                if isinstance(target, ast.Name):
                    found.add(target.id)
                elif isinstance(target, ast.Attribute):
                    found.add(target.attr)
            return found

        inside = calls_within(locked[0])
        for name, why in (
            ("publish", "moving the publish out of the lock breaches the ceiling"),
            ("raise_floor", "the floor must be read under the same lock it is written under"),
            ("record", "recording outside the lock reopens the check-then-act"),
            ("replace", "the persist must be atomic with the decision it records"),
            ("charge_budget", "the decision must not be made outside the lock"),
        ):
            with self.subTest(call=name):
                self.assertIn(name, inside, why)

        # Only the lock and its clock may sit outside it in the function body.
        outside = set()
        for statement in function.body:
            if isinstance(statement, ast.With):
                continue
            outside |= calls_within(statement)
        self.assertEqual(
            outside & {"publish", "raise_floor", "record", "replace", "charge_budget"},
            set(),
            "part of the ceiling decision has been hoisted out of the state lock",
        )

    def test_a_working_store_still_bounds_a_process_that_forgot(self):
        """The floor corrects the store upwards, never downwards."""
        for _index in range(CONTAINER_CEILING):
            self.assertEqual(self.post(self.envelope("Unexpected exit"))[0], 204)
        self.assertEqual(len(self.pushover.requests), CONTAINER_CEILING)

        self.write_state(
            {"version": 3, "entries": [], "budget": self.budget()}
        )
        self.assertEqual(self.post(self.envelope("Unexpected exit"))[0], 204)
        self.assertTrue(
            self.pushover.requests[-1]["form"]["title"].startswith("\U0001f507 "),
            "a rewound store handed the process its allowance a second time",
        )
        self.assertEqual(
            self.read_state()["budget"],
            self.budget(CONTAINER_CEILING, [(CONTAINER_ID, CONTAINER_CEILING, True)]),
        )

    def test_a_store_that_is_ahead_of_this_process_is_left_alone(self):
        """The floor raises, so a larger stored count has to win."""
        self.write_state(
            {
                "version": 3,
                "entries": [],
                "budget": self.budget(
                    CONTAINER_CEILING, [(CONTAINER_ID, CONTAINER_CEILING, False)]
                ),
            }
        )
        self.assertEqual(self.post(self.envelope("Unexpected exit"))[0], 204)
        self.assertTrue(
            self.pushover.requests[-1]["form"]["title"].startswith("\U0001f507 ")
        )
        self.assertEqual(len(self.pushover.requests), 1)

    def test_a_rejected_alert_says_so_on_stderr_with_its_status(self):
        """A rejected alert is not retried by Dozzle, so it must at least be logged."""
        self.pushover.response_status = 400
        self.pushover.response_body = b'{"user":"invalid","errors":["user key is not valid"]}'
        recorder = RecordingStderr()
        with contextlib.redirect_stderr(recorder):
            status, body = self.post(self.envelope())
        self.assertEqual((status, body), (502, b"upstream unavailable\n"))

        self.assertEqual(len(recorder.writes), 1, "one failure must be one write")
        line = recorder.writes[0]
        self.assertTrue(line.endswith("\n"))
        self.assertEqual(line.count("\n"), 1, "the line must be exactly one line")
        self.assertIn("alert-relay: pushover rejected the alert (HTTP 400)", line)
        self.assertIn("alert=\U0001f7e0 paperless_webserver unhealthy", line)
        self.assertIn("user key is not valid", line)

    def test_an_unreachable_upstream_is_distinguishable_from_a_rejection(self):
        """A rejection never heals and an outage does, so the log must say which."""
        self.config.pushover_api_url = "http://127.0.0.1:1/1/messages.json"
        recorder = RecordingStderr()
        with contextlib.redirect_stderr(recorder):
            status, body = self.post(self.envelope())
        self.assertEqual((status, body), (502, b"upstream unavailable\n"))

        self.assertEqual(len(recorder.writes), 1)
        line = recorder.writes[0]
        self.assertIn("alert-relay: pushover unreachable (", line)
        self.assertIn("alert=\U0001f7e0 paperless_webserver unhealthy", line)
        # No HTTP status, because there was no HTTP response.
        self.assertNotIn("HTTP ", line)
        self.assertNotIn("rejected", line)

    def test_no_credential_reaches_stderr_even_if_the_upstream_echoes_one(self):
        """A far end echoing a token must not put it in a log Dozzle renders."""
        self.pushover.response_status = 400
        self.pushover.response_body = json.dumps(
            {"errors": [f"token {PUSHOVER_TOKEN} and user {PUSHOVER_USER_KEY} rejected"]}
        ).encode("utf-8")
        recorder = RecordingStderr()
        with contextlib.redirect_stderr(recorder):
            self.assertEqual(self.post(self.envelope())[0], 502)

        output = recorder.getvalue()
        self.assertIn("alert-relay:", output, "the case must actually have logged")
        for secret in (PUSHOVER_TOKEN, PUSHOVER_USER_KEY):
            self.assertNotIn(secret, output)
        self.assertIn("[redacted]", output)

    def test_a_redacted_credential_cannot_survive_as_a_fragment(self):
        """Redact before truncating, proved on the helper at the boundary."""
        bound = self.relay_module.MAX_DIAGNOSTIC_CHARACTERS
        padded = "x" * (bound - 10) + PUSHOVER_TOKEN
        safe = self.relay_module.log_safe(padded, self.config)
        self.assertLessEqual(len(safe), bound)

        # Derived, not guessed: a guessed prefix length once let this pass with the
        # redaction deleted.
        surviving = PUSHOVER_TOKEN[: bound - (len(padded) - len(PUSHOVER_TOKEN))]
        self.assertEqual(len(surviving), 10)
        self.assertNotIn(surviving, safe)
        self.assertIn("[redacted]", safe)

    def test_an_upstream_response_cannot_forge_a_log_line_or_flood_the_log(self):
        """Upstream text and container names are not ours; a log line is a line."""
        self.pushover.response_status = 400
        self.pushover.response_body = (
            b"first\nalert-relay: pushover delivered everything fine\n" + b"z" * 20000
        )
        recorder = RecordingStderr()
        with contextlib.redirect_stderr(recorder):
            self.assertEqual(self.post(self.envelope())[0], 502)

        self.assertEqual(len(recorder.writes), 1)
        line = recorder.writes[0]
        self.assertEqual(line.count("\n"), 1, "the upstream forged a second line")
        self.assertLess(len(line), 1024, "an upstream body flooded the log")
        self.assertEqual(len(line.splitlines()), 1)

        self.assertEqual(
            self.relay_module.log_safe("svc\nforged", self.config), "svc?forged"
        )

    def test_concurrent_failures_produce_one_intact_line_each(self):
        """A log that garbles under concurrency is worse than no log.

        Driven at `publish` rather than through the relay, whose flock serialises
        publishes, and asserted on the write count because interleaving is luck.
        """
        self.config.pushover_api_url = "http://127.0.0.1:1/1/messages.json"
        failures = 16
        recorder = RecordingStderr()
        refusals = []

        def drive(index):
            notification = self.relay_module.render_notification(
                self.envelope("Unhealthy", container=f"service-{index}"), LINK_BASE
            )
            try:
                self.relay_module.publish(self.config, notification, self.config.pushover_token)
            except self.relay_module.UpstreamError:
                refusals.append(index)

        with contextlib.redirect_stderr(recorder):
            threads = [
                threading.Thread(target=drive, args=(index,), daemon=True)
                for index in range(failures)
            ]
            for thread in threads:
                thread.start()
            for thread in threads:
                thread.join(timeout=20)

        self.assertEqual(sorted(refusals), list(range(failures)))
        self.assertEqual(
            len(recorder.writes), failures,
            "one failure must be one write; two writes per line can interleave",
        )
        for write in recorder.writes:
            self.assertTrue(write.startswith("alert-relay: "))
            self.assertTrue(write.endswith("\n"))
            self.assertEqual(write.count("\n"), 1)
        self.assertEqual(len(recorder.getvalue().splitlines()), failures)
        self.assertEqual(
            sorted(
                line.split("alert=")[1].split(" detail=")[0]
                for line in recorder.getvalue().splitlines()
            ),
            sorted(f"\U0001f7e0 service-{index} unhealthy" for index in range(failures)),
        )

    def test_a_refused_publish_does_not_consume_the_allowance(self):
        """Publish first, persist second, so a refusing upstream cannot eat the allowance."""
        self.assertEqual(self.post(self.envelope("Unexpected exit"))[0], 204)
        charged = self.read_state()["budget"]

        self.pushover.response_status = 503
        for _index in range(CONTAINER_CEILING + 2):
            self.assertEqual(self.post(self.envelope("Unexpected exit"))[0], 502)
        self.assertEqual(self.read_state()["budget"], charged)

        self.pushover.response_status = 200
        self.assertEqual(self.post(self.envelope("Unexpected exit"))[0], 204)
        self.assertEqual(
            self.pushover.requests[-1]["form"]["title"],
            "\U0001f6d1 paperless_webserver exited (1)",
        )

    def test_budget_counters_cannot_crowd_out_unevictable_health_entries(self):
        """Counters are shed before unhealthy entries, which cannot be evicted.

        This defers the all-unhealthy raise; it does not prevent it.
        """
        # 85 of each is the largest pair that fits MAX_STATE_BYTES at the longest host;
        # the event below adds the counter that tips it over.
        long_host = "h" * 256
        planted = 85
        entries = [
            self.state_entry(f"{index:064x}", "unhealthy", "2026-08-15T01:00:00Z",
                             host=long_host)
            for index in range(planted)
        ]
        budget = {
            "day": self.today(),
            "count": 1,
            "notified": False,
            "containers": sorted(
                (
                    {
                        "identity": f"{long_host}\0{index:064x}",
                        "count": 1,
                        "notified": False,
                    }
                    for index in range(planted)
                ),
                key=lambda entry: entry["identity"],
            ),
        }
        self.write_ascii_state(
            {
                "version": 3,
                "entries": sorted(entries, key=lambda item: item["identity"]),
                "budget": budget,
            }
        )
        self.assertLessEqual(
            len(self.state_path.read_bytes()), self.relay_module.MAX_STATE_BYTES
        )

        self.assertEqual(self.request("GET", "/healthz", token=None)[0], 200)
        self.assertEqual(self.post(self.envelope("OOM", host=long_host))[0], 204)
        self.assertEqual(len(self.pushover.requests), 1)
        state = self.read_state()
        self.assertEqual(len(state["entries"]), planted)
        self.assertLess(len(state["budget"]["containers"]), planted + 1)
        self.assertLessEqual(
            len(self.state_path.read_bytes()), self.relay_module.MAX_STATE_BYTES
        )

    def test_budget_eviction_keeps_the_counters_that_are_doing_work(self):
        """Lowest count first, so a container at its ceiling keeps its latch."""
        entries = {
            f"nas\0{index:064x}": {
                "identity": f"nas\0{index:064x}",
                "count": 1 if index else 9,
                "notified": index == 0,
            }
            for index in range(self.relay_module.MAX_BUDGET_ENTRIES)
        }
        bounded, budget, _document = self.relay_module.bounded_state(
            {},
            {"day": self.today(), "count": 50, "notified": False, "containers": entries},
            FIXED_NOW,
        )
        self.assertEqual(bounded, {})
        self.assertEqual(len(budget["containers"]), self.relay_module.MAX_BUDGET_ENTRIES)

        crowded = dict(entries)
        for index in range(self.relay_module.MAX_BUDGET_ENTRIES,
                           self.relay_module.MAX_BUDGET_ENTRIES + 5):
            crowded[f"nas\0{index:064x}"] = {
                "identity": f"nas\0{index:064x}",
                "count": 2,
                "notified": False,
            }
        _bounded, budget, _document = self.relay_module.bounded_state(
            {},
            {"day": self.today(), "count": 50, "notified": False, "containers": crowded},
            FIXED_NOW,
        )
        self.assertEqual(len(budget["containers"]), self.relay_module.MAX_BUDGET_ENTRIES)
        self.assertIn(f"nas\0{0:064x}", budget["containers"])
        self.assertEqual(budget["containers"][f"nas\0{0:064x}"]["count"], 9)
        self.assertTrue(budget["containers"][f"nas\0{0:064x}"]["notified"])

    def test_malformed_budget_documents_fail_closed_without_traceback(self):
        entry = self.state_entry(CONTAINER_ID, "unhealthy", "2026-08-15T01:22:13Z")
        counter = {"identity": f"nas\0{CONTAINER_ID}", "count": 1, "notified": False}
        base = {"day": "2026-08-15", "count": 1, "notified": False,
                "containers": [counter]}
        fixtures = {
            "missing budget": None,
            "day is not a date": dict(base, day="yesterday"),
            "day is empty": dict(base, day=""),
            "count is negative": dict(base, count=-1),
            "count is a float": dict(base, count=1.5),
            # True is an int in Python; a count of True would read as 1.
            "count is a boolean": dict(base, count=True),
            "notice is not a boolean": dict(base, notified="yes"),
            "containers is a mapping": dict(base, containers={}),
            "counter has an extra key": dict(base, containers=[dict(counter, extra=1)]),
            "counter identity is invalid": dict(
                base, containers=[dict(counter, identity="nas")]
            ),
            "counters are not canonical": dict(base, containers=[counter, counter]),
            "too many counters": dict(
                base,
                containers=sorted(
                    (
                        {"identity": f"nas\0{index:064x}", "count": 1, "notified": False}
                        for index in range(self.relay_module.MAX_BUDGET_ENTRIES + 1)
                    ),
                    key=lambda item: item["identity"],
                ),
            ),
        }
        captured = io.StringIO()
        with contextlib.redirect_stderr(captured):
            for name, budget in fixtures.items():
                with self.subTest(name=name):
                    document = {"version": 3, "entries": [entry]}
                    if budget is not None:
                        document["budget"] = budget
                    self.write_ascii_state(document)
                    original = self.state_path.read_bytes()
                    self.assertEqual(
                        self.request("GET", "/healthz", token=None),
                        (503, b"state unavailable\n"),
                    )
                    self.assertEqual(
                        self.post(self.envelope("OOM")),
                        (500, b"state unavailable\n"),
                    )
                    self.assertEqual(self.pushover.requests, [])
                    self.assertEqual(self.state_path.read_bytes(), original)
        self.assertNotIn("Traceback", captured.getvalue())

    def test_version_two_state_migrates_into_a_full_allowance(self):
        """A v2 state file with no budget migrates and starts the day whole."""
        self.write_state(
            {
                "version": 2,
                "entries": [
                    self.state_entry(CONTAINER_ID, "unhealthy", "2026-08-15T01:22:13Z")
                ],
            }
        )
        self.assertEqual(self.request("GET", "/healthz", token=None)[0], 200)
        self.assertEqual(self.post(self.envelope("OOM"))[0], 204)
        self.assertEqual(
            self.read_state(),
            {
                "version": 3,
                "entries": [
                    self.state_entry(CONTAINER_ID, "unhealthy", "2026-08-15T01:22:13Z")
                ],
                "budget": self.budget(1, [(CONTAINER_ID, 1, False)]),
            },
        )

    def test_exit_and_oom_always_publish_without_changing_health_state(self):
        """Neither rule is a health transition, so neither writes a health entry."""
        for _iteration in range(2):
            self.assertEqual(self.post(self.envelope("Unexpected exit"))[0], 204)
            self.assertEqual(self.post(self.envelope("OOM"))[0], 204)
        self.assertEqual(len(self.pushover.requests), 4)
        self.assertEqual(
            self.read_state(),
            {
                "version": 3,
                "entries": [],
                "budget": self.budget(4, [(CONTAINER_ID, 4, False)]),
            },
        )

    def test_state_is_atomic_versioned_and_mode_0600(self):
        self.assertEqual(self.post(self.envelope())[0], 204)
        state = self.read_state()
        self.assertEqual(
            state,
            {
                "version": 3,
                "entries": [
                    self.state_entry(
                        CONTAINER_ID, "unhealthy", "2026-08-15T01:22:13Z"
                    )
                ],
                "budget": self.budget(1, [(CONTAINER_ID, 1, False)]),
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
        self.config.pushover_api_url = (
            f"http://127.0.0.1:{redirector.server_port}/1/messages.json"
        )

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

                before = len(self.pushover.requests)
                status_code, response_body = self.post(self.envelope())
                self.assertEqual(status_code, 500)
                self.assertEqual(response_body, b"state unavailable\n")
                self.assertEqual(len(self.pushover.requests), before)

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
                    self.assertEqual(self.pushover.requests, [])
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
                self.assertEqual(self.pushover.requests, [])
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
        self.assertEqual(self.pushover.requests, [])
        self.assertFalse(self.state_path.exists())
        self.assertNotIn("Traceback", captured.getvalue())

    def test_upstream_failure_does_not_commit_transition(self):
        self.pushover.response_status = 503
        status_code, response_body = self.post(self.envelope())
        self.assertEqual(status_code, 502)
        self.assertEqual(response_body, b"upstream unavailable\n")
        self.assertFalse(self.state_path.exists())

        self.pushover.response_status = 200
        self.assertEqual(self.post(self.envelope())[0], 204)
        expected_state = self.read_state()
        self.pushover.response_status = 503
        self.assertEqual(self.post(self.envelope("Recovery"))[0], 502)
        self.assertEqual(self.read_state(), expected_state)

    def test_markup_is_escaped_and_diagnostics_are_redacted(self):
        """Container and host text is escaped in `message` (html=1); `title` stays raw."""
        hostile = '<b>svc</b> & "q" <a href=\'x\'>'
        payload = self.envelope(container=hostile, host="nas<host>")
        captured = io.StringIO()
        with contextlib.redirect_stderr(captured):
            status_code, response_body = self.post(payload)
            wrong_status, wrong_body = self.post(payload, token="request-secret")
        self.assertEqual(status_code, 204)
        self.assertEqual(wrong_status, 401)
        published = self.pushover.requests[0]["form"]
        self.assertEqual(published["title"], f"\U0001f7e0 {hostile} unhealthy")
        escaped = "&lt;b&gt;svc&lt;/b&gt; &amp; &quot;q&quot; &lt;a href=&#x27;x&#x27;&gt;"
        self.assertEqual(published["message"].count(escaped), 2)
        self.assertIn("\U0001f5a5\ufe0f <b>Host</b> nas&lt;host&gt;\n", published["message"])
        # The only markup left is the relay's own fourteen tags.
        self.assertEqual(published["message"].count("<b>"), 4)
        self.assertEqual(published["message"].count("</b>"), 4)
        self.assertEqual(published["message"].count("<"), 14)
        combined = captured.getvalue() + response_body.decode() + wrong_body.decode()
        for secret in (RELAY_TOKEN, PUSHOVER_TOKEN, PUSHOVER_USER_KEY, "request-secret"):
            self.assertNotIn(secret, combined)

    def test_escaping_bounds_the_field_before_it_escapes_it(self):
        """Truncate then escape, so no entity is cut in half at the boundary."""
        self.assertEqual(
            self.relay_module.html_escape("x" * 200), "x" * 128
        )
        # Bounded on its output, by dropping whole input characters.
        escaped = self.relay_module.html_escape("&" * 200)
        self.assertLessEqual(
            len(escaped), self.relay_module.MAX_ESCAPED_FIELD_CHARACTERS
        )
        self.assertEqual(escaped, "&amp;" * (len(escaped) // 5))
        self.assertEqual(escaped.replace("&amp;", ""), "")

        long_name = "x" * 200
        self.assertEqual(
            self.post(self.envelope(container=long_name))[0], 204
        )
        published = self.pushover.requests[-1]["form"]
        self.assertIn(f">{'x' * 128}</a>\n", published["message"])
        self.assertNotIn("x" * 129, published["message"])

    def test_no_rendered_message_can_exceed_what_pushover_accepts(self):
        """Over Pushover's 1024 cap is a refused message and a lost alert.

        Escaping makes it reachable: `'` renders as six characters.
        """
        hostile = "'" * 256
        cap = self.relay_module.MAX_MESSAGE_CHARACTERS
        for rule, changes in (
            ("Unhealthy", {}),
            ("OOM", {}),
            ("Unexpected exit", {"exitCode": "255"}),
        ):
            with self.subTest(rule=rule):
                event = dict(
                    self.envelope(rule, container=hostile, host=hostile, **changes)
                )
                rendered = self.relay_module.render_notification(event, LINK_BASE)
                self.assertLessEqual(len(rendered["message"]), cap)
                self.assertNotIn("&#x2", rendered["message"].removesuffix("&#x27;")[-5:])

        for scope, allowance in (("global", None), ("container", 25)):
            with self.subTest(scope=scope):
                notice = self.relay_module.render_ceiling_notice(
                    self.envelope(container=hostile, host=hostile),
                    scope, 10, "2026-09-13", allowance
                )
                self.assertLessEqual(len(notice["message"]), cap)

        self.assertEqual(
            self.post(self.envelope(container=hostile, host=hostile))[0], 204
        )
        self.assertLessEqual(
            len(self.pushover.requests[-1]["form"]["message"]), cap
        )

    def test_no_rendered_title_can_exceed_what_pushover_accepts(self):
        """Pushover rejects a title over 250 characters; each renderer's slice bounds it."""
        longest = "c" * 256
        cap = self.relay_module.MAX_TITLE_CHARACTERS
        for rule, changes in (
            ("Unhealthy", {}),
            ("OOM", {}),
            ("Unexpected exit", {"exitCode": "255"}),
            ("Recovery", {}),
        ):
            with self.subTest(rule=rule):
                title = self.relay_module.render_notification(
                    self.envelope(rule, container=longest, host=longest, **changes),
                    LINK_BASE,
                )["title"]
                self.assertLessEqual(len(title), cap)
                # Bounded, not emptied: the name still identifies the container.
                self.assertIn("c" * 64, title)

        for scope, allowance in (("container", 25), ("container", None), ("global", None)):
            with self.subTest(scope=scope, allowance=allowance):
                title = self.relay_module.render_ceiling_notice(
                    self.envelope(container=longest, host=longest),
                    scope, 10, "2026-09-13", allowance
                )["title"]
                self.assertLessEqual(len(title), cap)

        self.assertEqual(
            self.post(self.envelope(container=longest, host=longest))[0], 204
        )
        self.assertLessEqual(len(self.pushover.requests[-1]["form"]["title"]), cap)

    def test_the_suppression_notice_title_is_bounded_on_the_wire(self):
        """The notice's own title, reached the way a running relay reaches it."""
        longest = "c" * 256
        for _index in range(CONTAINER_CEILING + 1):
            self.assertEqual(
                self.post(self.envelope("Unexpected exit", container=longest))[0], 204
            )
        notice = self.pushover.requests[-1]["form"]
        self.assertTrue(notice["title"].startswith("\U0001f507 "))
        self.assertLessEqual(
            len(notice["title"]), self.relay_module.MAX_TITLE_CHARACTERS
        )

    def test_the_container_notice_says_what_still_gets_through(self):
        """"Suppressed" would overstate it while the OOM allowance remains."""
        for _index in range(CONTAINER_CEILING + 1):
            self.assertEqual(self.post(self.envelope("Unexpected exit"))[0], 204)
        notice = self.pushover.requests[-1]["form"]
        self.assertIn(
            f"<i>Out-of-memory kills still get through, up to {OOM_CONTAINER_CEILING} a day",
            notice["message"],
        )

        # Past the OOM allowance: the notice must not claim anything still reports.
        spent = "b" * 64
        for _index in range(OOM_CONTAINER_CEILING):
            self.assertEqual(
                self.post(self.envelope("OOM", containerId=spent))[0], 204
            )
        self.assertEqual(
            self.post(self.envelope("Unexpected exit", containerId=spent))[0], 204
        )
        spent_notice = self.pushover.requests[-1]["form"]
        self.assertTrue(spent_notice["title"].startswith("\U0001f507 "))
        self.assertNotIn("still get through", spent_notice["message"])

    def test_the_global_notice_claims_no_exception_at_all(self):
        for index in range(GLOBAL_CEILING):
            self.assertEqual(
                self.post(
                    self.envelope("Unexpected exit", containerId=f"{index:064x}")
                )[0],
                204,
            )
        self.assertEqual(
            self.post(
                self.envelope("OOM", containerId=f"{GLOBAL_CEILING:064x}")
            )[0],
            204,
        )
        notice = self.pushover.requests[-1]["form"]
        self.assertEqual(notice["title"], "\U0001f507 Alerts paused")
        self.assertIn("<b>Every alert</b> is", notice["message"])
        self.assertNotIn("still get through", notice["message"])

    # --- Beszel host alerts, POSTed to /beszel ------------------------------

    # Each Beszel 0.20.0 subject and body, and the title and priority expected.
    BESZEL_SUBJECTS = (
        ("ASUSTOR-AS6704T CPU above threshold",
         "CPU averaged 93.20% for the previous 10 minutes.",
         "\U0001f534 ASUSTOR-AS6704T CPU above threshold", 1),
        ("ASUSTOR-AS6704T CPU below threshold",
         "CPU averaged 41.07% for the previous 10 minutes.",
         "\U0001f7e2 ASUSTOR-AS6704T CPU back below threshold", -1),
        ("ASUSTOR-AS6704T temperature above threshold",
         "Highest sensor coretemp_core_2 averaged 87.53\u00b0C for the previous 15 minutes.",
         "\U0001f534 ASUSTOR-AS6704T temperature above threshold", 1),
        ("Office NAS 2 15m load below threshold",
         "15m Load averaged 1.20 for the previous 10 minutes.",
         "\U0001f7e2 Office NAS 2 15m load back below threshold", -1),
        ("ASUSTOR-AS6704T disk usage above threshold",
         "Usage of /extra-filesystems/volume1 averaged 85.12% for the previous 1 minute.",
         "\U0001f534 ASUSTOR-AS6704T disk usage above threshold", 1),
        ("Connection to ASUSTOR-AS6704T is down \U0001f534",
         "Connection to ASUSTOR-AS6704T is down ",
         "\U0001f534 ASUSTOR-AS6704T unreachable", 1),
        ("Connection to ASUSTOR-AS6704T is up \u2705",
         "Connection to ASUSTOR-AS6704T is up ",
         "\U0001f7e2 ASUSTOR-AS6704T reachable again", -1),
        # Battery is the one inverted alert: its problem is the low side.
        ("laptop battery below threshold",
         "Battery averaged 8.00% for the previous 5 minutes.",
         "\U0001f534 laptop battery below threshold", 1),
        ("laptop battery above threshold",
         "Battery averaged 64.00% for the previous 5 minutes.",
         "\U0001f7e2 laptop battery back above threshold", -1),
        # Unparsed titles go out as Beszel wrote them.
        ("Services recovered on ASUSTOR-AS6704T \u2705",
         "No services are in the failed state on ASUSTOR-AS6704T.",
         "Services recovered on ASUSTOR-AS6704T \u2705", -1),
        ("ASUSTOR-AS6704T containers are healthy \u2705",
         "ASUSTOR-AS6704T containers are healthy",
         "ASUSTOR-AS6704T containers are healthy \u2705", -1),
        ("SMART failure on ASUSTOR-AS6704T: nvme0 \U0001f534",
         "Disk nvme0 (WDC WD40EFPX) SMART status changed to FAILED",
         "SMART failure on ASUSTOR-AS6704T: nvme0 \U0001f534", 1),
        ("Test Alert", "This is a notification from Beszel.", "Test Alert", 1),
    )

    @staticmethod
    def beszel(title, body, link=None):
        """A Beszel alert as its generic webhook sends it: body, blank line, link."""
        if link is None:
            link = f"{BESZEL_LINK_BASE}/system/{BESZEL_SYSTEM_ID}"
        return {"title": title, "message": f"{body}\n\n{link}"}

    def post_beszel(self, payload, **kwargs):
        if not isinstance(payload, (bytes, dict)):
            payload = json.dumps(payload).encode("utf-8")
        return self.request("POST", "/beszel", payload, **kwargs)

    def render_beszel(self, subject, link_base=BESZEL_LINK_BASE):
        return self.relay_module.render_beszel(
            self.beszel(subject[0], subject[1]), link_base, FIXED_NOW
        )

    def test_every_beszel_subject_maps_to_its_title_and_priority(self):
        self.relay.config = self.relay_module.Config.from_mapping(
            self.environment(ALERT_DAILY_GLOBAL_CEILING="1000")
        )
        for subject, body, title, priority in self.BESZEL_SUBJECTS:
            with self.subTest(subject=subject):
                before = len(self.pushover.requests)
                self.assertEqual(self.post_beszel(self.beszel(subject, body))[0], 204)
                self.assertEqual(len(self.pushover.requests), before + 1)
                form = self.pushover.requests[-1]["form"]
                self.assertEqual(form["title"], title)
                self.assertEqual(
                    form["priority"], str(priority),
                    "a Beszel recovery must arrive quiet at -1 and an alert must ring at 1",
                )

    def test_a_beszel_message_leads_with_its_state_and_labels_its_facts(self):
        red = self.relay_module.COLOR_RED
        green = self.relay_module.COLOR_GREEN
        subjects = self.BESZEL_SUBJECTS

        above = self.render_beszel(subjects[2])
        shape = message_shape(above["message"])
        self.assertEqual(shape["labels"], ["Host", "Average", "When"])
        self.assertEqual(
            shape["lead"],
            f'<b>ASUSTOR-AS6704T</b> temperature is <font color="{red}">above</font> its threshold',
        )
        self.assertIn(
            "\U0001f321\ufe0f <b>Average</b> 87.53\u00b0C over 15 minutes "
            "\u00b7 Highest sensor coretemp_core_2",
            above["message"],
        )
        self.assertIn("\U0001f552 <b>When</b> 15 Aug 12:00 UTC", above["message"])

        below = self.render_beszel(subjects[1])
        self.assertEqual(
            message_shape(below["message"])["lead"],
            f'<b>ASUSTOR-AS6704T</b> CPU is <font color="{green}">back below</font> its threshold',
        )
        self.assertIn("\U0001f4c8 <b>Average</b> 41.07% over 10 minutes \u00b7 CPU", below["message"])
        self.assertIn("over 1 minute \u00b7", self.render_beszel(subjects[4])["message"])

        down = self.render_beszel(subjects[5])
        self.assertEqual(message_shape(down["message"])["labels"], ["Host", "When"])
        self.assertIn(f'<font color="{red}">unreachable</font>', down["message"])
        up = self.render_beszel(subjects[6])
        self.assertIn(f'<font color="{green}">reachable</font> again', up["message"])

        fallback = self.render_beszel(subjects[-1])
        self.assertEqual(fallback["message"], "This is a notification from Beszel.")

    def test_the_beszel_envelope_is_exactly_a_title_and_a_message(self):
        valid = self.beszel("Test Alert", "line one\nline two")
        refused = {
            "a missing message": {"title": "Test Alert"},
            "an extra key": dict(valid, priority=2),
            "a non-string title": dict(valid, title=1),
            "a non-string message": dict(valid, message=["x"]),
            "an empty title": dict(valid, title=""),
            "a newline in the title": dict(valid, title="Test\nAlert"),
            "a carriage return in the message": dict(valid, message="a\rb"),
            "a NUL in the message": dict(valid, message="a\0b"),
            "not an object": ["Test Alert"],
        }
        for name, payload in refused.items():
            with self.subTest(refused=name):
                self.assertEqual(self.post_beszel(payload)[0], 400)
        self.assertEqual(
            self.request("POST", "/beszel", b'{"title":"a","title":"b","message":"c"}')[0], 400
        )
        self.assertEqual(self.post_beszel(valid, headers={"Content-Type": "text/plain"})[0], 400)
        self.assertEqual(
            self.request("POST", "/beszel", b"x" * (self.relay_module.MAX_BODY_BYTES + 1))[0], 413
        )
        self.assertEqual(self.pushover.requests, [])
        self.assertEqual(self.post_beszel(valid)[0], 204)

    def test_the_beszel_route_is_behind_the_relay_bearer_token(self):
        payload = self.beszel("Test Alert", "This is a notification from Beszel.")
        for token in (None, "wrong-token"):
            with self.subTest(token=token):
                self.assertEqual(
                    self.post_beszel(payload, token=token)[0], 401,
                    "the /beszel route must refuse a request without the relay's bearer token",
                )
        self.assertEqual(self.pushover.requests, [])
        self.assertEqual(self.request("GET", "/beszel", token=None)[0], 404)
        self.assertEqual(self.request("POST", "/beszel/", payload)[0], 404)
        self.assertEqual(self.request("POST", "/elsewhere", payload)[0], 404)

    def test_without_the_alerts_token_beszel_is_refused_and_containers_still_alert(self):
        self.relay.config = self.relay_module.Config.from_mapping(
            self.environment(PUSHOVER_ALERTS_TOKEN=None)
        )
        recorder = RecordingStderr()
        with contextlib.redirect_stderr(recorder):
            status, body = self.post_beszel(self.beszel("Test Alert", "x"))
        self.assertEqual((status, body), (503, b"alerts token unavailable\n"))
        self.assertEqual(
            recorder.writes,
            ["alert-relay: PUSHOVER_ALERTS_TOKEN is not set; a Beszel alert was not delivered\n"],
        )
        self.assertEqual(self.pushover.requests, [])
        self.assertEqual(self.post(self.envelope())[0], 204)
        self.assertEqual(len(self.pushover.requests), 1)

    def test_each_route_publishes_on_its_own_pushover_application(self):
        self.assertEqual(self.post(self.envelope())[0], 204)
        self.assertEqual(self.post_beszel(self.beszel(*self.BESZEL_SUBJECTS[0][:2]))[0], 204)
        container, host = self.published_forms()
        self.assertEqual(container["token"], PUSHOVER_TOKEN, "/alerts must stay on the Containers application")
        self.assertEqual(host["token"], ALERTS_TOKEN, "/beszel must publish on the Alerts application")
        self.assertEqual(container["user"], PUSHOVER_USER_KEY)
        self.assertEqual(host["user"], PUSHOVER_USER_KEY)

    # Beszel 0.20.0 titles about Golem, one per shape the relay routes on.
    GOLEM_SUBJECTS = (
        ("Connection to Golem is down \U0001f534", "Connection to Golem is down "),
        ("Golem CPU above threshold", "CPU averaged 93.20% for the previous 10 minutes."),
        ("Golem memory below threshold", "Memory averaged 40.00% for the previous 10 minutes."),
        ("Golem disk usage above threshold",
         "Usage of / averaged 85.12% for the previous 10 minutes."),
        ("Failed services on Golem \U0001f534", "1 failed service on Golem: cron.service"),
    )

    def test_golem_alerts_publish_on_the_golem_application(self):
        link = f"{BESZEL_LINK_BASE}/system/g0lem1d"
        for title, body in self.GOLEM_SUBJECTS:
            with self.subTest(title=title):
                self.assertEqual(self.post_beszel(self.beszel(title, body, link))[0], 204)
                form = self.pushover.requests[-1]["form"]
                self.assertEqual(form["token"], GOLEM_TOKEN, "Golem must publish on the Golem application")
                self.assertEqual(form["user"], PUSHOVER_USER_KEY)
                self.assertEqual(form["url"], link)
                self.assertIn("Golem", form["title"])
                self.assertNotIn("Reason", form["message"])
        self.assertIn("\U0001f5a5\ufe0f <b>Host</b> Golem", self.pushover.requests[0]["form"]["message"])

    def test_the_former_golem_system_name_still_publishes_on_the_golem_application(self):
        # Until roles/beszel renames the hub record, Beszel titles carry the old name.
        for title, body in self.GOLEM_SUBJECTS:
            title, body = title.replace("Golem", "golem"), body.replace("Golem", "golem")
            with self.subTest(title=title):
                self.assertEqual(self.post_beszel(self.beszel(title, body))[0], 204)
                self.assertEqual(self.pushover.requests[-1]["form"]["token"], GOLEM_TOKEN)

    def test_the_nas_and_lookalike_systems_stay_on_the_alerts_application(self):
        for title, body in (
            self.BESZEL_SUBJECTS[0][:2],
            ("golem-2 CPU above threshold", "CPU averaged 93.20% for the previous 10 minutes."),
            ("GOLEM CPU above threshold", "CPU averaged 93.20% for the previous 10 minutes."),
            ("Connection to notgolem is down \U0001f534", "Connection to notgolem is down "),
            ("Unhealthy container golem on ASUSTOR-AS6704T \U0001f534", "golem is unhealthy"),
            ("golem2 containers are healthy \u2705", "golem2 containers are healthy"),
            ("Test Alert", "This is a notification from Beszel."),
        ):
            with self.subTest(title=title):
                self.assertEqual(self.post_beszel(self.beszel(title, body))[0], 204)
                self.assertEqual(self.pushover.requests[-1]["form"]["token"], ALERTS_TOKEN)

    def test_without_the_golem_token_golem_alerts_go_to_alerts_and_say_so(self):
        self.relay.config = self.relay_module.Config.from_mapping(
            self.environment(PUSHOVER_GOLEM_TOKEN=None)
        )
        amber = self.relay_module.COLOR_AMBER
        reason = (f'\u2753 <b>Reason</b> <font color="{amber}">Golem app token not set</font>'
                  "; sent on Alerts")
        for title, body in (self.GOLEM_SUBJECTS[0], self.GOLEM_SUBJECTS[-1]):
            with self.subTest(title=title):
                recorder = RecordingStderr()
                with contextlib.redirect_stderr(recorder):
                    self.assertEqual(self.post_beszel(self.beszel(title, body))[0], 204)
                form = self.pushover.requests[-1]["form"]
                self.assertEqual(form["token"], ALERTS_TOKEN,
                                 "a Golem alert must still be delivered without the Golem token")
                self.assertIn(reason, form["message"])
                self.assertEqual(recorder.writes, [
                    "alert-relay: PUSHOVER_GOLEM_TOKEN is not set; "
                    "a Golem alert was sent on the Alerts application\n",
                ])
        recorder = RecordingStderr()
        with contextlib.redirect_stderr(recorder):
            self.assertEqual(self.post_beszel(self.beszel(*self.BESZEL_SUBJECTS[0][:2]))[0], 204)
        self.assertNotIn("Reason", self.pushover.requests[-1]["form"]["message"])
        self.assertEqual(recorder.writes, [])

    def test_a_ceiling_golem_trips_is_announced_on_the_alerts_application(self):
        alert = self.beszel(*self.GOLEM_SUBJECTS[0])
        for _index in range(GLOBAL_CEILING + 1):
            self.assertEqual(self.post_beszel(alert)[0], 204)
        *alerts, notice = self.published_forms()
        self.assertEqual({form["token"] for form in alerts}, {GOLEM_TOKEN})
        self.assertEqual(notice["title"], "\U0001f507 Alerts paused")
        self.assertEqual(notice["token"], ALERTS_TOKEN,
                         "the ceiling is shared, so its pause is the NAS's news too")

    def test_the_golem_system_name_is_one_beszel_manages(self):
        defaults = (ROOT / "roles/beszel/defaults/main.yml").read_text()
        name = re.escape(self.relay_module.GOLEM_BESZEL_SYSTEM)
        self.assertRegex(
            defaults, rf"(?m)^beszel_remote_systems:\n(?:[ #].*\n|\n)*?  - name: {name}$",
            "GOLEM_BESZEL_SYSTEM must name a system in beszel_remote_systems",
        )

    def test_the_golem_token_is_redacted_like_the_others(self):
        self.pushover.response_status = 400
        self.pushover.response_body = f'{{"errors":["token {GOLEM_TOKEN} is invalid"]}}'.encode()
        recorder = RecordingStderr()
        with contextlib.redirect_stderr(recorder):
            status, _body = self.post_beszel(self.beszel(*self.GOLEM_SUBJECTS[0]))
        self.assertEqual(status, 502)
        self.assertIn("[redacted]", recorder.getvalue())
        self.assertNotIn(GOLEM_TOKEN, recorder.getvalue())

    # --- golem's container events, POSTed to /alerts by golem's Dozzle agent --

    def test_golem_container_events_publish_on_the_golem_application(self):
        golem = self.relay_module.GOLEM_DOZZLE_HOST
        # Unhealthy and Recovery share a container, the others take their own,
        # so no container reaches its ceiling here.
        for rule, container_id in (("OOM", "0123456789ab"), ("Unexpected exit", "ba9876543210"),
                                   ("Unhealthy", CONTAINER_ID), ("Recovery", CONTAINER_ID)):
            with self.subTest(rule=rule):
                self.assertEqual(self.post(self.envelope(rule, host=golem, containerId=container_id))[0], 204)
                form = self.pushover.requests[-1]["form"]
                self.assertEqual(form["token"], GOLEM_TOKEN, "golem must publish on the Golem application")
                self.assertEqual(form["user"], PUSHOVER_USER_KEY)
                self.assertIn(f"\U0001f5a5️ <b>Host</b> {golem}", form["message"])
                self.assertNotIn("Reason", form["message"])
        self.assertEqual(self.published_forms()[0]["priority"], "2", "an OOM keeps its emergency priority")

    def test_nas_and_lookalike_container_hosts_stay_on_the_containers_application(self):
        for host in ("nas", "golem-2", "notgolem", "GOLEM", "golem ", "Golem "):
            with self.subTest(host=host):
                self.assertEqual(self.post(self.envelope("Unexpected exit", host=host))[0], 204)
                self.assertEqual(self.pushover.requests[-1]["form"]["token"], PUSHOVER_TOKEN)

    def test_without_the_golem_token_golem_container_events_go_to_containers_and_say_so(self):
        self.relay.config = self.relay_module.Config.from_mapping(
            self.environment(PUSHOVER_GOLEM_TOKEN=None)
        )
        amber = self.relay_module.COLOR_AMBER
        reason = (f'❓ <b>Reason</b> <font color="{amber}">Golem app token not set</font>'
                  "; sent on Containers")
        recorder = RecordingStderr()
        with contextlib.redirect_stderr(recorder):
            self.assertEqual(self.post(self.envelope("Unexpected exit", host="Golem"))[0], 204)
        form = self.pushover.requests[-1]["form"]
        self.assertEqual(form["token"], PUSHOVER_TOKEN,
                         "a Golem event must still be delivered without the Golem token")
        self.assertIn(reason, form["message"])
        self.assertEqual(recorder.writes, [
            "alert-relay: PUSHOVER_GOLEM_TOKEN is not set; "
            "a Golem container event was sent on the Containers application\n",
        ])
        recorder = RecordingStderr()
        with contextlib.redirect_stderr(recorder):
            self.assertEqual(self.post(self.envelope("Unexpected exit"))[0], 204)
        self.assertNotIn("Reason", self.pushover.requests[-1]["form"]["message"])
        self.assertEqual(recorder.writes, [])

    def test_health_state_is_kept_per_host_for_the_same_container_id(self):
        # One container id on both hosts: golem going unhealthy must not read as
        # a duplicate of the NAS's, and its recovery closes only its own entry.
        self.assertEqual(self.post(self.envelope("Unhealthy"))[0], 204)
        self.assertEqual(self.post(self.envelope("Unhealthy", host="Golem"))[0], 204)
        self.assertEqual(self.post(self.envelope(
            "Recovery", host="Golem", timestamp="2026-08-15T01:23:13Z"))[0], 204)
        self.assertEqual([form["token"] for form in self.published_forms()],
                         [PUSHOVER_TOKEN, GOLEM_TOKEN, GOLEM_TOKEN])
        states = {entry["identity"].split("\0")[0]: entry["state"]
                  for entry in self.read_state()["entries"]}
        self.assertEqual(states, {"nas": "unhealthy", "Golem": "healthy"})

    def test_the_former_golem_host_is_the_same_host(self):
        # An agent still on the old DOZZLE_HOSTNAME is Golem too: its recovery
        # closes an Unhealthy the renamed agent opened, on one identity.
        self.assertEqual(self.post(self.envelope("Unhealthy", host="golem"))[0], 204)
        self.assertEqual(self.post(self.envelope(
            "Recovery", host="Golem", timestamp="2026-08-15T01:23:13Z"))[0], 204)
        forms = self.published_forms()
        self.assertEqual([form["token"] for form in forms], [GOLEM_TOKEN, GOLEM_TOKEN])
        self.assertIn("\U0001f5a5️ <b>Host</b> Golem", forms[0]["message"])
        self.assertEqual([entry["identity"].split("\0")[0] for entry in self.read_state()["entries"]],
                         ["Golem"])

    def test_a_ceiling_a_golem_container_trips_is_announced_on_the_containers_application(self):
        event = self.envelope("Unexpected exit", host="Golem")
        for _index in range(CONTAINER_CEILING + 1):
            self.assertEqual(self.post(event)[0], 204)
        *alerts, notice = self.published_forms()
        self.assertEqual(len(alerts), CONTAINER_CEILING)
        self.assertEqual({form["token"] for form in alerts}, {GOLEM_TOKEN})
        self.assertEqual(notice["token"], PUSHOVER_TOKEN)

    # --- exact repeats of one /alerts envelope --------------------------------

    def deduplicate(self):
        """Give the running server the deployed duplicate window back."""
        self.relay_module.DUPLICATE_WINDOW = self.deployed_duplicate_window
        self.relay.delivered_events = self.relay_module.DeliveredEvents()

    def test_the_deployed_relay_drops_repeats(self):
        self.assertGreater(load_relay_module().DUPLICATE_WINDOW, timedelta(0))

    def test_an_exact_repeat_is_acknowledged_and_not_published_or_charged(self):
        self.deduplicate()
        event = self.envelope("Unexpected exit", host="Golem")
        for _attempt in range(3):
            self.assertEqual(self.post(event)[0], 204)
        self.assertEqual(len(self.published_forms()), 1)
        self.assertEqual(self.read_state()["budget"]["count"], 1)

    def test_the_former_host_name_repeats_the_renamed_one(self):
        self.deduplicate()
        self.assertEqual(self.post(self.envelope("Unexpected exit", host="golem"))[0], 204)
        self.assertEqual(self.post(self.envelope("Unexpected exit", host="Golem"))[0], 204)
        self.assertEqual(len(self.published_forms()), 1)

    def test_concurrent_repeats_publish_once(self):
        self.deduplicate()
        event = self.envelope("OOM", host="Golem")
        statuses = []
        threads = [threading.Thread(target=lambda: statuses.append(self.post(event)[0]))
                   for _index in range(3)]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join(timeout=5)
        self.assertEqual(statuses, [204, 204, 204])
        self.assertEqual(len(self.published_forms()), 1)

    def test_a_different_timestamp_container_event_or_host_is_still_sent(self):
        self.deduplicate()
        base = self.envelope("Unexpected exit")
        for event in (
            base,
            dict(base, timestamp="2026-08-15T01:22:13.000000001Z"),
            dict(base, containerId="ba9876543210"),
            self.envelope("OOM"),
            dict(base, host="Golem"),
        ):
            with self.subTest(event=event):
                before = len(self.published_forms())
                self.assertEqual(self.post(event)[0], 204)
                self.assertEqual(len(self.published_forms()), before + 1)

    def test_an_equal_time_unhealthy_repeat_is_now_dropped(self):
        # It used to republish (the 2026-08-15 ordering design); a repeat with
        # the same stamp is the same delivery, so it is dropped like any other.
        self.deduplicate()
        unhealthy = self.envelope("Unhealthy")
        self.assertEqual(self.post(unhealthy)[0], 204)
        self.assertEqual(self.post(unhealthy)[0], 204)
        self.assertEqual(len(self.published_forms()), 1)

    def test_a_repeat_of_a_refused_publish_is_sent(self):
        self.deduplicate()
        event = self.envelope("Unexpected exit")
        self.pushover.response_status = 500
        with contextlib.redirect_stderr(RecordingStderr()):
            self.assertEqual(self.post(event)[0], 502)
        self.pushover.response_status = 200
        self.assertEqual(self.post(event)[0], 204)
        self.assertEqual(self.pushover.requests[-1]["form"]["token"], PUSHOVER_TOKEN)
        self.assertEqual(self.post(event)[0], 204)
        self.assertEqual(len(self.pushover.requests), 2)

    def test_repeats_expire_with_the_window_and_the_capacity(self):
        delivered = self.relay_module.DeliveredEvents(window=timedelta(minutes=10), capacity=2)
        first, second, third = (self.envelope("OOM", containerId=f"{index:012x}")
                                for index in range(3))
        delivered.record(first, FIXED_NOW)
        self.assertTrue(delivered.seen(first, FIXED_NOW + timedelta(minutes=9)))
        self.assertFalse(delivered.seen(first, FIXED_NOW + timedelta(minutes=10)))
        delivered.record(first, FIXED_NOW)
        delivered.record(second, FIXED_NOW)
        delivered.record(third, FIXED_NOW)
        self.assertFalse(delivered.seen(first, FIXED_NOW), "the oldest goes past capacity")
        self.assertTrue(delivered.seen(second, FIXED_NOW))
        self.assertTrue(delivered.seen(third, FIXED_NOW))

    def test_the_golem_dozzle_host_is_the_label_of_the_remote_agent(self):
        inventory = (ROOT / "inventory/group_vars/all/service_dozzle.yml").read_text()
        name = re.escape(self.relay_module.GOLEM_DOZZLE_HOST)
        self.assertRegex(
            inventory, rf'(?m)^dozzle_remote_agent: "[^"|]+\|{name}"$',
            "GOLEM_DOZZLE_HOST must be the name dozzle_remote_agent gives golem's agent",
        )

    def test_the_alerts_token_is_redacted_like_the_others(self):
        self.pushover.response_status = 400
        self.pushover.response_body = f'{{"errors":["token {ALERTS_TOKEN} is invalid"]}}'.encode()
        recorder = RecordingStderr()
        with contextlib.redirect_stderr(recorder):
            status, _body = self.post_beszel(self.beszel("Test Alert", "x"))
        self.assertEqual(status, 502)
        self.assertIn("[redacted]", recorder.getvalue())
        self.assertNotIn(ALERTS_TOKEN, recorder.getvalue())

    def test_a_beszel_alert_charges_only_the_global_ceiling(self):
        alert = self.beszel(*self.BESZEL_SUBJECTS[0][:2])
        self.assertEqual(self.post_beszel(alert)[0], 204)
        budget = self.read_state()["budget"]
        self.assertEqual(budget["count"], 1)
        self.assertEqual(
            budget["containers"], [],
            "a Beszel alert has no container, so it must charge only the global counter",
        )
        for _index in range(GLOBAL_CEILING - 1):
            self.assertEqual(self.post_beszel(alert)[0], 204)
        self.assertEqual(len(self.pushover.requests), GLOBAL_CEILING)

        self.assertEqual(self.post_beszel(alert)[0], 204)
        notice = self.pushover.requests[-1]["form"]
        self.assertEqual(notice["title"], "\U0001f507 Alerts paused")
        self.assertIn("<b>Every alert</b> is", notice["message"])
        self.assertIn("<b>Host</b> ASUSTOR-AS6704T", notice["message"])
        self.assertEqual(notice["token"], ALERTS_TOKEN)

        self.assertEqual(self.post(self.envelope("Unexpected exit"))[0], 204)
        self.assertEqual(self.post_beszel(alert)[0], 204)
        self.assertEqual(len(self.pushover.requests), GLOBAL_CEILING + 1)
        budget = self.read_state()["budget"]
        self.assertEqual((budget["count"], budget["containers"], budget["notified"]),
                         (GLOBAL_CEILING, [], True))

    def test_a_beszel_button_links_only_to_this_relays_beszel_system_page(self):
        subject, body = self.BESZEL_SUBJECTS[0][:2]
        render = self.relay_module.render_beszel
        valid = f"{BESZEL_LINK_BASE}/system/{BESZEL_SYSTEM_ID}"
        rendered = render(self.beszel(subject, body, valid), BESZEL_LINK_BASE, FIXED_NOW)
        self.assertEqual((rendered.get("url"), rendered.get("url_title")), (valid, "Open in Beszel"))

        refused = {
            "the app URL alone": BESZEL_LINK_BASE,
            "another origin": f"https://elsewhere.example/system/{BESZEL_SYSTEM_ID}",
            "a lookalike host": f"{BESZEL_LINK_BASE}.elsewhere.example/system/{BESZEL_SYSTEM_ID}",
            "a path escape": f"{BESZEL_LINK_BASE}/system/../_/admin",
            "a query": f"{BESZEL_LINK_BASE}/system/{BESZEL_SYSTEM_ID}?next=https://elsewhere.example",
            "a quote": f'{BESZEL_LINK_BASE}/system/abc"onclick=x',
            "a script": f"javascript:alert(1)//{BESZEL_LINK_BASE}/system/{BESZEL_SYSTEM_ID}",
            "an empty id": f"{BESZEL_LINK_BASE}/system/",
        }
        for name, link in refused.items():
            with self.subTest(refused=name):
                rendered = render(self.beszel(subject, body, link), BESZEL_LINK_BASE, FIXED_NOW)
                self.assertNotIn(
                    "url", rendered,
                    "a link from the request body reached the button without validation",
                )
                self.assertNotIn("url_title", rendered)
                self.assertNotIn("href", rendered["message"])

        self.assertNotIn("url", render(self.beszel(subject, body, valid), None, FIXED_NOW))
        for raw in (None, "http://admin:link-secret@nas.tailnet.example:8090/beszel"):
            with self.subTest(base=raw):
                config = self.relay_module.Config.from_mapping(self.environment(BESZEL_LINK_BASE=raw))
                self.assertIsNone(config.beszel_link_base)
                self.assertIn("BESZEL_LINK_BASE", config.beszel_link_problem)
                self.assertNotIn("link-secret", config.beszel_link_problem)

        self.assertEqual(self.post_beszel(self.beszel(subject, body, valid))[0], 204)
        self.assertEqual(self.pushover.requests[-1]["form"]["url"], valid)

    def test_hostile_beszel_input_renders_a_message_pushover_takes(self):
        hostile = ("<b>&'\"\n\U0001f9e8" * 1500)[:10_000]
        line = hostile.replace("\n", " ")
        alerts = [
            {"title": line, "message": hostile},
            {"title": f"{line} CPU above threshold",
             "message": f"{line} averaged 1.00% for the previous 1 minute.\n\n{hostile}"},
            {"title": f"{line} temperature below threshold",
             "message": f"{line} averaged 99.99\u00b0C for the previous 99 minutes."},
            {"title": f"Connection to {line} is down \U0001f534", "message": hostile},
            {"title": f"{line} \u2705", "message": ""},
            {"title": "x", "message": "\n\n\n"},
        ]
        rendered = [
            self.relay_module.render_beszel(alert, BESZEL_LINK_BASE, FIXED_NOW) for alert in alerts
        ]
        self.assertEqual(self.post_beszel({"title": line[:1500], "message": hostile[:3000]})[0], 204)
        rendered.append(self.pushover.requests[-1]["form"])
        for fields in rendered:
            with self.subTest(title=fields["title"][:24]):
                title = fields["title"]
                message = fields["message"]
                self.assertTrue(title)
                self.assertLessEqual(len(title), self.relay_module.MAX_TITLE_CHARACTERS)
                self.assertNotIn("&amp;", title, "a title is plain text on Pushover's side")
                self.assertTrue(message.strip())
                self.assertLessEqual(len(message), self.relay_module.MAX_MESSAGE_CHARACTERS)
                self.assertIsNone(HALF_ENTITY.search(message), message[-40:])
                for tag in ("b", "i", "font", "a"):
                    self.assertEqual(
                        len(re.findall(rf"<{tag}\b", message)), message.count(f"</{tag}>"), tag
                    )


class RelayStateDirectoryTest(unittest.TestCase):
    """The three refusals of open_directory_no_symlinks, and what each owns (#658).

    Its own TestCase with no servers running, because it spies on os.open and
    os.close process-wide.
    """

    def setUp(self):
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary_directory.cleanup)
        self.root = Path(self.temporary_directory.name)
        self.relay_module = load_relay_module()

    def test_a_refused_state_directory_closes_the_descriptor_it_opened(self):
        unsafe = self.root / "unsafe"
        unsafe.mkdir(mode=0o755)

        for label, path, opens in (
            ("relative", Path("relative/state"), False),
            ("absent", self.root / "absent", False),
            ("world-readable", unsafe, True),
        ):
            with self.subTest(label):
                opened, closed = [], []
                real_open, real_close = os.open, os.close

                def spy_open(*arguments, _real=real_open, _seen=opened, **keywords):
                    descriptor = _real(*arguments, **keywords)
                    _seen.append(descriptor)
                    return descriptor

                def spy_close(descriptor, _real=real_close, _seen=closed):
                    _seen.append(descriptor)
                    return _real(descriptor)

                with mock.patch.object(os, "open", spy_open), \
                        mock.patch.object(os, "close", spy_close):
                    with self.assertRaises(self.relay_module.StateError):
                        self.relay_module.open_directory_no_symlinks(path)

                self.assertEqual(bool(opened), opens, f"opened={opened}")
                self.assertEqual(closed, opened, "every descriptor opened must be closed")


class RelayProcessSignalTest(unittest.TestCase):
    """What a deliberate stop does to the relay, run as its own process.

    In the container the relay is PID 1, which has no default SIGTERM disposition,
    so it must install its own and exit zero under it (#516).
    """

    def setUp(self):
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary_directory.cleanup)
        state_directory = Path(self.temporary_directory.name) / "state"
        state_directory.mkdir(mode=0o700)
        self.state_path = state_directory / "alert-relay.json"

    def start_relay(self, **changes):
        """Run services/dozzle/alert_relay.py the way its container does.

        `changes` overrides the environment below; None removes a name.
        """
        port, holder = reserve_local_port()
        self.addCleanup(holder.close)
        environment = dict(os.environ)
        environment.update(
            {
                "ALERT_RELAY_TOKEN": RELAY_TOKEN,
                "ALERT_RELAY_PORT": str(port),
                # Never dialled: a discard address, not api.pushover.net.
                "PUSHOVER_API_URL": "http://127.0.0.1:9/1/messages.json",
                "ALERT_RELAY_LINK_BASE": LINK_BASE,
                "PUSHOVER_TOKEN": PUSHOVER_TOKEN,
                "PUSHOVER_USER_KEY": PUSHOVER_USER_KEY,
                "ALERT_DAILY_CONTAINER_CEILING": str(CONTAINER_CEILING),
                "ALERT_DAILY_OOM_CONTAINER_CEILING": str(OOM_CONTAINER_CEILING),
                "ALERT_DAILY_GLOBAL_CEILING": str(GLOBAL_CEILING),
                "ALERT_STATE_PATH": str(self.state_path),
                "PYTHONDONTWRITEBYTECODE": "1",
            }
        )
        for name, value in changes.items():
            if value is None:
                environment.pop(name, None)
            else:
                environment[name] = value
        # Released on the line before the spawn: the relay is the binder.
        holder.close()
        process = subprocess.Popen(  # noqa: S603 - fixed argv, no shell
            [sys.executable, str(RELAY_PATH)],
            env=environment,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        self.addCleanup(self.reap, process)

        deadline = time.monotonic() + RELAY_START_TIMEOUT_SECONDS
        while time.monotonic() < deadline:
            if process.poll() is not None:
                _out, error = process.communicate()
                self.fail(
                    "the relay exited before it listened, status "
                    f"{process.returncode}: {error.decode(errors='replace')}"
                )
            with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
                probe.settimeout(0.5)
                try:
                    probe.connect(("127.0.0.1", port))
                except OSError:
                    time.sleep(0.05)
                    continue
            return process, port
        self.fail(
            f"the relay did not listen on 127.0.0.1:{port} within "
            f"{RELAY_START_TIMEOUT_SECONDS} seconds"
        )
        return None, None  # unreachable; self.fail raises

    @staticmethod
    def reap(process):
        if process.poll() is None:
            process.kill()
        process.communicate()

    def signalled_exit(self, number, open_connections=0):
        process, port = self.start_relay()
        clients = []
        for _ in range(open_connections):
            client = socket.create_connection(("127.0.0.1", port), timeout=3)
            self.addCleanup(client.close)
            # Cut short, so the worker is mid-read when the signal lands: socketserver
            # swallows a raising handler's exception there.
            client.sendall(b"POST /alerts HT")
            clients.append(client)
        process.send_signal(number)
        try:
            process.communicate(timeout=RELAY_EXIT_TIMEOUT_SECONDS)
        except subprocess.TimeoutExpired:
            self.fail(
                f"the relay was still running {RELAY_EXIT_TIMEOUT_SECONDS} seconds after "
                f"{signal.Signals(number).name}; inside its container Docker would SIGKILL "
                "it here and the `die` rule would page on exit 137, through the relay"
            )
        return process.returncode

    def test_sigterm_shuts_the_relay_down_cleanly(self):
        status = self.signalled_exit(signal.SIGTERM)

        self.assertEqual(
            status,
            0,
            "the relay must install its own SIGTERM disposition and exit zero: a status of "
            f"{status} here is the default disposition, which PID 1 does not have, so in the "
            "container the signal is dropped and the stop ends in a SIGKILL and exit 137",
        )

    def test_sigint_still_shuts_the_relay_down_cleanly(self):
        """SIGINT, which worked before #516, still ends in a clean exit."""
        status = self.signalled_exit(signal.SIGINT)

        self.assertEqual(status, 0, f"SIGINT must still end in a clean exit, got {status}")

    def test_sigterm_lands_cleanly_while_requests_are_in_flight(self):
        """A stop arriving mid-request must not be swallowed by socketserver."""
        status = self.signalled_exit(signal.SIGTERM, open_connections=3)

        self.assertEqual(
            status,
            0,
            "a stop arriving while requests are in flight must still exit zero, got "
            f"{status}",
        )



class RelayLinkBaseProcessTest(unittest.TestCase):
    """A relay whose environment predates the link base still starts and alerts."""

    setUp = RelayProcessSignalTest.setUp
    start_relay = RelayProcessSignalTest.start_relay
    reap = RelayProcessSignalTest.__dict__["reap"]

    def alert_through(self, **changes):
        pushover = ThreadingHTTPServer(("127.0.0.1", 0), RecordingPushoverHandler)
        pushover.requests = []
        pushover.response_status = 200
        pushover.response_body = b""
        thread = threading.Thread(target=pushover.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(DozzleAlertRelayTest.stop_server, pushover, thread)
        process, port = self.start_relay(
            PUSHOVER_API_URL=f"http://127.0.0.1:{pushover.server_port}/1/messages.json",
            **changes,
        )
        body = json.dumps(DozzleAlertRelayTest.envelope(), separators=(",", ":")).encode()
        connection = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
        connection.request(
            "POST", "/alerts", body=body,
            headers={"Authorization": f"Bearer {RELAY_TOKEN}",
                     "Content-Type": "application/json",
                     "Content-Length": str(len(body))},
        )
        status = connection.getresponse().status
        connection.close()
        process.send_signal(signal.SIGTERM)
        _out, error = process.communicate(timeout=RELAY_EXIT_TIMEOUT_SECONDS)
        self.assertEqual(status, 204, "the relay did not accept the alert")
        self.assertEqual(len(pushover.requests), 1, "the relay did not publish the alert")
        return pushover.requests[0]["form"], error.decode(errors="replace")

    def link_problem_lines(self, stderr):
        return [line for line in stderr.splitlines() if "ALERT_RELAY_LINK_BASE" in line]

    def test_a_relay_without_a_link_base_starts_and_alerts_without_a_link(self):
        form, stderr = self.alert_through(ALERT_RELAY_LINK_BASE=None)
        self.assertNotIn("url", form)
        self.assertNotIn("url_title", form)
        self.assertEqual(form["timestamp"], "1786756933")
        self.assertEqual(
            self.link_problem_lines(stderr),
            ["alert-relay: ALERT_RELAY_LINK_BASE is not set; alerts will carry no Dozzle link"],
        )

    def test_a_relay_with_an_invalid_link_base_starts_and_says_so_once(self):
        form, stderr = self.alert_through(
            ALERT_RELAY_LINK_BASE="http://admin:link-secret@nas.tailnet.example:8080/dozzle"
        )
        self.assertNotIn("url", form)
        self.assertNotIn("url_title", form)
        self.assertEqual(form["timestamp"], "1786756933")
        lines = self.link_problem_lines(stderr)
        self.assertEqual(len(lines), 1, stderr)
        self.assertTrue(lines[0].startswith("alert-relay: ALERT_RELAY_LINK_BASE must be"))
        for secret in ("link-secret", RELAY_TOKEN, PUSHOVER_TOKEN, PUSHOVER_USER_KEY):
            self.assertNotIn(secret, stderr)

    def test_a_relay_with_a_valid_link_base_links_and_says_nothing(self):
        form, stderr = self.alert_through()
        self.assertEqual(form["url"], f"{LINK_BASE}/container/{CONTAINER_ID}")
        self.assertEqual(form["url_title"], "Open in Dozzle")
        self.assertEqual(self.link_problem_lines(stderr), [])

class RelayPreviousEnvironmentProcessTest(unittest.TestCase):
    """This relay, started with exactly the environment main renders today.

    `current` is repointed before roles/dozzle re-renders the environment, so the
    relay must start without PUSHOVER_ALERTS_TOKEN or BESZEL_LINK_BASE (#327).
    """

    setUp = RelayProcessSignalTest.setUp
    start_relay = RelayProcessSignalTest.start_relay
    reap = RelayProcessSignalTest.__dict__["reap"]

    @staticmethod
    def post(port, path, payload):
        body = json.dumps(payload, separators=(",", ":")).encode()
        connection = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
        connection.request(
            "POST", path, body=body,
            headers={"Authorization": f"Bearer {RELAY_TOKEN}",
                     "Content-Type": "application/json",
                     "Content-Length": str(len(body))},
        )
        status = connection.getresponse().status
        connection.close()
        return status

    def test_the_previous_environment_serves_alerts_and_refuses_beszel(self):
        pushover = ThreadingHTTPServer(("127.0.0.1", 0), RecordingPushoverHandler)
        pushover.requests = []
        pushover.response_status = 200
        pushover.response_body = b""
        thread = threading.Thread(target=pushover.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(DozzleAlertRelayTest.stop_server, pushover, thread)
        process, port = self.start_relay(
            PUSHOVER_API_URL=f"http://127.0.0.1:{pushover.server_port}/1/messages.json",
            PUSHOVER_ALERTS_TOKEN=None,
            BESZEL_LINK_BASE=None,
        )
        statuses = [
            self.post(port, "/alerts", DozzleAlertRelayTest.envelope()),
            self.post(port, "/beszel", DozzleAlertRelayTest.beszel(
                "Test Alert", "This is a notification from Beszel.")),
            self.post(port, "/alerts", DozzleAlertRelayTest.envelope("Unexpected exit")),
        ]
        alive = process.poll() is None
        process.send_signal(signal.SIGTERM)
        _out, error = process.communicate(timeout=RELAY_EXIT_TIMEOUT_SECONDS)
        stderr = error.decode(errors="replace")

        self.assertTrue(alive, f"the relay died serving the previous environment: {stderr}")
        self.assertEqual(statuses, [204, 503, 204])
        self.assertEqual(process.returncode, 0)
        self.assertEqual(
            [request["form"]["token"] for request in pushover.requests],
            [PUSHOVER_TOKEN, PUSHOVER_TOKEN],
        )
        self.assertEqual(
            [line for line in stderr.splitlines() if "PUSHOVER_ALERTS_TOKEN" in line],
            ["alert-relay: PUSHOVER_ALERTS_TOKEN is not set; a Beszel alert was not delivered"],
        )


if __name__ == "__main__":
    unittest.main()
