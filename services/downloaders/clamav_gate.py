#!/usr/bin/env python3
"""SABnzbd post-processing gate: refuse a completed Usenet job clamd calls infected.

SABnzbd runs this after it has repaired, unpacked and moved the job into its
category directory under `.acquisition`, and before the job reaches history as
Completed. Sonarr, Radarr, Bindery and Kapowarr all import by polling that
history, so a job this script fails is never imported into a library -- which is
what makes a post-processing script, rather than a scheduled scan, the only shape
that satisfies "scan before we copy". A scheduled scan of `.acquisition` would
find an empty tree: the arr moves the job out within seconds of it landing.

The exit code only reaches SABnzbd because `script_can_fail` is 1 in
`downloaders_sabnzbd_owned_misc`. Its default is 0, under which SABnzbd records
the code in history as `Exit(n)` and imports the job anyway, so this file is
inert without that setting and the two belong together.

**What is scanned is not the whole download.** clamd's stock `MaxFileSize` and
`MaxScanSize` (100MB and 400MB in clamav 1.5) mean it skips the video and audio
files entirely rather than reading them. That is deliberate here and not a
limitation worked around: the executable content a Usenet drop can carry is in
the small files beside the media -- archives, scripts, .lnk, .exe, sample
payloads -- and reading a 40GB remux would put a core back under the sustained
load that #608's temperature alert exists to report. An operator reading
"downloads are scanned" should read this paragraph as the scope.

Fail closed. Anything that is not an explicit per-file OK from clamd -- a refused
connection, a timeout, a short reply, an ERROR line -- fails the job, because a
scanner that passes what it could not read is worse than no scanner at all. The
cost of that choice is real and is the reason for the readiness wait below:
SABnzbd reports a failed job to the arr, and the arr's failed-download handling
blocklists the release and searches for another, so a clamd that is merely
missing burns releases. The wait covers the window a converge's `docker compose
up` recreation opens; beyond it, burning a release is the intended outcome.
"""

import os
import socket
import sys
import time

HOST = os.environ.get("CLAMD_HOST", "clamav")
PORT = int(os.environ.get("CLAMD_PORT", "3310"))
# Long enough to sit out a container recreation during a converge, short enough
# that a clamd which is genuinely gone is reported rather than waited on for ever.
READY_TIMEOUT = float(os.environ.get("CLAMD_READY_TIMEOUT", "300"))
# A scan of the small files in one job is seconds. This bounds a clamd that
# accepted the connection and then stopped answering.
SCAN_TIMEOUT = float(os.environ.get("CLAMD_SCAN_TIMEOUT", "1800"))


def command(payload: bytes, timeout: float) -> str:
    """Send one NULL-delimited clamd command and return the whole reply.

    The `z` prefix rather than `n`: it delimits with NUL, which upstream
    recommends because it is the one framing a path can never contain. A newline
    is legal in a POSIX filename and so in a release name.
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
    """Return clamd's reply lines for a recursive scan of `target`.

    SCAN rather than MULTISCAN, and the choice is load and not taste: MULTISCAN
    spreads one job across every thread clamd has, which is the shape that put
    the host at a loadavg of 3.29 of 4 and kept the temperature alert ringing.
    SCAN is single-threaded and stops at the first detection, which is all a gate
    needs to know. See the Temperature comment in roles/beszel/defaults/main.yml
    before reaching for the faster one.
    """
    reply = command(b"SCAN " + target.encode("utf-8"), timeout=SCAN_TIMEOUT)
    return [line for line in reply.splitlines() if line.strip()]


def main() -> int:
    target = os.environ.get("SAB_COMPLETE_DIR", "")
    name = os.environ.get("SAB_FINAL_NAME") or target or "(unnamed job)"
    if not target:
        print("SCANNER UNAVAILABLE: SABnzbd passed no SAB_COMPLETE_DIR to scan.")
        return 3
    if not os.path.isdir(target):
        print(f"SCANNER UNAVAILABLE: {target} is not a directory this container can see.")
        return 3

    try:
        await_clamd()
        lines = verdict(target)
    except (OSError, RuntimeError) as error:
        print(f"SCANNER UNAVAILABLE: {name} was not scanned: {error}")
        return 3

    infected = [line for line in lines if line.endswith(" FOUND")]
    if infected:
        print(f"INFECTED: {name} was refused by ClamAV.")
        for line in infected:
            print(line)
        return 1

    # An empty reply is not a clean result: it is clamd having said nothing at
    # all, which is the failure this branch exists to keep out of the OK path.
    errored = [line for line in lines if line.endswith(" ERROR")]
    if errored or not lines:
        print(f"SCANNER UNAVAILABLE: ClamAV could not complete the scan of {name}.")
        for line in errored or ["clamd returned an empty reply"]:
            print(line)
        return 3

    print(f"Clean: ClamAV scanned {name} and found nothing in {len(lines)} result line(s).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
