"""Report whether another deployment already holds this host's deployment lock (#326).

Takes the flock non-blocking and releases it at once, so it never becomes the holder;
an absent file means no poller. An unreadable file is a failure, never "free".
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
        # Released here, not at exit, so slow teardown cannot look like a deployment.
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
