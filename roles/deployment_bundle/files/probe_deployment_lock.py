"""Report whether another deployment already holds this host's deployment lock.

Issue #326. scripts/production_auto_deploy.py serialises deployments with an
flock on <state>/deployment.lock, and the poller cannot race itself. A hand-run
ansible-playbook took no lock at all, so on a host polling every five minutes a
manual converge lasting longer than five minutes overlapped the poller's. What
the operator saw was not a lock-contention message: the poller repointed
`current` at a release of its own while the manual run was still converging
services against the release *it* had activated, and the run died 1463 tasks in
on the containment guard, naming an unsafe deployment target -- the same message
a genuine path traversal or a corrupted pointer produces.

This probe exists so that failure arrives at the first task of the first role,
saying what is actually true. It reads; it never creates the lock file and never
holds the lock. Acquiring the flock non-blocking and immediately releasing it is
the only way to ask "is somebody holding this?" without becoming the holder, and
an absent file means the poller is not installed on this host, which is the
normal case in the sandboxes and on a Mac.

The holder record inside the file is advisory: the flock is the liveness truth,
so a record is only reported when the lock is actually held. A file that exists
but cannot be read is reported as a failure rather than as "free", because the
one thing this must never do is quietly stop guarding.
"""

import fcntl
import json
import os
import sys


def probe(path):
    """Describe the current holder of `path`, without becoming one."""

    if not os.path.exists(path):
        return {"state": "absent", "held": False}
    try:
        descriptor = os.open(path, os.O_RDONLY)
    except OSError as error:
        raise SystemExit(
            f"Deployment lock {path} exists but cannot be read ({error}); "
            "refusing to guess whether a deployment is already running"
        )
    try:
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            return {"state": "held", "held": True, **_holder(descriptor)}
        # Held for microseconds and released here rather than at process exit,
        # so a slow interpreter teardown cannot make the next probe -- or the
        # poller's own next tick -- see this read as a deployment.
        fcntl.flock(descriptor, fcntl.LOCK_UN)
        return {"state": "free", "held": False}
    finally:
        os.close(descriptor)


def _holder(descriptor):
    """Whatever the holder wrote about itself, or nothing legible."""

    try:
        payload = json.loads(os.pread(descriptor, 4096, 0).decode("ascii"))
    except (OSError, UnicodeError, ValueError):
        return {}
    if not isinstance(payload, dict):
        return {}
    return {
        key: payload[key]
        for key in ("pid", "holder", "started")
        if isinstance(payload.get(key), (str, int))
    }


def main(argv):
    if len(argv) != 1:
        raise SystemExit("Deployment lock probe expects exactly one lock path")
    print(json.dumps(probe(argv[0]), sort_keys=True))


if __name__ == "__main__":
    main(sys.argv[1:])
