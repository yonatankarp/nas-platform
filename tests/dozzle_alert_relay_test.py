#!/usr/bin/env python3
"""Behavior and security tests for the private Dozzle alert relay."""

from __future__ import annotations

import ast
import contextlib
from datetime import datetime, timezone
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
# Dozzle's address as roles/dozzle renders it, which the relay turns into a
# tap-through link. A name rather than 127.0.0.1 so a relay that substituted its
# own host would be visible.
LINK_BASE = "http://nas.tailnet.example:8080"
# The ceilings these cases run against. Deliberately not the deployment's
# 10/25/200: a case that trips a ceiling has to publish one message per unit of
# allowance first, and a relay that ignored its configuration and kept a literal
# would still pass at whatever numbers the role happens to declare today.
CONTAINER_CEILING = 3
OOM_CONTAINER_CEILING = 5
GLOBAL_CEILING = 9
# The listener port the deployment declares today, in roles/dozzle/defaults.
# Nothing here depends on the number staying current: these tests only need a
# port that differs from any literal the relay itself could have kept, so a
# stale value would still select a usable one.
DEPLOYED_PORT = 8081
# How long the process-level signal cases below wait for the relay to begin
# listening, and for it to exit once signalled. Both are environment inputs
# because a hardcoded wait is how this repository's gate keeps acquiring a
# floor it cannot parallelise away (#319, #485): a case that waits is a worker
# slot held without CPU. The defaults are generous against what the operation
# costs -- the relay listens in well under a second on a cold interpreter -- and
# the exit budget is Docker's own stop grace period, because a relay that needed
# longer than that in the container would be SIGKILLed rather than waited for.
RELAY_START_TIMEOUT_SECONDS = float(
    os.environ.get("PLATFORM_RELAY_START_TIMEOUT_SECONDS", "20")
)
RELAY_EXIT_TIMEOUT_SECONDS = float(
    os.environ.get("PLATFORM_RELAY_EXIT_TIMEOUT_SECONDS", "10")
)


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


class RecordingPushoverHandler(BaseHTTPRequestHandler):
    """Stands in for api.pushover.net and records the form it was POSTed.

    The whole request is captured, not only the fields a case looks at: the
    Authorization header disappeared with the ntfy transport because Pushover
    authenticates by form field, and a case that only read the fields it cared
    about could not say that a header carrying a credential had come back.
    """

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
                # Every Pushover field is single-valued; a repeated key would be
                # a defect rather than something to merge silently, so it is
                # kept visible as a list of what arrived.
                "form": {
                    key: values[0] if len(values) == 1 else values
                    for key, values in parsed.items()
                },
            }
        )
        # A rejection carries a body, because Pushover's `errors` array is the
        # half that says WHICH rejection it is -- and because a stand-in that
        # only ever answers empty cannot exercise what the relay does with the
        # far end's text.
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
    """A stderr that counts write() CALLS, not just the text they produced.

    The point of the count. `print(x, file=sys.stderr)` issues two writes -- the
    text, then the terminator -- and under socketserver's threading two
    concurrent failures can interleave into a merged line. Asserting only on the
    joined text would catch that non-deterministically at best, because whether
    two threads actually interleave is a scheduling accident. Counting calls
    catches it every time: one line must be one write.

    list.append is atomic under the GIL, so this records faithfully from the
    request threads without a lock of its own perturbing what it measures.
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
        moment = now or datetime.now(timezone.utc)
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

        Docker's own `oom` event is cgroup-scoped, so a host-level kill can only
        be seen here. The three codes beside it are deliberate stops: a graceful
        shutdown exits 143 under the grace periods the services declare, and a
        suppression list emptied by accident has to fail rather than go quiet.
        """
        status_code, body = self.post(
            self.envelope("Unexpected exit", container="jellyfin", exitCode="137")
        )

        self.assertEqual((status_code, body), (204, b""))
        published = self.pushover.requests[-1]["form"]
        self.assertEqual(published["priority"], "1")
        self.assertEqual(published["title"], "Unexpected exit · jellyfin")
        self.assertEqual(
            published["message"],
            "<b>Host:</b> nas\n<b>Container:</b> jellyfin\n<b>Exit code:</b> 137",
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
        # Two accepted OOMs have now charged the ceiling, so the state file
        # exists. What a rejected timestamp must not do is move it -- the whole
        # document is captured rather than only its absence, which is what the
        # assertion below meant before the ceiling gave this file a reason to
        # exist after an OOM.
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
                    # The path is part of the endpoint rather than a root the
                    # relay appends a topic to, which is the transport change in
                    # one line.
                    "path": "/1/messages.json",
                    # Pushover authenticates by form field. A Bearer header here
                    # would mean the relay had carried the ntfy shape across and
                    # was leaking a credential into a header nothing reads.
                    "authorization": None,
                    "content_type": "application/x-www-form-urlencoded",
                    "form": {
                        "token": PUSHOVER_TOKEN,
                        "user": PUSHOVER_USER_KEY,
                        "title": "Unhealthy · paperless_webserver",
                        "message": "<b>Host:</b> nas\n"
                                   "<b>Container:</b> paperless_webserver\n"
                                   "<b>Status:</b> unhealthy",
                        "html": "1",
                        "priority": "1",
                        # The container's own page in Dozzle, by the short id
                        # the page's store is keyed on, and the moment Docker
                        # reported the event (2026-08-15T01:22:13Z) as Unix
                        # seconds, which is the form Pushover reads.
                        "url": f"{LINK_BASE}/container/{CONTAINER_ID}",
                        "url_title": "Open in Dozzle",
                        "timestamp": "1786756933",
                    },
                }
            ],
        )

    def test_all_rule_renderings_are_human_readable_and_fixed(self):
        cases = [
            (
                "Unexpected exit",
                "Unexpected exit · service",
                "<b>Host:</b> nas\n<b>Container:</b> service\n<b>Exit code:</b> 23",
                "1",
                {"container": "service", "exitCode": "23"},
            ),
            (
                "OOM",
                "Out of memory · service",
                "<b>Host:</b> nas\n<b>Container:</b> service\n"
                "<b>Status:</b> out of memory",
                "2",
                {"container": "service"},
            ),
            (
                "Recovery",
                "Recovered · service",
                "<b>Host:</b> nas\n<b>Container:</b> service\n<b>Status:</b> healthy",
                "-1",
                {"container": "service", "containerId": "b" * 64},
            ),
        ]
        for rule, title, message, priority, changes in cases:
            with self.subTest(rule=rule):
                if rule == "Recovery":
                    # A recovery only publishes when it closes an unhealthy
                    # entry, so the transition has to exist before it.
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
                self.assertEqual(published["message"], message)
                self.assertEqual(published["priority"], priority)
                self.assertEqual(published["html"], "1")

    def test_emergency_priority_carries_the_parameters_pushover_requires(self):
        """Priority 2 without retry and expire is refused by Pushover outright.

        This is the acknowledge semantic the migration was made for, so it is
        asserted on the wire rather than in the renderer: a message that reached
        the API at priority 2 with either parameter missing would be rejected
        and the out-of-memory alert simply lost.
        """
        self.assertEqual(self.post(self.envelope("OOM"))[0], 204)
        emergency = self.pushover.requests[-1]["form"]
        self.assertEqual(emergency["priority"], "2")
        self.assertEqual(emergency["retry"], "60")
        self.assertEqual(emergency["expire"], "3600")
        # Interior to Pushover's documented bounds rather than at them, so the
        # message is accepted whatever the exact limits are today.
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
                # Only an emergency carries them; a retry on a non-emergency is
                # accepted by the API and silently means nothing.
                self.assertNotIn("retry", ordinary)
                self.assertNotIn("expire", ordinary)

    def test_the_documented_escalation_window_is_the_one_that_happens(self):
        """The third bound, which is neither of the two the case above checks.

        Pushover stops an emergency at 50 retries whatever `expire` says, and
        its own worked example is retry=30 with expire=10800 escalating for 25
        minutes rather than three hours. The relay's comment used to explain its
        choice with arithmetic that ignored the cap -- "an hour of re-alerting
        once a minute is already sixty alerts" -- which the API simply does not
        do.

        Asserted on the CONSTANTS rather than on the wire, and that is the whole
        reason this is its own case. Placed inside the case above it sat behind
        `assertEqual(retry, "60")`, so every plant that could have made it fail
        tripped the literal first and it could never fire -- a check that cannot
        fail, which is what this file keeps finding. Here a change to either
        constant reaches it.
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
        # And still inside what the API accepts, which the cap says nothing
        # about: a retry below 30 or an expire above 10800 is a refused message
        # and a lost out-of-memory alert.
        self.assertGreaterEqual(relay.EMERGENCY_RETRY_SECONDS, 30)
        self.assertLessEqual(relay.EMERGENCY_EXPIRE_SECONDS, 10800)

    def test_every_problem_rule_outranks_a_recovery(self):
        """Only a recovery is quiet; a problem must never be downgraded.

        This is what replaced the two-topic split: the Recovery rule used to be
        routed to nas-containers so it could be muted on its own, and Pushover
        says the same thing on the message itself with a negative priority.
        """
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
            # Credentials travel in the form body; a URL carrying its own is a
            # hand-edited endpoint rather than a configured one.
            ("userinfo", "https://user:pass@api.pushover.net/1/messages.json"),
            ("query", "https://api.pushover.net/1/messages.json?token=leak"),
            ("fragment", "https://api.pushover.net/1/messages.json#x"),
            # A bare root is the ntfy shape, and POSTing a Pushover form at it
            # would be a silent misconfiguration rather than a refusal.
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

        A url over Pushover's 512 characters is a 4xx and a lost alert, so the
        bound lives here at start-up rather than as a cut at render time: the
        longest base accepted plus the route and the longest id the envelope
        admits must still fit. What an unusable base costs is the link: the
        relay script arrives through the `current` symlink before roles/dozzle
        re-renders this environment, so a relay restarted in between meets an
        environment without the setting, and refusing to start there would lose
        every container alert (see Config).
        """
        relay = self.relay_module
        configured = relay.Config.from_mapping(self.environment())
        self.assertEqual(configured.alert_relay_link_base, LINK_BASE)
        self.assertIsNone(configured.alert_relay_link_problem)
        # A trailing slash is the same origin, not a path, and must not double up.
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
                # Everything else in the configuration is untouched.
                self.assertEqual(degraded.pushover_api_url, configured.pushover_api_url)

        with self.assertRaises(relay.ConfigurationError):
            relay.validated_link_base("http://nas.tailnet.example:8080/dozzle")

    def test_the_role_default_renders_a_link_base_the_relay_accepts(self):
        """The gate half of tolerating a bad base: the role must not ship one.

        A relay without a valid base still alerts, so a broken role default
        would degrade on the NAS silently. This renders the default the way
        Ansible would for the two host shapes platform_public_host takes -- the
        Mac inventory's loopback address and a MagicDNS name -- and holds it to
        the relay's own validator.
        """
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

        `url_title` has a cap of its own, 100, and `timestamp` is Unix seconds,
        so an ISO string or a negative number is a refused message. The
        envelope admits a timestamp before 1970 and Docker never sends one; it
        is left off rather than sent for Pushover to refuse.
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

        The order matters rather than being tidiness. An OOM allowance below the
        ordinary one inverts the whole point of having a second threshold, and a
        global backstop below a per-container allowance makes the per-container
        ceiling unreachable -- so it would never be observed to work or to fail.
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

    def test_config_requires_a_usable_listener_port(self):
        base = self.environment()
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

        environment = self.environment(ALERT_RELAY_PORT=str(port))
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
        self.assertEqual(len(self.pushover.requests), 0)
        # A first healthy transition publishes nothing, so it charges nothing:
        # the ceiling is charged only once the transition logic has decided the
        # event is worth sending.
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
                "title": "Recovered · immich_server",
                "message": "<b>Host:</b> nas\n<b>Container:</b> immich_server\n"
                           "<b>Status:</b> healthy",
                "html": "1",
                # A recovery is a record, not an emergency: a badge and no
                # sound, which is what the second ntfy topic used to express.
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
        # The suppressed duplicate charged nothing either.
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
                # A migrated document carries today's empty budget: a schema
                # that could not hold a count cannot be read as having spent
                # one, so the first day after an upgrade starts whole.
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

    # --- the daily ceiling -------------------------------------------------
    #
    # Every case below runs against CONTAINER_CEILING / OOM_CONTAINER_CEILING /
    # GLOBAL_CEILING rather than the deployment's numbers, so a relay that
    # ignored its configuration fails here rather than passing by coincidence.

    def test_under_the_ceiling_every_alert_publishes_and_is_counted(self):
        """The passing path, asserted on purpose.

        A ceiling is easy to get right in the direction that suppresses and easy
        to get catastrophically wrong in the direction that does not publish,
        and a suite that only exercises the tripping path cannot tell a working
        ceiling from a relay that has gone silent.
        """
        for index in range(CONTAINER_CEILING):
            with self.subTest(index=index):
                self.assertEqual(self.post(self.envelope("Unexpected exit"))[0], 204)
                self.assertEqual(len(self.pushover.requests), index + 1)
                self.assertEqual(
                    self.read_state()["budget"],
                    self.budget(index + 1, [(CONTAINER_ID, index + 1, False)]),
                )
        titles = {form["title"] for form in self.published_forms()}
        self.assertEqual(titles, {"Unexpected exit · paperless_webserver"})
        self.assertNotIn(
            "Alerts suppressed",
            "".join(form["title"] for form in self.published_forms()),
        )

    def test_the_container_ceiling_trips_at_its_boundary_and_notices_once(self):
        for _index in range(CONTAINER_CEILING):
            self.assertEqual(self.post(self.envelope("Unexpected exit"))[0], 204)
        self.assertEqual(len(self.pushover.requests), CONTAINER_CEILING)

        # One past the allowance: the notice, and nothing else.
        self.assertEqual(self.post(self.envelope("Unexpected exit"))[0], 204)
        notice = self.pushover.requests[-1]["form"]
        self.assertEqual(notice["title"], "Alerts suppressed · paperless_webserver")
        self.assertIn("<b>Suppressed:</b> paperless_webserver", notice["message"])
        self.assertIn(f"{CONTAINER_CEILING} alerts already sent", notice["message"])
        # The notice says the platform has gone quiet, which outranks any single
        # alert it replaced -- but there is nothing to acknowledge, so never 2.
        self.assertEqual(notice["priority"], "1")

        # And then silence, for this container, however many more arrive.
        for _index in range(5):
            self.assertEqual(self.post(self.envelope("Unexpected exit"))[0], 204)
        self.assertEqual(len(self.pushover.requests), CONTAINER_CEILING + 1)
        suppressed = [
            form for form in self.published_forms()
            if form["title"].startswith("Alerts suppressed")
        ]
        self.assertEqual(len(suppressed), 1)
        # The notice itself is not charged: the allowance is already spent, and
        # charging it would make the latch depend on the counter it sets.
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
            "Unexpected exit · immich_server",
        )

    def test_an_oom_outlives_the_ordinary_allowance_and_is_still_bounded(self):
        """OOM is not exempt, and the crash loop is why.

        A container the kernel kills and Docker restarts emits an unbounded
        `oom` stream, so a fully exempt rule would hand that stream the quota. A
        higher allowance rather than no allowance is what lets a container whose
        ordinary alerts are suppressed still report that it was killed.
        """
        for _index in range(CONTAINER_CEILING):
            self.assertEqual(self.post(self.envelope("Unexpected exit"))[0], 204)
        self.assertEqual(len(self.pushover.requests), CONTAINER_CEILING)

        # The ordinary ceiling is spent; an OOM still gets through, at its own
        # higher allowance and at emergency priority.
        for index in range(OOM_CONTAINER_CEILING - CONTAINER_CEILING):
            with self.subTest(index=index):
                self.assertEqual(self.post(self.envelope("OOM"))[0], 204)
                self.assertEqual(self.pushover.requests[-1]["form"]["priority"], "2")
        self.assertEqual(len(self.pushover.requests), OOM_CONTAINER_CEILING)

        # An ordinary alert in between is still suppressed, and its notice is
        # the container's one notice.
        self.assertEqual(self.post(self.envelope("Unexpected exit"))[0], 204)
        self.assertTrue(
            self.pushover.requests[-1]["form"]["title"].startswith("Alerts suppressed")
        )

        # And the OOM allowance ends too, rather than running forever.
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

        # A container that has never alerted before is silenced too: the global
        # count is checked before any per-container allowance.
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
        self.assertEqual(notice["title"], "Alerts suppressed · ceiling reached")
        self.assertIn("<b>Suppressed:</b> every container", notice["message"])
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
                    if form["title"].startswith("Alerts suppressed")
                ]
            ),
            1,
            "one global notice per day, and one only",
        )
        # Once the global backstop has tripped, no per-container notice is ever
        # emitted on top of it -- which is what bounds the unbudgeted notices.
        self.assertTrue(self.read_state()["budget"]["notified"])

        # An OOM is bounded by the global backstop too. It is the one message
        # this relay most wants to deliver, and it is still not a way past the
        # quota; the notice above is what says so out loud.
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
            "Unexpected exit · paperless_webserver",
        )
        self.assertEqual(
            self.read_state()["budget"],
            self.budget(1, [(CONTAINER_ID, 1, False)], day="2026-08-16"),
        )

    def test_a_clock_that_moves_backwards_cannot_wedge_the_relay_shut(self):
        """The failure a rolling window has and a calendar day key does not.

        A window stored as "started at T" and reset on `now - T >= one day` goes
        negative when the clock jumps backwards and then never resets at all:
        the relay would sit suppressed until somebody noticed the silence. A day
        key has no arithmetic to invert -- any day that is not the stored one
        resets -- so this case moves the clock the wrong way on purpose.
        """
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
            "Unexpected exit · paperless_webserver",
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
            # The count survives the restart, so the boundary is still where it
            # was: one more publishes, the next is the notice.
            self.assertEqual(self.post(self.envelope("Unexpected exit"))[0], 204)
            self.assertEqual(len(self.pushover.requests), CONTAINER_CEILING)
            self.assertEqual(
                self.pushover.requests[-1]["form"]["title"],
                "Unexpected exit · paperless_webserver",
            )
            self.assertEqual(self.post(self.envelope("Unexpected exit"))[0], 204)
            self.assertTrue(
                self.pushover.requests[-1]["form"]["title"].startswith(
                    "Alerts suppressed"
                )
            )
            # The latch survives too: a restart must not buy a second notice.
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
                    if form["title"].startswith("Alerts suppressed")
                ]
            ),
            1,
        )

    def test_the_ceiling_survives_a_state_store_that_cannot_be_written(self):
        """The defect that made the ceiling fail completely open.

        The bound lived only in the state file, so a write that failed took the
        increment with it: the next event re-read an unchanged document, saw the
        same count, and published again. Measured on the broken tree at
        10/25/200 with the write always failing, 500 events produced 500 alerts
        and no notice. The notice latch was worse -- nothing backed it at all,
        so ten over-ceiling events produced ten notices.

        `/state` filling or remounting read-only is the same class of event this
        relay exists to report, so this was reachable, and silent in the
        direction that matters.

        Failing closed is NOT the fix and this case would not accept it: a relay
        that stops publishing when its disk fills is silent at the one moment
        somebody needs to hear from it. The bound degrades from durable to
        process-lifetime instead, which is what the assertions below pin.
        """
        with mock.patch.object(
            self.relay_module.LockedState, "replace",
            side_effect=self.relay_module.StateError("state replacement failed"),
        ):
            statuses = []
            for _index in range(CONTAINER_CEILING + 12):
                statuses.append(self.post(self.envelope("Unexpected exit"))[0])

        # Every write failed, so every request reports the store as unavailable
        # -- the alert was delivered, so that status is about the store.
        self.assertEqual(set(statuses), {500})
        # And nothing was persisted, which is what makes this the hard case.
        self.assertFalse(self.state_path.exists())

        titles = [form["title"] for form in self.published_forms()]
        alerts = [t for t in titles if t.startswith("Unexpected exit")]
        notices = [t for t in titles if t.startswith("Alerts suppressed")]
        self.assertEqual(
            len(alerts), CONTAINER_CEILING,
            f"the ceiling failed open across a broken store: {len(alerts)} alerts",
        )
        self.assertEqual(
            len(notices), 1,
            f"the notice latch failed open across a broken store: {len(notices)} notices",
        )

    def test_the_global_ceiling_and_its_latch_survive_a_broken_store_too(self):
        """The other scope, which the per-container case cannot reach.

        With a per-container ceiling of 3 and a global of 9, the case above
        never gets near the global backstop -- it spends its events on one
        container. The global count and the global notice latch are separate
        fields with a separate merge, so they need their own broken-store case
        or half the floor is asserted by nothing. Planted: dropping the global
        latch from the merge left the per-container case green.
        """
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
        alerts = [t for t in titles if t.startswith("Unexpected exit")]
        notices = [t for t in titles if t == "Alerts suppressed · ceiling reached"]
        self.assertEqual(
            len(alerts), GLOBAL_CEILING,
            f"the global backstop failed open across a broken store: {len(alerts)}",
        )
        self.assertEqual(
            len(notices), 1,
            f"the global notice latch failed open across a broken store: {len(notices)}",
        )

    def test_the_whole_ceiling_decision_happens_inside_the_state_lock(self):
        """The interlock, pinned structurally because a comment cannot hold it.

        The ceiling is a check-then-act -- raise_floor reads, charge_budget
        decides, record and replace write -- with the publish those authorise in
        between. BudgetFloor's own lock covers only its dict and spans none of
        that, so the exclusive flock is what stops two concurrent events each
        seeing the same remaining allowance. Measured with the window widened to
        50ms: with the flock a ceiling of 10 delivered 10; with the flock gone
        and BudgetFloor untouched, the same ceiling delivered 40.

        The trap this closes is that moving `publish` out of the lock is the
        obvious fix for a hung upstream serialising every Dozzle POST, and it
        breaches the ceiling with BudgetFloor still there and still looking like
        protection. Read as source structure rather than behaviour because a
        concurrency test for this would be a race against a 10-second timeout;
        this cannot flake and it fails the moment somebody takes the trap.
        """
        tree = ast.parse(RELAY_PATH.read_text(encoding="utf-8"))
        function = next(
            node for node in tree.body
            if isinstance(node, ast.FunctionDef) and node.name == "process_event"
        )
        locked = [node for node in function.body if isinstance(node, ast.With)]
        self.assertEqual(
            len(locked), 1, "process_event must hold exactly one state lock"
        )
        self.assertTrue(
            any(
                isinstance(item.context_expr, ast.Call)
                and getattr(item.context_expr.func, "id", None) == "LockedState"
                for item in locked[0].items
            ),
            "the one with-block in process_event must be the state lock",
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

        # And nothing that matters may sit outside it: the only calls in the
        # function body proper are the lock itself and the clock it is entered
        # with, so a later edit cannot quietly hoist one of the five out.
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
        """The floor corrects the store upwards, never downwards.

        A document that lost an increment -- the write failed, or something
        rewrote it -- must not hand this process the same allowance again. The
        state file is rolled back by hand here, which is the same input a lost
        write produces.
        """
        for _index in range(CONTAINER_CEILING):
            self.assertEqual(self.post(self.envelope("Unexpected exit"))[0], 204)
        self.assertEqual(len(self.pushover.requests), CONTAINER_CEILING)

        # Wind the persisted counters back to zero behind the relay's back.
        self.write_state(
            {"version": 3, "entries": [], "budget": self.budget()}
        )
        self.assertEqual(self.post(self.envelope("Unexpected exit"))[0], 204)
        self.assertTrue(
            self.pushover.requests[-1]["form"]["title"].startswith("Alerts suppressed"),
            "a rewound store handed the process its allowance a second time",
        )
        # And the correction is written back, so the next reader sees it too.
        self.assertEqual(
            self.read_state()["budget"],
            self.budget(CONTAINER_CEILING, [(CONTAINER_ID, CONTAINER_CEILING, True)]),
        )

    def test_a_store_that_is_ahead_of_this_process_is_left_alone(self):
        """The floor raises, so a larger stored count has to win.

        Merging the other way -- trusting whichever value this process last saw
        -- would let a relay that restarted mid-day undo a count written before
        it started.
        """
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
            self.pushover.requests[-1]["form"]["title"].startswith("Alerts suppressed")
        )
        self.assertEqual(len(self.pushover.requests), 1)

    def test_a_rejected_alert_says_so_on_stderr_with_its_status(self):
        """The path that was silent, and it is the worst-consequence one.

        Nothing in the relay logged anything -- no logging import, no print, no
        stderr, `log_message` a no-op, and /healthz reporting only on the state
        store -- so a rejected alert was answered with 502, not retried by
        Dozzle, and gone. Against a local ntfy a 4xx was barely reachable;
        against Pushover it is reachable through the 250 and 1024 caps, the
        priority-2 parameters, and credentials that were revoked or mistyped.
        """
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
        # Which alert was lost, which is the operator's first question.
        self.assertIn("alert=Unhealthy · paperless_webserver", line)
        # And the far end's own explanation, which separates a bad credential
        # from an over-long message from a missing retry parameter.
        self.assertIn("user key is not valid", line)

    def test_an_unreachable_upstream_is_distinguishable_from_a_rejection(self):
        """Collapsing the two was half the defect.

        A rejection never heals and an outage does, so an operator seeing one
        line needs to know which they have. Before this both raised
        `UpstreamError("upstream unavailable")` byte for byte.
        """
        self.config.pushover_api_url = "http://127.0.0.1:1/1/messages.json"
        recorder = RecordingStderr()
        with contextlib.redirect_stderr(recorder):
            status, body = self.post(self.envelope())
        self.assertEqual((status, body), (502, b"upstream unavailable\n"))

        self.assertEqual(len(recorder.writes), 1)
        line = recorder.writes[0]
        self.assertIn("alert-relay: pushover unreachable (", line)
        self.assertIn("alert=Unhealthy · paperless_webserver", line)
        # No HTTP status, because there was no HTTP response. A line claiming
        # one would be the collapse this case exists to prevent, wearing the
        # other name.
        self.assertNotIn("HTTP ", line)
        self.assertNotIn("rejected", line)

    def test_no_credential_reaches_stderr_even_if_the_upstream_echoes_one(self):
        """The assertion that has to survive the far end misbehaving.

        The credentials travel in the request body, so the exception text is
        clean today -- but "clean today" is exactly what stops being true, and a
        far end that echoed a token into its error message would put it in a log
        Dozzle renders to anybody who can read it.
        """
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
        """Redact before truncating, proved on the helper at the boundary.

        Truncating first leaves the leading half of a credential in the log, and
        half a credential is still a leak. Bounded to a length that would cut
        this one in the middle, so the ordering is what the assertion turns on.
        """
        bound = self.relay_module.MAX_DIAGNOSTIC_CHARACTERS
        padded = "x" * (bound - 10) + PUSHOVER_TOKEN
        safe = self.relay_module.log_safe(padded, self.config)
        self.assertLessEqual(len(safe), bound)

        # The fragment is DERIVED rather than guessed, and that is the whole
        # assertion. Truncating first leaves exactly the credential's first
        # `bound - (len(padded) - len(token))` characters, and an earlier
        # version of this case asserted a 12-character prefix when only 10
        # survive -- so it passed with the redaction deleted. Planted and
        # measured, not reasoned.
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
        # The forged text may appear, but only inside the one real line, never
        # as an entry of its own.
        self.assertEqual(len(line.splitlines()), 1)

        # The same sanitiser on the field the platform does not author either.
        self.assertEqual(
            self.relay_module.log_safe("svc\nforged", self.config), "svc?forged"
        )

    def test_concurrent_failures_produce_one_intact_line_each(self):
        """A log that garbles under concurrency is worse than no log.

        It gets read as evidence of something it did not say. The line is
        assembled whole and written ONCE for that reason: print() issues two
        writes -- the text, then the terminator -- and two of those can
        interleave into a merged line.

        DRIVEN AT `publish` RATHER THAN THROUGH THE RELAY, for two reasons, and
        the first is a correction worth stating. Inside process_event every
        publish happens under the exclusive flock, so two failures CANNOT
        currently interleave -- a version of this case that posted twelve
        requests was serialising them behind that lock and proving nothing about
        concurrent writers. The single write is therefore defensive rather than
        load-bearing today: it holds if the publish ever moves out from under
        the lock, and against anything else in the process that writes to
        stderr. Second, the HTTP path carries a pre-existing ~1-in-180
        StateError under twelve-way concurrency -- present unchanged on this
        branch's base -- which made the case flaky for a reason that has nothing
        to do with what it asserts.

        Asserted on the WRITE COUNT, not only on the text: whether two threads
        actually interleave is a scheduling accident, so a text-only assertion
        would catch a two-write implementation only sometimes. One line is one
        write, always.
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
                self.relay_module.publish(self.config, notification)
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
        # Every alert is named exactly once, so nothing was lost or merged.
        self.assertEqual(
            sorted(
                line.split("alert=")[1].split(" detail=")[0]
                for line in recorder.getvalue().splitlines()
            ),
            sorted(f"Unhealthy · service-{index}" for index in range(failures)),
        )

    def test_a_refused_publish_does_not_consume_the_allowance(self):
        """Publish first, persist second, and this is what that order buys.

        Charging before the POST would let an upstream that is refusing eat the
        whole daily allowance while delivering nothing, and the relay would then
        be suppressed for the rest of the day for messages nobody received.
        """
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
            "Unexpected exit · paperless_webserver",
        )

    def test_budget_counters_cannot_crowd_out_unevictable_health_entries(self):
        """The wedge the budget is a separate structure to DEFER.

        bounded_state may only evict a health entry once it is healthy, so a
        document full of unhealthy entries has nothing left to shed and raises
        -- which stops the relay reporting anything at all. A counter may always
        be evicted, because the global count beneath the per-container ones is
        what actually guarantees the quota, so the bytes are reclaimed there
        first. This plants a document that is only reconcilable if that ordering
        holds.

        Deferred rather than prevented, and the earlier version of this comment
        claimed prevention. Shedding counters buys back the counters' bytes and
        nothing else, so an all-unhealthy document still reaches that raise at
        the same size it would with no counters at all -- measured at 128
        entries for a short ASCII host, where the entry count binds first, and
        39 for a 256-character non-ASCII one. That raise is byte-identical to
        the one on the branch base and is not something the counters introduced.
        """
        # 85 of each is the largest pair of lists that still fits inside
        # MAX_STATE_BYTES at the longest host name the envelope schema allows:
        # the stored document is 65208 bytes and one more counter takes it to
        # 65577, past the 65536 bound. Adding the counter is what the event
        # below does, so the shrink is reached rather than merely possible.
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

        # Health entries that cannot be evicted, plus counters that can: the
        # relay must shed counters and keep reporting.
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
        """Lowest count first, so a container at its ceiling keeps its latch.

        Evicting oldest-first, or arbitrarily, would hand a suppressed container
        a fresh allowance and a second notice -- the counter that is actually
        holding something back is the one that must survive.
        """
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
            datetime.now(timezone.utc),
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
            datetime.now(timezone.utc),
        )
        self.assertEqual(len(budget["containers"]), self.relay_module.MAX_BUDGET_ENTRIES)
        # The count-9 latch is still there; five count-1 counters went instead.
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
        """An upgrade meets a file on the NAS that has no budget in it.

        A relay that refused it would report nothing at all, which is worse than
        anything the ceiling protects against, so v2 migrates the way v1 already
        did and starts today whole.
        """
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
        """Neither rule is a health transition, so neither writes a health entry.

        The ceiling gave this file a second thing to hold, so the assertion that
        used to be "no state file at all" is now "no health entries": an exit or
        an OOM that started tracking health would suppress the next one, which is
        what this case has always been about.
        """
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
        # Nothing is written, so the refused publish did not consume any of the
        # day's allowance either.
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
        """Container and host text is attacker-adjacent and lands inside markup.

        Pushover parses `message` under html=1 as five tags -- <b>, <i>, <u>,
        <font color> and <a href> -- so a container named `<b>` would style the
        notification and one carrying an `<a href>` would put a link in it. The
        relay emits only <b> of those five, which is its own narrowness rather
        than the API's. `title` is not parsed, and stays raw on purpose:
        escaping it would show `&amp;` to somebody reading a notification title.
        """
        hostile = '<b>svc</b> & "q" <a href=\'x\'>'
        payload = self.envelope(container=hostile, host="nas<host>")
        captured = io.StringIO()
        with contextlib.redirect_stderr(captured):
            status_code, response_body = self.post(payload)
            wrong_status, wrong_body = self.post(payload, token="request-secret")
        self.assertEqual(status_code, 204)
        self.assertEqual(wrong_status, 401)
        published = self.pushover.requests[0]["form"]
        self.assertEqual(published["title"], f"Unhealthy · {hostile}")
        self.assertEqual(
            published["message"],
            "<b>Host:</b> nas&lt;host&gt;\n"
            "<b>Container:</b> &lt;b&gt;svc&lt;/b&gt; &amp; &quot;q&quot; "
            "&lt;a href=&#x27;x&#x27;&gt;\n"
            "<b>Status:</b> unhealthy",
        )
        # The only markup left in the message is the relay's own three labels,
        # so every `<` in it opens a <b> or a </b> and none of them came from
        # the container's name.
        self.assertEqual(published["message"].count("<b>"), 3)
        self.assertEqual(published["message"].count("</b>"), 3)
        self.assertEqual(published["message"].count("<"), 6)
        combined = captured.getvalue() + response_body.decode() + wrong_body.decode()
        for secret in (RELAY_TOKEN, PUSHOVER_TOKEN, PUSHOVER_USER_KEY, "request-secret"):
            self.assertNotIn(secret, combined)

    def test_escaping_bounds_the_field_before_it_escapes_it(self):
        """Truncate then escape, so no entity is cut in half at the boundary.

        Escaping first and cutting afterwards leaves a dangling `&am` at the
        boundary, which renders as literal text in the middle of a notification.
        Both of the relay's bounds are asserted through the renderer as well as
        on the helper, so a renderer that stopped bounding its input is caught
        too.
        """
        # An ordinary name is bounded on its input length and comes through whole.
        self.assertEqual(
            self.relay_module.html_escape("x" * 200), "x" * 128
        )
        # A name that escapes to six characters apiece is bounded on its OUTPUT,
        # by dropping whole input characters -- never by cutting the escaped
        # text, which is what would leave the dangling entity.
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
        self.assertIn(f"<b>Container:</b> {'x' * 128}\n", published["message"])
        self.assertNotIn("x" * 129, published["message"])

    def test_no_rendered_message_can_exceed_what_pushover_accepts(self):
        """Over Pushover's cap is a refused message, not a truncated one.

        The API rejects a `message` longer than 1024 characters with a 4xx, so
        the relay would raise UpstreamError, answer Dozzle 502, and the alert
        would simply be lost -- Dozzle does not retry. Escaping is what makes
        this reachable at all: `'` becomes `&#x27;`, so 128 characters of
        container name can render as 768 and two such fields overrun the cap
        between them.

        Real Docker container names cannot contain any of the five escaped
        characters, so nothing on this platform reaches it. The envelope accepts
        any non-control text in that field, so something could.
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

        # And on the wire, not only in the renderer.
        self.assertEqual(
            self.post(self.envelope(container=hostile, host=hostile))[0], 204
        )
        self.assertLessEqual(
            len(self.pushover.requests[-1]["form"]["message"]), cap
        )

    def test_no_rendered_title_can_exceed_what_pushover_accepts(self):
        """The title slice is the whole guard, and it was guarded by nothing.

        Pushover caps a title at 250 characters and rejects a longer one with a
        4xx -- the same lost alert an over-long message causes, reached by a
        much shorter input. The title is NOT escaped, so nothing expands; what
        makes it reachable is that the envelope admits a 256-character container
        name and only the slice in each renderer bounds it.

        Measured on the tree before this case existed: deleting the slice
        produced a 268-character title and all 54 tests stayed green.

        Both renderers, because they slice independently -- a fix applied to one
        would leave the other losing alerts.
        """
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

        # And on the wire, so a renderer that stopped bounding is caught even if
        # something else started doing it for them.
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
        self.assertTrue(notice["title"].startswith("Alerts suppressed"))
        self.assertLessEqual(
            len(notice["title"]), self.relay_module.MAX_TITLE_CHARACTERS
        )

    def test_the_container_notice_says_what_still_gets_through(self):
        """"Suppressed" would overstate it while the OOM allowance remains.

        A container past its ordinary ceiling still publishes out-of-memory
        kills up to the higher one, so the one message whose whole job is being
        honest about going quiet has to say so -- and has to stop saying so once
        that allowance is spent too.
        """
        for _index in range(CONTAINER_CEILING + 1):
            self.assertEqual(self.post(self.envelope("Unexpected exit"))[0], 204)
        notice = self.pushover.requests[-1]["form"]
        self.assertIn(
            f"<b>Still reporting:</b> out-of-memory kills, to {OOM_CONTAINER_CEILING} a day",
            notice["message"],
        )

        # A second container, taken past the OOM allowance before its first
        # notice: nothing is still reporting, and the notice must not claim
        # otherwise.
        spent = "b" * 64
        for _index in range(OOM_CONTAINER_CEILING):
            self.assertEqual(
                self.post(self.envelope("OOM", containerId=spent))[0], 204
            )
        self.assertEqual(
            self.post(self.envelope("Unexpected exit", containerId=spent))[0], 204
        )
        spent_notice = self.pushover.requests[-1]["form"]
        self.assertTrue(spent_notice["title"].startswith("Alerts suppressed"))
        self.assertNotIn("Still reporting", spent_notice["message"])

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
        self.assertEqual(notice["title"], "Alerts suppressed · ceiling reached")
        self.assertIn("<b>Suppressed:</b> every container, every rule", notice["message"])
        self.assertNotIn("Still reporting", notice["message"])


class RelayProcessSignalTest(unittest.TestCase):
    """What a deliberate stop does to the relay, run as its own process.

    services/dozzle/compose.yml starts the relay in exec form, so inside the
    container the Python process is PID 1 unless Compose is asked for an init.
    PID 1 has no default disposition for SIGTERM: the kernel delivers the signal
    only if the process installed a handler, and drops it otherwise. A relay
    that handled nothing but SIGINT therefore ignored `docker stop` outright and
    was SIGKILLed at the end of the grace period for exit 137 -- which the `die`
    rule pages on since #493, through the relay itself, which is the delivery
    path every alert on this platform takes. It paged on its own recreation and
    could not deliver the page (#516).

    A unit test cannot make a process PID 1; that needs a container, and the
    gate has no Docker. What it can assert is the property that makes the PID-1
    case safe, and it is exactly the property that was missing: the relay
    installs its own disposition for SIGTERM and exits zero under it, instead of
    depending on a default disposition PID 1 does not have. Without the handler
    this process is killed by the signal and reports returncode -SIGTERM, so
    these cases are red on the tree that had the bug.
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
        port = reserve_local_port()
        environment = dict(os.environ)
        environment.update(
            {
                "ALERT_RELAY_TOKEN": RELAY_TOKEN,
                "ALERT_RELAY_PORT": str(port),
                # Never dialled: these cases publish nothing. The discard
                # address keeps a misdirected publish from reaching anything,
                # and it is emphatically not api.pushover.net.
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
            # A request line cut short, so the worker thread is inside the read
            # when the signal lands. That is the window a shutdown implemented
            # as a raising signal handler loses the signal in: socketserver
            # catches whatever is raised while it dispatches a request and
            # carries on, and the stop then ends in the SIGKILL it was meant to
            # avoid.
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
        """The path that already worked, so the SIGTERM handler cannot cost it.

        SIGINT reached the relay before #516 as a KeyboardInterrupt out of
        serve_forever. Installing a handler for it replaces that exception, so
        this case is what says the replacement still ends in a clean exit.
        """
        status = self.signalled_exit(signal.SIGINT)

        self.assertEqual(status, 0, f"SIGINT must still end in a clean exit, got {status}")

    def test_sigterm_lands_cleanly_while_requests_are_in_flight(self):
        """The window a raising signal handler loses the stop in.

        socketserver reports any exception raised while it is dispatching a
        request through handle_error and keeps serving, so a stop implemented as
        a handler that raises is swallowed whenever the signal arrives between
        accept and the worker thread starting -- observed once in eight attempts
        of a raising handler, on SIGINT, with a client connecting at start-up.
        Blocking the signals and waiting for one has no such window, and this
        case is what says so.
        """
        status = self.signalled_exit(signal.SIGTERM, open_connections=3)

        self.assertEqual(
            status,
            0,
            "a stop arriving while requests are in flight must still exit zero, got "
            f"{status}",
        )



class RelayLinkBaseProcessTest(unittest.TestCase):
    """A relay whose environment predates the link base still starts and alerts.

    Run as a process, because the property is about start-up: the relay script
    reaches its container through the `current` release symlink before
    roles/dozzle re-renders the environment, so a restart in between runs this
    script against an environment that has never heard of ALERT_RELAY_LINK_BASE.
    """

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

if __name__ == "__main__":
    unittest.main()
