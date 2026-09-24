"""The gate's verdict logic, against a real socket serving clamd's replies.

The subject is services/downloaders/clamav_gate.py, whose whole job is turning a
clamd reply into an exit code SABnzbd acts on. Since #811 only an infection is
allowed to fail a job: every other outcome imports it and pages the operator, so
the pairing of exit code and alert is what each case below asserts. The fake
clamd speaks the wire protocol rather than the module being stubbed, and the
fake Pushover is an HTTP server rather than a patched function, because the two
things that can silently stop working are the framing and the POST.

Every case points PUSHOVER_API_URL at that fake. A case that forgot would reach
pushover.net from the gate with whatever credentials the environment carried.
"""

import importlib.util
import os
import socket
import threading
import unittest
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs

ROOT = Path(__file__).resolve().parent.parent
GATE = ROOT / "services" / "downloaders" / "clamav_gate.py"

ALERTS_TOKEN = "clamav-gate-test-alerts-token"
USER_KEY = "clamav-gate-test-user-key"


@contextmanager
def load_gate(**env):
    """Import the gate fresh under `env`, and hold `env` while it runs.

    The module reads the clamd address and the Pushover credentials at import
    and SAB_COMPLETE_DIR inside main(), so the environment has to outlive the
    import rather than be restored at it -- restoring early made every case take
    the "SABnzbd passed no SAB_COMPLETE_DIR" branch and two of them still read as
    passes. A None value unsets the variable, which is how the case for an
    environment carrying no token at all is expressed.
    """
    previous = {key: os.environ.get(key) for key in env}
    for key, value in env.items():
        if value is None:
            os.environ.pop(key, None)
        else:
            os.environ[key] = value
    try:
        spec = importlib.util.spec_from_file_location("clamav_gate", GATE)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        yield module
    finally:
        for key, value in previous.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value


@contextmanager
def fake_clamd(replies):
    """Serve one scripted reply per connection on an ephemeral port.

    `replies` is consumed in order; PING arrives on its own connection, so a case
    that scans answers PONG first and the scan reply second.
    """
    listener = socket.socket()
    listener.bind(("127.0.0.1", 0))
    listener.listen(8)
    served = []

    def serve():
        for reply in replies:
            try:
                conn, _ = listener.accept()
            except OSError:
                return
            with conn:
                served.append(conn.recv(8192))
                if reply is not None:
                    conn.sendall(reply)

    thread = threading.Thread(target=serve, daemon=True)
    thread.start()
    try:
        yield listener.getsockname()[1], served
    finally:
        listener.close()
        thread.join(timeout=5)


@contextmanager
def fake_pushover(status=200):
    """Accept POSTs on an ephemeral port and record each decoded form body."""
    received = []

    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.0"

        def do_POST(self):  # noqa: N802 - BaseHTTPRequestHandler's own spelling
            body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
            received.append(parse_qs(body.decode("utf-8")))
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", "2")
            self.end_headers()
            self.wfile.write(b"{}")

        def log_message(self, *args):
            """Keep the server's request log out of the test output."""

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield f"http://127.0.0.1:{server.server_address[1]}/1/messages.json", received
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)


def closed_port():
    """A port nothing is listening on, for the two unreachable-endpoint cases."""
    listener = socket.socket()
    listener.bind(("127.0.0.1", 0))
    port = listener.getsockname()[1]
    listener.close()
    return port


class ClamavGateTest(unittest.TestCase):
    def run_gate(self, replies, target=None, ready_timeout="5",
                 pushover_status=200, **overrides):
        """Run main() against a fake clamd and a fake Pushover.

        Returns the exit code, what clamd was sent, and the alert bodies the
        fake Pushover received -- the three things every case below reads.
        """
        with fake_pushover(status=pushover_status) as (api_url, received):
            with fake_clamd(replies) as (port, served):
                environment = {
                    "CLAMD_HOST": "127.0.0.1",
                    "CLAMD_PORT": str(port),
                    "CLAMD_READY_TIMEOUT": ready_timeout,
                    "CLAMD_SCAN_TIMEOUT": "5",
                    "SAB_COMPLETE_DIR": target if target is not None else str(ROOT),
                    "SAB_FINAL_NAME": "Some.Release.2026",
                    "PUSHOVER_API_URL": api_url,
                    "PUSHOVER_ALERTS_TOKEN": ALERTS_TOKEN,
                    "PUSHOVER_USER_KEY": USER_KEY,
                    "PUSHOVER_TIMEOUT": "5",
                }
                environment.update(overrides)
                with load_gate(**environment) as module:
                    return module.main(), served, received

    def assert_alerted(self, received, name="Some.Release.2026"):
        """One alert, on the Alerts application, naming the release."""
        self.assertEqual(len(received), 1, received)
        alert = received[0]
        self.assertEqual(alert.get("token"), [ALERTS_TOKEN])
        self.assertEqual(alert.get("user"), [USER_KEY])
        self.assertEqual(alert.get("priority"), ["1"])
        self.assertIn(name, alert.get("message", [""])[0])

    def test_clean_scan_passes_and_does_not_alert(self):
        code, served, received = self.run_gate([b"PONG\n", b"/scan: OK\n"])
        self.assertEqual(code, 0)
        self.assertEqual(received, [])
        # The z-prefix framing is part of the contract: a release name may
        # legally contain a newline, which is exactly what `n` would split on.
        self.assertTrue(served[1].startswith(b"zSCAN "), served[1])
        self.assertTrue(served[1].endswith(b"\0"), served[1])

    def test_infection_fails_the_job_and_does_not_alert(self):
        """The one verdict that still fails a job, and the one that pages nobody.

        An infection reaches the operator as a failed job in SABnzbd and as the
        arr's failed-download handling. Paging for it too would make the alert
        this file added stop meaning "imported unscanned".
        """
        code, _, received = self.run_gate(
            [b"PONG\n", b"/scan/x.exe: Win.Test.EICAR FOUND\n"]
        )
        self.assertEqual(code, 1)
        self.assertEqual(received, [])

    def test_scan_error_imports_and_alerts(self):
        code, _, received = self.run_gate([b"PONG\n", b"/scan: Can't open file ERROR\n"])
        self.assertEqual(code, 0)
        self.assert_alerted(received)

    def test_empty_reply_imports_and_alerts(self):
        """The branch an infected file never reaches and a broken clamd always does."""
        code, _, received = self.run_gate([b"PONG\n", b""])
        self.assertEqual(code, 0)
        self.assert_alerted(received)

    def test_unreachable_clamd_imports_and_alerts(self):
        code, _, received = self.run_gate(
            [b"PONG\n"], ready_timeout="0", CLAMD_PORT=str(closed_port())
        )
        self.assertEqual(code, 0)
        self.assert_alerted(received)

    def test_missing_and_bogus_complete_dir_import_and_alert(self):
        """The two branches that run before clamd is asked anything.

        SAB_FINAL_NAME is dropped as well, so this is also the case where the
        alert has only the "(unnamed job)" placeholder to name -- the path where
        there is nothing to report is still a path.
        """
        for target in ("", str(ROOT / "does-not-exist")):
            with self.subTest(target=target):
                code, _, received = self.run_gate(
                    [b"PONG\n"], target=target, SAB_FINAL_NAME=None
                )
                self.assertEqual(code, 0)
                self.assert_alerted(received, name=target or "(unnamed job)")

    def test_rejected_alert_still_imports(self):
        """Pushover answering 500 must not resurrect the fail-closed behaviour."""
        code, _, received = self.run_gate([b"PONG\n", b""], pushover_status=500)
        self.assertEqual(code, 0)
        self.assertEqual(len(received), 1, received)

    def test_unreachable_alert_endpoint_still_imports(self):
        code, _, _ = self.run_gate(
            [b"PONG\n", b""],
            PUSHOVER_API_URL=f"http://127.0.0.1:{closed_port()}/1/messages.json",
        )
        self.assertEqual(code, 0)

    def test_missing_credentials_still_import_and_send_nothing(self):
        """An environment with no token: no alert to send, and still an import."""
        code, _, received = self.run_gate([b"PONG\n", b""], PUSHOVER_ALERTS_TOKEN=None)
        self.assertEqual(code, 0)
        self.assertEqual(received, [])


if __name__ == "__main__":
    unittest.main()
