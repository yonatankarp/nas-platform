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

**Only an infection fails the job (#811).** Anything that is not a verdict at all
-- a refused connection, a timeout, a short reply, an ERROR line, a
SAB_COMPLETE_DIR this container cannot see -- lets the job import and pages the
operator instead.

That reverses the fail-closed posture #793 shipped, and the reason is a
measurement rather than a preference. SABnzbd reports a failed job to the arr,
the arr's failed-download handling blocklists the release and searches for
another, so every job a broken scanner touches costs a release. #793 accepted
that on the reasoning that the readiness wait below covers the only window in
which the scanner is missing. It does not cover the window that actually
happened: on 2026-09-22, between 21:45:02 and 22:02:00, SABnzbd recorded 44 jobs
as `Exit(-1): Cannot run script /scripts/clamav_gate.py` and failed every one --
a script SABnzbd cannot launch never reaches any wait this file contains. 44
releases burned, zero infections found to date -- and read that second figure
with verdict() below, which records a reply-framing hazard that would make a
detection impossible and which nothing here has been able to observe either way.
An unscanned import is the cheaper of the two failures: what it risks is executable content sitting in a
library directory, which nothing on this platform runs, while a burned release is
certain and immediate.

**The alert is what keeps that from being a silent downgrade.** An unscanned
import is acceptable once and unacceptable as a standing state, and only a
notification tells the two apart; the message names the release so an operator
can distinguish an unscanned import from an infection without opening SABnzbd.
It goes out on the Pushover Alerts application at priority 1, which is what every
other publisher on that application uses for a problem. A clamd outage of the
shape measured above is therefore 44 high-priority messages, and there is no
ceiling here to soften that: the answer to the noise is repairing clamd, and a
ceiling would be a second thing that can silence this. A failed alert is printed
and swallowed -- a Pushover outage that failed the job would be this file's old
behaviour wearing a different hat.

**Exit 1 now means exactly one thing: clamd named a signature.** That is what
makes `script_can_fail: 1` still worth having, and it is also why every guard in
this file is broader than the failure it was written for -- a malformed URL, a
release name that is not UTF-8, a defect in this file. Any of them exiting 1
would have SABnzbd report an infection and the arr blocklist a release over a
traceback.

The readiness wait below still earns its place, for a different reason than it
used to. It no longer saves releases, because nothing here burns one any more: it
keeps a converge's container recreation from paging the operator once per job
that lands inside it.
"""

import os
import socket
import sys
import time
import urllib.parse
import urllib.request

HOST = os.environ.get("CLAMD_HOST", "clamav")
PORT = int(os.environ.get("CLAMD_PORT", "3310"))
# Long enough to sit out a container recreation during a converge, short enough
# that a clamd which is genuinely gone is reported rather than waited on for ever.
READY_TIMEOUT = float(os.environ.get("CLAMD_READY_TIMEOUT", "300"))
# A scan of the small files in one job is seconds. This bounds a clamd that
# accepted the connection and then stopped answering.
SCAN_TIMEOUT = float(os.environ.get("CLAMD_SCAN_TIMEOUT", "1800"))

# The Pushover Alerts application, rendered into this container's environment by
# roles/downloaders/templates/env.j2 the way roles/dozzle renders the same three
# values for services/dozzle/alert_relay.py. The `.env` is the shape that fits a
# container: the protected curl configs roles/image_prune and
# roles/production_auto_deploy use live in the deploy account's home, which is
# not reachable from inside one.
PUSHOVER_API_URL = os.environ.get(
    "PUSHOVER_API_URL", "https://api.pushover.net/1/messages.json"
)
PUSHOVER_ALERTS_TOKEN = os.environ.get("PUSHOVER_ALERTS_TOKEN", "")
PUSHOVER_USER_KEY = os.environ.get("PUSHOVER_USER_KEY", "")
# SABnzbd will not start the next job until this script returns, so the alert is
# on the critical path of the queue. Ten seconds is long enough for a POST and
# short enough that a black-holed endpoint is not a stalled downloader. It is
# parsed inside alert() rather than here because exit 1 now means INFECTED and
# nothing else: a float() at import would fail every job, clean ones included,
# with the code that tells the arr to blocklist the release.
ALERT_TIMEOUT = os.environ.get("PUSHOVER_TIMEOUT", "10")


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
    r"""Return clamd's reply lines for a recursive scan of `target`.

    SCAN rather than MULTISCAN, and the choice is load and not taste: MULTISCAN
    spreads one job across every thread clamd has, which is the shape that put
    the host at a loadavg of 3.29 of 4 and kept the temperature alert ringing.
    SCAN is single-threaded and stops at the first detection, which is all a gate
    needs to know. See the Temperature comment in roles/beszel/defaults/main.yml
    before reaching for the faster one.

    **The replace is about the framing of the reply, and which framing this clamd
    uses has not been observed here.** clamd is widely documented as terminating
    its replies with the same character the command prefix asked for, which would
    make a `z` command's answer `path: Sig FOUND\0` rather than `...FOUND\n`.
    Nothing in Python's splitlines() breaks on a NUL, so under that framing the
    two verdict tests below -- both anchored with endswith() -- would read every
    reply as one unterminated line, match neither " FOUND" nor " ERROR", and send
    every scan down the Clean branch. Nothing in this repository would say so:
    the readiness wait uses `"PONG" in reply`, a substring test that survives a
    trailing NUL either way, and no check anywhere runs this file against a real
    clamd. The replace costs nothing and is correct under both framings, which is
    why it is here rather than a question held open.

    One command settles which framing is live, from inside the SABnzbd container:
    `printf 'zPING\0' | nc clamav 3310 | xxd`. A trailing 00 means the replies
    were NUL-terminated and this line is load-bearing; a trailing 0a means they
    were not and it is a no-op.
    """
    reply = command(b"SCAN " + target.encode("utf-8"), timeout=SCAN_TIMEOUT)
    return [line for line in reply.replace("\0", "\n").splitlines() if line.strip()]


def alert(name: str, detail: str) -> None:
    """Page the operator that `name` imported without a verdict. Never raises.

    Every failure here is printed into SABnzbd's script log and swallowed. That
    is the whole point of the change this file records: an import that proceeds
    only when Pushover is reachable would be the old fail-closed behaviour with
    a third party added to it.

    Pushover authenticates by form field rather than by header, so the
    application token and the user key are in the request body and not in a
    header -- worth knowing wherever a request is captured, because a recorded
    body is a credential. Nothing below prints the body.

    Everything after the credential check is inside the try, not only the POST.
    A malformed PUSHOVER_API_URL raises from Request(), and a release name
    carrying bytes that are not UTF-8 -- which os.environ hands over as
    surrogates -- raises from urlencode(); both were measured exiting 1, which
    is the code that tells the arr the release was infected.
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
    # Both of these run before anything has asked clamd a question, so they are
    # the paths where `name` is whatever SABnzbd did or did not pass -- down to
    # the "(unnamed job)" placeholder, which is still a message worth sending.
    if not target:
        return unavailable(name, "SABnzbd passed no SAB_COMPLETE_DIR to scan.")
    if not os.path.isdir(target):
        return unavailable(name, f"{target} is not a directory this container can see.")

    try:
        await_clamd()
        lines = verdict(target)
    # Broad on purpose, and for the same reason the alert's guard is: the only
    # thing exit 1 may mean is that clamd named a signature. Anything else that
    # goes wrong between here and a verdict is an unscanned import.
    except Exception as error:  # noqa: BLE001
        return unavailable(name, f"{type(error).__name__}: {error}")

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
        return unavailable(
            name,
            "ClamAV could not complete the scan.",
            tuple(errored) or ("clamd returned an empty reply",),
        )

    print(f"Clean: ClamAV scanned {name} and found nothing in {len(lines)} result line(s).")
    return 0


if __name__ == "__main__":
    # The last net under the same rule. main() reports its own failures, so
    # reaching this is a defect rather than a scanner problem -- but a defect
    # that exited 1 would be read by SABnzbd and the arr as an infection, and a
    # release would be blocklisted over a traceback.
    try:
        EXIT_CODE = main()
    except Exception as error:  # noqa: BLE001
        print("SCANNER UNAVAILABLE: the gate itself failed "
              f"({type(error).__name__}: {error}).")
        EXIT_CODE = 0
    sys.exit(EXIT_CODE)
