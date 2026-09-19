"""The gate's verdict logic, against a real socket serving clamd's replies.

The subject is services/downloaders/clamav_gate.py, whose whole job is turning a
clamd reply into an exit code SABnzbd acts on. Three of its four outcomes are
failure paths, and the one that matters most is the one no infected file
exercises: a scanner that could not scan must not exit 0. So the fake below
speaks the wire protocol rather than the module being stubbed, and every case
asserts the exit code, because the exit code is the entire interface SABnzbd has
to this file.
"""

import importlib.util
import os
import socket
import threading
import unittest
from contextlib import contextmanager
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
GATE = ROOT / "services" / "downloaders" / "clamav_gate.py"


@contextmanager
def load_gate(**env):
    """Import the gate fresh under `env`, and hold `env` while it runs.

    The module reads the clamd address at import and SAB_COMPLETE_DIR inside
    main(), so the environment has to outlive the import rather than be restored
    at it -- restoring early made every case take the "SABnzbd passed no
    SAB_COMPLETE_DIR" branch and two of them still read as passes.
    """
    previous = {key: os.environ.get(key) for key in env}
    os.environ.update(env)
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


class ClamavGateTest(unittest.TestCase):
    def run_gate(self, replies, target=None, ready_timeout="5"):
        with fake_clamd(replies) as (port, served):
            with load_gate(
                CLAMD_HOST="127.0.0.1",
                CLAMD_PORT=str(port),
                CLAMD_READY_TIMEOUT=ready_timeout,
                CLAMD_SCAN_TIMEOUT="5",
                SAB_COMPLETE_DIR=target if target is not None else str(ROOT),
                SAB_FINAL_NAME="Some.Release.2026",
            ) as module:
                return module.main(), served

    def test_clean_scan_passes(self):
        code, served = self.run_gate([b"PONG\n", b"/scan: OK\n"])
        self.assertEqual(code, 0)
        # The z-prefix framing is part of the contract: a release name may
        # legally contain a newline, which is exactly what `n` would split on.
        self.assertTrue(served[1].startswith(b"zSCAN "), served[1])
        self.assertTrue(served[1].endswith(b"\0"), served[1])

    def test_infection_fails_the_job(self):
        code, _ = self.run_gate([b"PONG\n", b"/scan/x.exe: Win.Test.EICAR FOUND\n"])
        self.assertEqual(code, 1)

    def test_scan_error_is_not_a_pass(self):
        code, _ = self.run_gate([b"PONG\n", b"/scan: Can't open file ERROR\n"])
        self.assertEqual(code, 3)

    def test_empty_reply_is_not_a_pass(self):
        """The branch an infected file never reaches and a broken clamd always does."""
        code, _ = self.run_gate([b"PONG\n", b""])
        self.assertEqual(code, 3)

    def test_unreachable_clamd_fails_closed(self):
        listener = socket.socket()
        listener.bind(("127.0.0.1", 0))
        port = listener.getsockname()[1]
        listener.close()
        with load_gate(
            CLAMD_HOST="127.0.0.1", CLAMD_PORT=str(port), CLAMD_READY_TIMEOUT="0",
            CLAMD_SCAN_TIMEOUT="5", SAB_COMPLETE_DIR=str(ROOT), SAB_FINAL_NAME="x",
        ) as module:
            self.assertEqual(module.main(), 3)

    def test_missing_and_bogus_complete_dir_fail_closed(self):
        for target in ("", str(ROOT / "does-not-exist")):
            with self.subTest(target=target):
                code, _ = self.run_gate([b"PONG\n"], target=target)
                self.assertEqual(code, 3)


if __name__ == "__main__":
    unittest.main()
