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

Two framings and two shapes of case, and both pairs exist for a reason a green
run did not give. clamd answers a `z`-prefixed command with NUL-terminated
replies, and the fixture served newline-terminated ones, so the whole suite
passed over a verdict test that could not have matched a real reply. And every
case called main() in-process, which sees a return value rather than an exit
code -- so a crash on the way to one, which is what a malformed Pushover URL
was, was invisible here while the process exited 1 and told the arr the release
was infected. The subprocess cases at the end are the ones that see that.
"""

import importlib.util
import os
import socket
import subprocess
import sys
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

    def run_script(self, **env):
        """Run the gate as SABnzbd runs it: a process, read for its exit code.

        `main()` returning is not the same event as the process exiting, and the
        difference is everything the in-process cases cannot see -- an
        import-time failure, and any exception escaping main().
        """
        environment = {
            "PATH": os.environ.get("PATH", ""),
            "CLAMD_HOST": "127.0.0.1",
            "CLAMD_PORT": str(closed_port()),
            "CLAMD_READY_TIMEOUT": "0",
            "CLAMD_SCAN_TIMEOUT": "5",
            "SAB_COMPLETE_DIR": str(ROOT),
            "SAB_FINAL_NAME": "Some.Release.2026",
            "PUSHOVER_ALERTS_TOKEN": ALERTS_TOKEN,
            "PUSHOVER_USER_KEY": USER_KEY,
            "PUSHOVER_TIMEOUT": "5",
        }
        environment.update({k: v for k, v in env.items() if v is not None})
        return subprocess.run(
            [sys.executable, str(GATE)], env=environment, check=False,
            capture_output=True, text=True, errors="replace", timeout=60,
        )

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


    def test_nul_terminated_replies_are_read(self):
        """The framing a real clamd answers a `z` command with.

        Nothing in splitlines() breaks on a NUL, so a reply terminated the way
        the gate asked for it to be terminated used to arrive as one line
        ending in "\x00" -- matching neither " FOUND" nor " ERROR", and taking
        the Clean branch with a signature in it.
        """
        infected, _, received = self.run_gate(
            [b"PONG\0", b"/scan/x.exe: Win.Test.EICAR FOUND\0"]
        )
        self.assertEqual(infected, 1)
        self.assertEqual(received, [])

        errored, _, received = self.run_gate([b"PONG\0", b"/scan: Can't open file ERROR\0"])
        self.assertEqual(errored, 0)
        self.assert_alerted(received)

        clean, _, received = self.run_gate([b"PONG\0", b"/scan: OK\0"])
        self.assertEqual(clean, 0)
        self.assertEqual(received, [])

    def test_process_exits_zero_when_it_cannot_scan(self):
        """The exit code SABnzbd actually reads, from a real process."""
        with fake_pushover() as (api_url, received):
            completed = self.run_script(PUSHOVER_API_URL=api_url)
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assert_alerted(received)

    def test_process_exits_one_only_for_an_infection(self):
        with fake_pushover() as (api_url, _):
            with fake_clamd([b"PONG\0", b"/scan/x.exe: Win.Test.EICAR FOUND\0"]) as (port, _):
                completed = self.run_script(
                    PUSHOVER_API_URL=api_url, CLAMD_PORT=str(port),
                    CLAMD_READY_TIMEOUT="5",
                )
        self.assertEqual(completed.returncode, 1, completed.stderr)
        self.assertIn("INFECTED", completed.stdout)

    def test_a_broken_alert_configuration_does_not_exit_one(self):
        """Exit 1 is the arr's blocklist signal, so no defect may borrow it.

        Each of these was measured exiting 1 before the guards widened: a URL
        Request() refuses, a release name os.environ hands over as surrogates,
        and a timeout float() cannot parse, which fails at import.
        """
        for label, override in (
            ("no scheme", {"PUSHOVER_API_URL": "api.pushover.net/1/messages.json"}),
            ("unsupported scheme", {"PUSHOVER_API_URL": "gopher://example.invalid/x"}),
            ("unparseable timeout", {"PUSHOVER_TIMEOUT": "abc"}),
        ):
            with self.subTest(label=label):
                completed = self.run_script(**override)
                self.assertEqual(completed.returncode, 0, completed.stderr)

    def test_a_release_name_that_is_not_utf8_does_not_exit_one(self):
        """os.environ decodes undecodable bytes as surrogates; urlencode refuses them."""
        completed = self.run_script(
            PUSHOVER_API_URL="http://127.0.0.1:1/1/messages.json",
            SAB_FINAL_NAME=b"Release.\xff\xfe.name".decode("utf-8", "surrogateescape"),
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)


if __name__ == "__main__":
    unittest.main()
