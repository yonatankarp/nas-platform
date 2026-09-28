#!/usr/bin/env python3
"""SABnzbd post-processing gate: refuse a completed Usenet job clamd calls infected.

Runs before the job reaches history, so a failed job is never imported. The exit
code matters only because `script_can_fail` is 1 in
`downloaders_sabnzbd_owned_misc`. clamd's stock size limits skip the media files
on purpose; the executable content is in the small files beside them.

Exit 1 means exactly one thing: clamd named a signature (#811). Anything that is
not a verdict imports the job and pages the operator instead, because a failed
job makes the arr blocklist the release.
"""

import os
import socket
import sys
import time
import urllib.parse
import urllib.request

HOST = os.environ.get("CLAMD_HOST", "clamav")
PORT = int(os.environ.get("CLAMD_PORT", "3310"))
# Long enough to sit out a container recreation during a converge.
READY_TIMEOUT = float(os.environ.get("CLAMD_READY_TIMEOUT", "300"))
# Bounds a clamd that accepted the connection and then stopped answering.
SCAN_TIMEOUT = float(os.environ.get("CLAMD_SCAN_TIMEOUT", "1800"))

# The Pushover Alerts application, rendered by roles/downloaders/templates/env.j2.
PUSHOVER_API_URL = os.environ.get(
    "PUSHOVER_API_URL", "https://api.pushover.net/1/messages.json"
)
PUSHOVER_ALERTS_TOKEN = os.environ.get("PUSHOVER_ALERTS_TOKEN", "")
PUSHOVER_USER_KEY = os.environ.get("PUSHOVER_USER_KEY", "")
# The alert is on the queue's critical path. Parsed inside alert(), not here, so
# a bad value can never exit 1 (which means INFECTED).
ALERT_TIMEOUT = os.environ.get("PUSHOVER_TIMEOUT", "10")


def command(payload: bytes, timeout: float) -> str:
    """Send one NUL-delimited clamd command (`z` prefix) and return the whole reply.

    NUL is the one framing a path (and so a release name) can never contain.
    """
    with socket.create_connection((HOST, PORT), timeout=timeout) as sock:
        sock.settimeout(timeout)
        sock.sendall(b"z" + payload + b"\0")
        chunks = []
        while True:
            chunk = sock.recv(8192)
            if not chunk:
                break
            chunks.append(chunk)
    return b"".join(chunks).decode("utf-8", "replace")


def await_clamd() -> None:
    """Block until clamd answers PING, or raise the last error at the deadline."""
    deadline = time.monotonic() + READY_TIMEOUT
    while True:
        try:
            if "PONG" in command(b"PING", timeout=10):
                return
            failure = "clamd answered PING with something other than PONG"
        except OSError as error:
            failure = f"clamd is unreachable at {HOST}:{PORT} ({error})"
        if time.monotonic() >= deadline:
            raise RuntimeError(f"{failure}; still true after {READY_TIMEOUT:.0f}s")
        time.sleep(5)


def verdict(target: str) -> list[str]:
    r"""Return clamd's reply lines for a recursive scan of `target`.

    SCAN, not MULTISCAN: multithreaded scans are what pegged the host (see the
    Temperature alert in roles/beszel/defaults/main.yml). The replace handles
    NUL-terminated replies, which endswith() would otherwise never match; which
    framing this clamd uses is unobserved: `printf 'zPING\0' | nc clamav 3310 | xxd`.
    """
    reply = command(b"SCAN " + target.encode("utf-8"), timeout=SCAN_TIMEOUT)
    return [line for line in reply.replace("\0", "\n").splitlines() if line.strip()]


def alert(name: str, detail: str) -> None:
    """Page the operator that `name` imported without a verdict. Never raises.

    Everything after the credential check is inside the try: a malformed URL or a
    non-UTF-8 release name must not exit 1. The body carries credentials.
    """
    if not (PUSHOVER_ALERTS_TOKEN and PUSHOVER_USER_KEY):
        print("The unscanned-import alert was not sent: no Pushover credentials in "
              "this container's environment.")
        return
    try:
        body = urllib.parse.urlencode(
            {
                "token": PUSHOVER_ALERTS_TOKEN,
                "user": PUSHOVER_USER_KEY,
                "title": "SABnzbd imported an unscanned download",
                "message": f"{name} was imported without a ClamAV verdict: {detail}",
                "priority": 1,
            }
        ).encode("ascii")
        request = urllib.request.Request(
            PUSHOVER_API_URL,
            data=body,
            headers={"Content-Type": "application/x-www-form-urlencoded"},
            method="POST",
        )
        with urllib.request.urlopen(request, timeout=float(ALERT_TIMEOUT)) as response:
            print(f"Unscanned-import alert sent (HTTP {response.status}).")
    except Exception as error:  # noqa: BLE001 - a failed alert must not fail the job
        print("The unscanned-import alert was not delivered "
              f"({type(error).__name__}: {error}).")


def unavailable(name: str, detail: str, lines: tuple[str, ...] = ()) -> int:
    """Report an unscanned import, alert, and exit 0 so SABnzbd imports the job."""
    print(f"SCANNER UNAVAILABLE: {name} was imported without being scanned: {detail}")
    for line in lines:
        print(line)
    alert(name, detail)
    return 0


def main() -> int:
    target = os.environ.get("SAB_COMPLETE_DIR", "")
    name = os.environ.get("SAB_FINAL_NAME") or target or "(unnamed job)"
    # These run before clamd is asked anything; `name` may be the placeholder.
    if not target:
        return unavailable(name, "SABnzbd passed no SAB_COMPLETE_DIR to scan.")
    if not os.path.isdir(target):
        return unavailable(name, f"{target} is not a directory this container can see.")

    try:
        await_clamd()
        lines = verdict(target)
    # Broad on purpose: only a signature may exit 1.
    except Exception as error:  # noqa: BLE001
        return unavailable(name, f"{type(error).__name__}: {error}")

    infected = [line for line in lines if line.endswith(" FOUND")]
    if infected:
        print(f"INFECTED: {name} was refused by ClamAV.")
        for line in infected:
            print(line)
        return 1

    # An empty reply is clamd having said nothing, not a clean result.
    errored = [line for line in lines if line.endswith(" ERROR")]
    if errored or not lines:
        return unavailable(
            name,
            "ClamAV could not complete the scan.",
            tuple(errored) or ("clamd returned an empty reply",),
        )

    print(f"Clean: ClamAV scanned {name} and found nothing in {len(lines)} result line(s).")
    return 0


if __name__ == "__main__":
    # Last net: a defect exiting 1 would blocklist a release over a traceback.
    try:
        EXIT_CODE = main()
    except Exception as error:  # noqa: BLE001
        print("SCANNER UNAVAILABLE: the gate itself failed "
              f"({type(error).__name__}: {error}).")
        EXIT_CODE = 0
    sys.exit(EXIT_CODE)
