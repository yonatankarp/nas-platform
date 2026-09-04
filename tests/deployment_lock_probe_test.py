#!/usr/bin/env python3

"""Behavioural tests for the deployment lock probe deployment_bundle runs.

The probe is what turns issue #326's late, misleading failure -- a containment
refusal 1463 tasks into a run whose real problem was a second converge -- into a
refusal at the first task of the role that would have raced. It has exactly two
ways to be wrong, and both are silent: reporting a held lock as free disarms the
guard, and reporting a free lock as held stops every deployment on the host.
"""

import fcntl
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPT = (
    Path(__file__).resolve().parents[1]
    / "roles"
    / "deployment_bundle"
    / "files"
    / "probe_deployment_lock.py"
)


class DeploymentLockProbeTest(unittest.TestCase):
    def setUp(self):
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary_directory.cleanup)
        self.state = Path(os.path.realpath(self.temporary_directory.name))
        self.lock = self.state / "deployment.lock"

    def probe(self, *arguments):
        return subprocess.run(
            [sys.executable, str(SCRIPT), *arguments],
            capture_output=True,
            text=True,
            check=False,
        )

    def report(self, *arguments):
        completed = self.probe(*(arguments or (str(self.lock),)))
        self.assertEqual(completed.returncode, 0, completed.stderr)
        return json.loads(completed.stdout)

    def hold(self, payload=None):
        """Hold the lock for the rest of the test, as the poller holds it."""

        descriptor = os.open(self.lock, os.O_WRONLY | os.O_CREAT, 0o600)
        self.addCleanup(os.close, descriptor)
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        if payload is not None:
            os.write(descriptor, payload)
        return descriptor

    def test_a_host_without_a_poller_has_no_lock_and_is_not_guarded(self):
        self.assertEqual(self.report(), {"state": "absent", "held": False})
        self.assertFalse(
            self.lock.exists(),
            "probing must never create the lock file it reads",
        )

    def test_an_unheld_lock_reports_free(self):
        self.lock.write_bytes(b"")
        self.assertEqual(self.report(), {"state": "free", "held": False})

    def test_a_held_lock_reports_the_holder_it_recorded(self):
        self.hold(
            json.dumps(
                {"pid": 4711, "holder": "operator converge", "started": "2026-09-03T11:20:31Z"}
            ).encode("ascii")
        )
        self.assertEqual(
            self.report(),
            {
                "state": "held",
                "held": True,
                "pid": 4711,
                "holder": "operator converge",
                "started": "2026-09-03T11:20:31Z",
            },
        )

    def test_a_held_lock_without_a_legible_record_is_still_held(self):
        # A holder that crashed before writing, or an older poller that wrote
        # nothing at all. The flock is the liveness truth; the record is a
        # courtesy, and losing it must not lose the refusal.
        self.hold(b"not json at all\n")
        self.assertEqual(self.report(), {"state": "held", "held": True})

    def test_a_stale_record_under_a_free_lock_is_not_reported_as_a_holder(self):
        # The record outlives its holder: nothing truncates it on release, and a
        # crashed holder leaves it behind. Reporting it would stop every
        # deployment on the host until somebody deleted a file by hand.
        self.lock.write_bytes(json.dumps({"pid": 4711, "holder": "poll"}).encode("ascii"))
        self.assertEqual(self.report(), {"state": "free", "held": False})

    def test_probing_does_not_leave_the_lock_held(self):
        self.lock.write_bytes(b"")
        self.report()
        descriptor = os.open(self.lock, os.O_WRONLY)
        self.addCleanup(os.close, descriptor)
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)

    @unittest.skipIf(os.geteuid() == 0, "root can read a mode 0000 lock file")
    def test_an_unreadable_lock_fails_loudly_rather_than_reporting_free(self):
        self.lock.write_bytes(b"")
        self.lock.chmod(0)
        self.addCleanup(self.lock.chmod, 0o600)

        completed = self.probe(str(self.lock))

        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("cannot be read", completed.stderr)
        self.assertEqual(completed.stdout, "")

    def test_a_malformed_invocation_is_refused(self):
        completed = self.probe(str(self.lock), str(self.lock))

        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("exactly one lock path", completed.stderr)


if __name__ == "__main__":
    unittest.main()
