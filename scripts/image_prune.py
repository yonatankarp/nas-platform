#!/usr/bin/env python3
"""Reclaim disk space by removing Docker images nothing references."""

from __future__ import annotations

import contextlib
from contextlib import contextmanager
from dataclasses import dataclass, fields
from datetime import datetime, timedelta, timezone
import fcntl
import html
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time
from typing import Iterator

# Images are pinned as repo:tag@sha256:..., so every Renovate bump pulls a new
# image and leaves the superseded one behind. Nothing else on the NAS removes
# them, which is what this exists to do.
PRUNE_LOG_PATTERN = re.compile(r"(\d{8}T\d{6}Z)-prune")
RECLAIMED_PATTERN = re.compile(
    r"^Total reclaimed space:\s*([0-9]+(?:\.[0-9]+)?)\s*([A-Za-z]{1,3})\s*$",
    re.MULTILINE,
)
DELETED_PATTERN = re.compile(r"^deleted:\s*sha256:[0-9a-f]{64}\s*$", re.MULTILINE)
# Docker renders sizes with go-units, which is decimal. Binary suffixes are
# accepted anyway rather than silently reading as zero if that ever changes.
BYTE_UNITS = {
    "b": 1,
    "kb": 1000,
    "mb": 1000**2,
    "gb": 1000**3,
    "tb": 1000**4,
    "pb": 1000**5,
    "kib": 1024,
    "mib": 1024**2,
    "gib": 1024**3,
    "tib": 1024**4,
    "pib": 1024**5,
}
# A same-day image is never a candidate. The window is a margin, not the
# mutual exclusion: `until` filters on when an image was *created* upstream,
# not on when this host pulled it, so a release published months ago and
# pulled a minute ago is already outside any window. What actually keeps a
# prune off a running deployment is the deployment lock below.
MINIMUM_RETENTION_HOURS = 24
PRUNE_TIMEOUT_SECONDS = 15 * 60
INVENTORY_TIMEOUT_SECONDS = 60
NOTIFICATION_TIMEOUT_SECONDS = 10
LOCK_POLL_SECONDS = 15
# Pushover's own caps, spelled exactly as services/dozzle/alert_relay.py and
# scripts/production_auto_deploy.py spell them; tests/policy_test.rb holds the
# copies identical. Over any of them is a 4xx and a lost message.
MAX_ESCAPED_FIELD_CHARACTERS = 384
MAX_MESSAGE_CHARACTERS = 1024
MAX_TITLE_CHARACTERS = 250
# A reclaim is a record worth a week on the Containers app and no longer.
RECLAIMED_TTL_SECONDS = 7 * 24 * 60 * 60
# The palette scripts/production_auto_deploy.py documents, spelled as it spells
# it; tests/policy_test.rb holds the copies identical.
COLOR_GREEN = "#2e7d32"
COLOR_RED = "#c62828"
COLOR_AMBER = "#f9a825"
COLOR_GREY = "#9e9e9e"


class ConfigurationError(ValueError):
    """The on-disk configuration cannot be trusted to drive a prune."""


class PruneError(RuntimeError):
    """Docker could not be asked to remove images."""


@dataclass(frozen=True)
class Config:
    state_root: Path
    log_root: Path
    # The poller's own lock. Held for the whole prune so a deployment can never
    # be pulling an image while its layers are being removed underneath it.
    deployment_lock: Path
    deployment_lock_wait_seconds: int
    retention_hours: int
    dangling_retention_hours: int
    log_retention_days: int
    # Discovered by the installer. NAS firmwares scatter binaries across
    # /usr/local, /usr/builtin and /opt, so no fixed directory is correct.
    docker_path: Path
    curl_path: Path
    tool_path: str
    # The protected curl config of each Pushover application the prune sends to
    # (#558): Alerts for a failure, Containers for a reclaim -- Deployments is
    # reserved for the one message per release. None means that
    # application cannot be published to; see load_config.
    pushover_alerts_curl_config: Path | None = None
    pushover_containers_curl_config: Path | None = None


_PATH_FIELDS = frozenset(
    {
        "state_root",
        "log_root",
        "deployment_lock",
        "docker_path",
        "curl_path",
    }
)
_PUSHOVER_FIELDS = frozenset(
    {"pushover_alerts_curl_config", "pushover_containers_curl_config", "pushover_deployments_curl_config"}
)
_COUNT_FIELDS = {
    "retention_hours": MINIMUM_RETENTION_HOURS,
    "dangling_retention_hours": 1,
    "log_retention_days": 1,
    "deployment_lock_wait_seconds": 0,
}


def load_config(path: str | os.PathLike[str]) -> Config:
    """Read the non-secret prune configuration written by the installer role."""

    try:
        payload = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, UnicodeError, ValueError) as error:
        raise ConfigurationError("configuration is unreadable") from error
    if not isinstance(payload, dict):
        raise ConfigurationError("configuration is not an object")
    values: dict[str, object] = {}
    unpublishable = []
    for field in fields(Config):
        if field.name in _PUSHOVER_FIELDS:
            # Never a refusal, and checked before the non-empty and absolute
            # rules below. The install play copies this script before it renders
            # the file, so a prune started in that window, or after a failed
            # render, reads a pre-Pushover configuration naming no Pushover config.
            # Refusing it would stop the prune itself; reading it as "cannot
            # publish" costs that run's notification and one stderr line.
            raw = payload.get(field.name)
            usable = type(raw) is str and Path(raw).is_absolute()
            values[field.name] = Path(raw) if usable else None
            if not usable:
                unpublishable.append(field.name)
            continue
        if field.name not in payload:
            raise ConfigurationError(f"configuration is missing {field.name}")
        raw = payload[field.name]
        if field.name in _COUNT_FIELDS:
            floor = _COUNT_FIELDS[field.name]
            if type(raw) is not int or raw < floor:
                raise ConfigurationError(
                    f"{field.name} must be an integer of at least {floor}"
                )
            values[field.name] = raw
        elif type(raw) is not str or not raw:
            raise ConfigurationError(f"{field.name} must be a non-empty string")
        elif field.name in _PATH_FIELDS:
            candidate = Path(raw)
            if not candidate.is_absolute():
                raise ConfigurationError(f"{field.name} must be absolute")
            values[field.name] = candidate
        else:
            values[field.name] = raw
    # A dangling window wider than the unused one would claim to be the
    # narrower policy while removing nothing the other pass had not already
    # taken, so the difference between the two would stop meaning anything.
    if values["dangling_retention_hours"] > values["retention_hours"]:  # type: ignore[operator]
        raise ConfigurationError(
            "dangling_retention_hours must not exceed retention_hours"
        )
    if unpublishable:
        print(
            "image prune: nothing can be published to Pushover through "
            f"{', '.join(unpublishable)}, which the configuration does not name",
            file=sys.stderr,
        )
    return Config(**values)  # type: ignore[arg-type]


# Two passes, narrowest policy last. The first removes every image no container
# references; the second removes untagged leftovers on a shorter window,
# because nothing can name them at all. Neither can reach a volume, a network
# or a container: `docker image prune` has no argument that would.
#
# The platform forbids `build:`, so there is no build cache to prune and no
# knob pretending otherwise.
PRUNE_PASSES = (
    ("unused", ("--all",), "retention_hours"),
    ("dangling", (), "dangling_retention_hours"),
)


def prune_commands(config: Config) -> list[tuple[str, list[str]]]:
    """Build the exact argument vectors this run is allowed to execute."""

    return [
        (
            label,
            [
                str(config.docker_path),
                "image",
                "prune",
                *flags,
                "--force",
                "--filter",
                f"until={getattr(config, attribute)}h",
            ],
        )
        for label, flags, attribute in PRUNE_PASSES
    ]


def _environment(config: Config) -> dict[str, str]:
    """The narrow environment both tools run under.

    HOME is carried because the Docker CLI reads its own configuration from
    there; cron supplies no environment at all, and a Docker CLI without a home
    warns on every invocation into the prune log.
    """

    environment = {"PATH": config.tool_path, "LC_ALL": "C"}
    home = os.environ.get("HOME")
    if home:
        environment["HOME"] = home
    return environment


def _run(
    arguments: list[str], *, timeout: float, config: Config
) -> subprocess.CompletedProcess:
    """Run one command with a narrow environment and a wall-clock deadline."""

    return subprocess.run(
        arguments,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        timeout=timeout,
        env=_environment(config),
        check=False,
    )


def parse_reclaimed(output: str) -> int:
    """Read the reclaimed byte count out of one prune pass's own report."""

    total = 0
    for amount, unit in RECLAIMED_PATTERN.findall(output):
        multiplier = BYTE_UNITS.get(unit.lower())
        if multiplier is None:
            continue
        total += int(float(amount) * multiplier)
    return total


def count_removed(output: str) -> int:
    """Count the images one prune pass actually deleted, not the tags it dropped."""

    return len(DELETED_PATTERN.findall(output))


def format_bytes(count: int) -> str:
    """Render a byte count the way Docker reports it, so the two agree."""

    if count < 1000:
        return f"{count} B"
    size = float(count)
    for unit in ("kB", "MB", "GB", "TB"):
        size /= 1000
        if size < 1000:
            return f"{size:.1f} {unit}"
    return f"{size:.1f} PB"


def format_duration(seconds: int) -> str:
    """Render an elapsed prune, which is minutes at worst."""

    if seconds < 0:
        return "unknown"
    minutes, seconds = divmod(seconds, 60)
    hours, minutes = divmod(minutes, 60)
    if hours:
        return f"{hours}h {minutes}m {seconds}s"
    if minutes:
        return f"{minutes}m {seconds}s"
    return f"{seconds}s"


def html_escape(value: str, maximum: int = 128, escaped_maximum: int = MAX_ESCAPED_FIELD_CHARACTERS) -> str:
    """Bound one value, then make it inert markup for Pushover's html=1.

    Identical to the copy in the other script by construction, and
    tests/policy_test.rb compares the two definitions as text so it stays that
    way (#423). Prose true of only one script goes in a comment above the def,
    which that comparison does not read. services/dozzle/alert_relay.py carries
    a relative of it, unannotated, which is left alone.

    Cut first and escape after: escaping first and cutting afterwards can split
    `&amp;` and leave a dangling entity. The second bound is on the result, and
    it drops whole input characters rather than cutting the escaped text, for
    the same reason -- `'` renders as `&#x27;`, so escaping expands.
    """

    bounded = value[:maximum]
    escaped = html.escape(bounded, quote=True)
    while bounded and len(escaped) > escaped_maximum:
        bounded = bounded[:-1]
        escaped = html.escape(bounded, quote=True)
    return escaped


def fit_message(lines) -> str:
    """Join message lines, dropping whole lines from the end until Pushover takes it.

    Identical to the copies in the other two programs by construction, and
    tests/policy_test.rb compares the definitions as text so it stays that way
    (#423). Prose true of only one program goes in a comment above the def,
    which that comparison does not read.

    Whole lines where it can, because every line is HTML and a cut can split an
    entity or a tag. A message over MAX_MESSAGE_CHARACTERS is refused outright,
    and so is an empty one -- which Pushover would blame on the token -- so a
    first line that does not fit on its own is cut instead: back past any
    partial tag or entity at the cut, and before any tag the cut left unclosed,
    with a marker, and never to nothing when there was something to send.
    """

    kept = list(lines)
    while len(kept) > 1 and len("\n".join(kept)) > MAX_MESSAGE_CHARACTERS:
        kept.pop()
    message = "\n".join(kept)
    if len(message) <= MAX_MESSAGE_CHARACTERS:
        return message
    cut = message[: MAX_MESSAGE_CHARACTERS - 1]
    cut = re.sub(r"<[^>]*\Z", "", cut)
    cut = re.sub(r"&[^;<>\s]*\Z", "", cut)
    unclosed = [
        opening
        for opening in re.finditer(r"<(b|i|u|a|font)\b[^>]*>", cut)
        if f"</{opening.group(1)}>" not in cut[opening.end():]
    ]
    if unclosed:
        cut = cut[: unclosed[0].start()]
    return f"{cut}\u2026"


def compose_message(lead: str, details, closing: str = "") -> str:
    """One message in the platform's shape: a lead line, labelled details, what next.

    Identical to the copies in the other two programs by construction, and
    tests/policy_test.rb compares the definitions as text so it stays that way
    (#423). Prose true of only one program goes in a comment above the def,
    which that comparison does not read.

    The lead says what happened with its state coloured; each detail is one
    `emoji <b>Label</b> value` fact; the closing, in italics, says what happens
    next. Blank lines separate the three. Over MAX_MESSAGE_CHARACTERS the details
    give way from the last, so the lead and the closing survive wherever they
    can, and fit_message is the backstop for a lead that cannot fit on its own.
    """

    details = list(details)
    while True:
        lines = [lead]
        if details:
            lines += ["", *details]
        if closing:
            lines += ["", closing]
        if not details or len("\n".join(lines)) <= MAX_MESSAGE_CHARACTERS:
            return fit_message(lines)
        details.pop()


def pushover_verdict(returncode: int, output: bytes) -> str:
    """Read one curl --write-out '\\n%{http_code}' run as accepted, refused or unanswered.

    Identical to the copy in the other script by construction, and
    tests/policy_test.rb compares the two definitions as text so it stays that
    way (#423). Prose true of only one script goes in a comment above the def,
    which that comparison does not read.

    The same verdict as roles/deployment_bundle/tasks/pushover_publish.yml (#598): 200 with
    an integer status of 1 is accepted, a 4xx other than 429 with an integer
    status of 0 is refused, and everything else -- no answer, a proxy's page, a
    quota 429, a status of "0" or true -- is unanswered, which is not a refusal.
    The code is read from the end of the output because curl's diagnostics can
    precede it on the same stream.
    """

    if returncode != 0:
        return "unanswered"
    body, _separator, code = output.rpartition(b"\n")
    try:
        status = int(code.decode("ascii"))
        answer = json.loads(body.decode("utf-8")).get("status")
    except (AttributeError, UnicodeError, ValueError, RecursionError):
        return "unanswered"
    if type(answer) is not int:
        return "unanswered"
    if status == 200 and answer == 1:
        return "accepted"
    if 400 <= status <= 499 and status != 429 and answer == 0:
        return "refused"
    return "unanswered"


def _timestamp(now: datetime | None = None) -> str:
    """Render a moment as the second-resolution UTC stamp both scripts write.

    Identical to the copy in the other script by construction, and
    tests/policy_test.rb compares the two definitions as text so it stays that
    way (#423). Prose true of only one script goes in a comment above the def,
    which that comparison does not read.
    """

    moment = datetime.now(timezone.utc) if now is None else now
    return moment.strftime("%Y-%m-%dT%H:%M:%SZ")


def _write_private(path: Path, payload: bytes) -> None:
    """Replace path's contents atomically, at mode 0600.

    Identical to the copy in the other script by construction, and
    tests/policy_test.rb compares the two definitions so it stays that way.
    They diverged once, in opposite directions -- one fsynced and never
    repaired the mode, the other repaired the mode and never fsynced -- so each
    carried the bug the other had fixed (#354).

    Both copies also truncated in place, and that is what made this state
    losable: a crash between the O_TRUNC and the fsync leaves an empty file,
    and an empty blind-polls count reads as zero while the blind-alarm marker
    beside it persists, which suppresses the next alarm for the rest of the
    outage (#401). Writing a temporary file and renaming it means a reader sees
    either the whole previous payload or the whole new one, never nothing.

    os.replace installs a new inode, so a target that already existed with a
    looser mode is repaired by the rename itself -- os.open's mode argument
    applies only when it creates the file, which is why the mode needed
    repairing at all, and a separate chmod would be one more step a crash could
    land between. fchmod sets 0600 on the temporary file explicitly because
    mkstemp's own mode is subject to the umask, which can clear bits from it.
    The directory is fsynced after the rename so the replacement survives a
    power loss rather than only a crash.
    """

    directory = path.parent
    descriptor, temporary = tempfile.mkstemp(dir=directory, prefix=f".{path.name}.")
    try:
        with os.fdopen(descriptor, "wb") as handle:
            os.fchmod(handle.fileno(), 0o600)
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    except BaseException:
        with contextlib.suppress(OSError):
            os.unlink(temporary)
        raise
    directory_descriptor = os.open(directory, os.O_RDONLY)
    try:
        os.fsync(directory_descriptor)
    finally:
        os.close(directory_descriptor)


# Why the prune is a second writer of the poller's record rather than leaving
# the field to it: roles/deployment_bundle probes this file at the first task of
# every role, and a holder it cannot identify is one it will not refuse. Left
# unwritten, "no record" would mean either a prune or a poller too old to write
# one, and a converge would race a prune every Sunday to keep the upgrade window
# open. Written by the prune too, "no record" means exactly the pre-upgrade
# poller and nothing else. That is this script's own reasoning, so it sits above
# the definition, where the identity comparison below does not read it.
def _record_lock_holder(descriptor: int, holder: str) -> None:
    """Write who holds the lock, for a refused caller to name.

    Identical to the copy in the other script by construction, and
    tests/policy_test.rb compares the two definitions as text so it stays that
    way (#423). Prose true of only one script goes in a comment above the def,
    which that comparison does not read.

    Best effort and advisory. The flock is the liveness truth -- a crashed
    holder leaves this record behind, and a reader that finds the lock free must
    ignore whatever it says. Written with pwrite after truncating so no reader
    can observe a half-replaced record at offset zero, and the payload is ASCII
    because roles/deployment_bundle decodes it as ASCII.
    """

    payload = json.dumps(
        {"pid": os.getpid(), "holder": holder, "started": _timestamp()},
        sort_keys=True,
    )
    with contextlib.suppress(OSError):
        os.ftruncate(descriptor, 0)
        os.pwrite(descriptor, payload.encode("ascii") + b"\n", 0)


@contextmanager
def deployment_lock(config: Config) -> Iterator[bool]:
    """Hold the poller's deployment lock; yield False when a deployment has it.

    Taking the deploying process's own lock is what makes a scheduled prune
    safe: between pulling an image and starting its container there is a window
    where the new image is referenced by nothing, and an age filter does not
    close it because the image was created upstream long before it was pulled.
    """

    descriptor = os.open(config.deployment_lock, os.O_WRONLY | os.O_CREAT, 0o600)
    deadline = time.monotonic() + config.deployment_lock_wait_seconds
    try:
        while True:
            try:
                fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except OSError:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    yield False
                    return
                time.sleep(min(LOCK_POLL_SECONDS, remaining))
                continue
            break
        _record_lock_holder(descriptor, "image prune")
        try:
            yield True
        finally:
            # Cleared while the lock is still held, exactly as the poller
            # clears its own, so nothing reads this prune's record from under
            # a lock it no longer holds.
            with contextlib.suppress(OSError):
                os.ftruncate(descriptor, 0)
    finally:
        os.close(descriptor)


@contextmanager
def prune_log(config: Config):
    """Open one private prune log and point 'latest' at it."""

    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    path = config.log_root / f"{stamp}-prune"
    os.close(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600))
    os.chmod(path, 0o600)
    with path.open("wb") as sink:
        link = config.log_root / "latest"
        with contextlib.suppress(OSError):
            link.unlink()
        with contextlib.suppress(OSError):
            link.symlink_to(path.name)
        try:
            yield sink
        finally:
            sink.flush()


def rotate_logs(config: Config, now: datetime) -> None:
    """Delete prune logs older than the configured retention window."""

    cutoff = now - timedelta(days=config.log_retention_days)
    try:
        entries = list(config.log_root.iterdir())
    except OSError:
        return
    for entry in entries:
        match = PRUNE_LOG_PATTERN.fullmatch(entry.name)
        if match is None:
            continue
        try:
            stamped = datetime.strptime(match.group(1), "%Y%m%dT%H%M%SZ").replace(
                tzinfo=timezone.utc
            )
        except ValueError:
            continue
        if stamped < cutoff:
            with contextlib.suppress(OSError):
                entry.unlink()


def count_images(config: Config) -> int | None:
    """Count the images left on the host, or None when Docker cannot say."""

    try:
        result = _run(
            [str(config.docker_path), "image", "ls", "--all", "--format", "{{.ID}}"],
            timeout=INVENTORY_TIMEOUT_SECONDS,
            config=config,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if result.returncode != 0:
        return None
    identifiers = {
        line.strip()
        for line in result.stdout.decode("utf-8", "replace").splitlines()
        if line.strip()
    }
    return len(identifiers)


def _state_path(config: Config) -> Path:
    return config.state_root / "last-prune"


def read_state(config: Config) -> dict | None:
    """The recorded outcome of the last prune, or None when there is none."""

    try:
        payload = json.loads(_state_path(config).read_text(encoding="utf-8"))
    except (OSError, UnicodeError, ValueError):
        return None
    return payload if isinstance(payload, dict) else None


def record_state(config: Config, state: dict) -> None:
    """Record one prune outcome privately, so --status can report it later."""

    _write_private(
        _state_path(config),
        json.dumps(state, ensure_ascii=False, sort_keys=True).encode("utf-8"),
    )


OUTCOMES = {
    # Pushover application, title, priority. A prune that reclaimed nothing is
    # not in here on purpose: a weekly no-op notification is noise, and the
    # weeks that reclaim nothing are most of them.
    "reclaimed": ("containers", "\U0001f9f9 Images pruned", -1),
    "failed": ("alerts", "\U0001f534 Image prune failed", 1),
}


def _images(count: int) -> str:
    return f"{count} image" if count == 1 else f"{count} images"


def render_notification(config: Config, outcome: str, summary: dict) -> tuple[str, dict]:
    """Build the Pushover application and fields for one prune outcome."""

    try:
        app, title, priority = OUTCOMES[outcome]
    except KeyError:
        raise ValueError(f"unknown prune outcome: {outcome}") from None
    took = f"⏱️ <b>Took</b> {format_duration(int(summary.get('seconds', 0)))}"
    log = f'\U0001f4c4 <b>Log</b> <font color="{COLOR_GREY}">{html_escape(str(summary.get("log", "")))}</font>'
    window = (
        f'\U0001f5d3️ <b>Window</b> <font color="{COLOR_GREY}">unused older than '
        f"{config.retention_hours}h · dangling older than {config.dangling_retention_hours}h</font>"
    )
    if outcome == "failed":
        lead = f'<b>Image prune</b> <font color="{COLOR_RED}">failed</font>'
        details = [
            f'❓ <b>Reason</b> <font color="{COLOR_RED}">{html_escape(str(summary.get("reason", "?")))}</font>',
            f"\U0001f9f9 <b>Pass</b> {html_escape(str(summary.get('pass', '?')))}",
            took,
            log,
            window,
        ]
        # The prune is scheduled, never retried by hand, and a failure changes
        # nothing about the next run: it finds the same images, one week older.
        closing = "<i>The next scheduled prune tries again.</i>"
    else:
        size = format_bytes(summary["reclaimed_bytes"])
        lead = f'<b>Unused images</b> <font color="{COLOR_GREEN}">pruned</font>'
        details = [
            f'\U0001f4be <b>Reclaimed</b> <font color="{COLOR_GREEN}">{size}</font>',
            f"\U0001f5d1️ <b>Removed</b> {_images(summary['images_removed'])}",
        ]
        if summary.get("images_remaining") is not None:
            details.append(f"\U0001f4da <b>Remaining</b> {_images(summary['images_remaining'])}")
        details += [took, window, log]
        closing = ""
    # A lock screen shows the title and little else, so the reclaimed size is
    # the one number worth putting there. A failure says so in the title
    # already and does not need it said twice.
    headline = (
        f"{title} · {format_bytes(summary['reclaimed_bytes'])}"
        if outcome == "reclaimed"
        else title
    )
    fields = {"title": headline, "message": compose_message(lead, details, closing), "priority": priority}
    if outcome == "reclaimed":
        # A ttl is never sent with priority 2, which none of these is.
        fields["ttl"] = RECLAIMED_TTL_SECONDS
    return app, fields


def publish(config: Config, app: str, fields: dict) -> bool:
    """Send one message to a Pushover application; True only if Pushover accepted it.

    The token and the user key live only in that application's protected curl
    config, so argv holds nothing but the message, and every field goes as
    --form-string, which never reads a leading @ or < as a file. A refusal names
    the vault keys to fix and never a value, and nothing here raises.
    """

    # An application this script configures no curl config for reads as cannot
    # publish, like an unconfigured one, rather than raising.
    curl_config = getattr(config, f"pushover_{app}_curl_config", None)
    if curl_config is None:
        return False
    form = dict(fields, html="1")
    form["title"] = str(form["title"])[:MAX_TITLE_CHARACTERS]
    arguments = [
        str(config.curl_path),
        "--disable",
        "--silent",
        "--show-error",
        "--max-time",
        "10",
        "--config",
        str(curl_config),
    ]
    for key, value in form.items():
        arguments += ["--form-string", f"{key}={value}"]
    arguments += ["--write-out", "\n%{http_code}"]
    try:
        result = _run(arguments, timeout=NOTIFICATION_TIMEOUT_SECONDS, config=config)
    except (OSError, ValueError, subprocess.SubprocessError):
        # ValueError is a NUL byte in a field, which no argv can carry: nothing
        # was sent, and a notice that cannot be sent must not raise either.
        return False
    verdict = pushover_verdict(result.returncode, result.stdout)
    if verdict == "refused":
        print(
            f"image prune: Pushover refused a message to the {app} application; "
            f"check vault_pushover_{app}_token and vault_pushover_user_key. "
            "Values are not shown.",
            file=sys.stderr,
        )
    elif result.returncode == 0 and result.stdout.rpartition(b"\n")[2].strip() == b"429":
        print(
            f"image prune: Pushover rate-limited a message to the {app} application "
            "(HTTP 429: its quota is spent).",
            file=sys.stderr,
        )
    return verdict == "accepted"


def notify(config: Config, outcome: str, summary: dict) -> bool:
    """Publish a secret-free prune outcome to its Pushover application."""

    return publish(config, *render_notification(config, outcome, summary))


def run_passes(config: Config, log) -> tuple[int, int]:
    """Run every prune pass in order, returning reclaimed bytes and image count.

    A pass that cannot run, or that Docker fails, raises rather than being
    counted as a clean zero: a prune that silently stopped working looks
    exactly like a week with nothing to reclaim.
    """

    reclaimed = 0
    removed = 0
    for label, arguments in prune_commands(config):
        log.write(f"$ {' '.join(arguments)}\n".encode("utf-8"))
        try:
            result = _run(arguments, timeout=PRUNE_TIMEOUT_SECONDS, config=config)
        except subprocess.TimeoutExpired as error:
            raise PruneError(f"{label} pass timed out") from error
        except (OSError, subprocess.SubprocessError) as error:
            raise PruneError(f"{label} pass could not run") from error
        output = result.stdout.decode("utf-8", "replace")
        log.write(output.encode("utf-8"))
        if result.returncode != 0:
            raise PruneError(f"{label} pass exited {result.returncode}")
        reclaimed += parse_reclaimed(output)
        removed += count_removed(output)
    return reclaimed, removed


def prune(config: Config) -> bool:
    """Run one scheduled prune. False means it failed; True means it is done."""

    with deployment_lock(config) as acquired:
        if not acquired:
            # A deployment is running. Skipping is the whole point of asking:
            # the next scheduled prune finds the same images, one week older.
            record_state(
                config,
                {
                    "finished": _timestamp(),
                    "outcome": "skipped",
                    "reason": "a deployment held the lock",
                },
            )
            print("image prune: skipped, a deployment is running")
            return True
        rotate_logs(config, datetime.now(timezone.utc))
        started = time.monotonic()
        with prune_log(config) as log:
            summary: dict = {"log": log.name}
            try:
                reclaimed, removed = run_passes(config, log)
            except PruneError as error:
                summary |= {
                    "finished": _timestamp(),
                    "outcome": "failed",
                    "reason": str(error),
                    "pass": str(error).split(" ", 1)[0],
                    "seconds": int(time.monotonic() - started),
                }
                record_state(config, summary)
                if not notify(config, "failed", summary):
                    warning = "image prune: outcome notification failed"
                    log.write(warning.encode("ascii") + b"\n")
                    print(warning, file=sys.stderr)
                return False
            summary |= {
                "finished": _timestamp(),
                "outcome": "reclaimed" if reclaimed or removed else "nothing",
                "reclaimed_bytes": reclaimed,
                "images_removed": removed,
                "images_remaining": count_images(config),
                "seconds": int(time.monotonic() - started),
            }
            record_state(config, summary)
            log.write(
                f"reclaimed {format_bytes(reclaimed)} from {removed} images\n".encode(
                    "utf-8"
                )
            )
            if summary["outcome"] == "reclaimed" and not notify(
                config, "reclaimed", summary
            ):
                warning = "image prune: outcome notification failed"
                log.write(warning.encode("ascii") + b"\n")
                print(warning, file=sys.stderr)
        return True


def print_status(config: Config) -> None:
    """Print what the last prune did and the policy the next one will apply."""

    state = read_state(config)
    if state is None:
        print("last prune: none")
    elif state.get("outcome") == "failed":
        print(f"last prune: {state.get('finished', 'unknown')} failed: "
              f"{state.get('reason', 'unknown reason')}")
    elif state.get("outcome") == "skipped":
        print(f"last prune: {state.get('finished', 'unknown')} skipped: "
              f"{state.get('reason', 'unknown reason')}")
    else:
        print(
            f"last prune: {state.get('finished', 'unknown')} reclaimed "
            f"{format_bytes(int(state.get('reclaimed_bytes', 0)))} from "
            f"{state.get('images_removed', 0)} images"
        )
        remaining = state.get("images_remaining")
        if remaining is not None:
            print(f"images remaining: {remaining}")
    print(f"unused retention: {config.retention_hours}h")
    print(f"dangling retention: {config.dangling_retention_hours}h")
    if state is not None and state.get("log"):
        print(f"log: {state['log']}")


def _parse_arguments(argv):
    config_path = None
    mode = None
    remaining = list(argv)
    while remaining:
        argument = remaining.pop(0)
        if argument == "--config" and remaining and config_path is None:
            config_path = remaining.pop(0)
        elif argument == "--prune" and mode is None:
            mode = "prune"
        elif argument == "--status" and mode is None:
            mode = "status"
        else:
            return None
    if config_path is None or mode is None:
        return None
    return config_path, mode


def main(argv=None) -> int:
    """Run one explicit image prune mode."""

    parsed = _parse_arguments(list(sys.argv[1:] if argv is None else argv))
    if parsed is None:
        print("image prune: invalid arguments", file=sys.stderr)
        return 2
    config_path, mode = parsed
    try:
        config = load_config(config_path)
    except ConfigurationError:
        # The notifier's paths live in this file, so an unusable configuration
        # cannot be reported through Pushover.
        print("image prune: unusable configuration", file=sys.stderr)
        return 1
    if mode == "status":
        print_status(config)
        return 0
    try:
        succeeded = prune(config)
    except OSError as error:
        # A private directory the installer owns is missing or unwritable.
        # Cron keeps only the most recent output, so this has to read as a
        # sentence rather than as a traceback a week after the fact.
        print(f"image prune: {error.filename or 'a managed path'} is unusable",
              file=sys.stderr)
        return 1
    if not succeeded:
        print("image prune: failed", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
