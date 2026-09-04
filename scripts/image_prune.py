#!/usr/bin/env python3
"""Reclaim disk space by removing Docker images nothing references."""

from __future__ import annotations

import contextlib
from contextlib import contextmanager
from dataclasses import dataclass, fields
from datetime import datetime, timedelta, timezone
import fcntl
import json
import os
from pathlib import Path
import re
import subprocess
import sys
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
# Mirrors scripts/production_auto_deploy.py so both publishers escape alike.
MARKDOWN_PATTERN = re.compile(r"([\\`*_{}\[\]()#+\-.!|>])")


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
    ntfy_curl_config: Path
    # Addressed in the publish body, not the URL: ntfy only parses a JSON
    # publish document when the POST goes to the server root.
    ntfy_topic_critical: str
    ntfy_topic_deployment: str
    retention_hours: int
    dangling_retention_hours: int
    log_retention_days: int
    # Discovered by the installer. NAS firmwares scatter binaries across
    # /usr/local, /usr/builtin and /opt, so no fixed directory is correct.
    docker_path: Path
    curl_path: Path
    tool_path: str


_PATH_FIELDS = frozenset(
    {
        "state_root",
        "log_root",
        "deployment_lock",
        "ntfy_curl_config",
        "docker_path",
        "curl_path",
    }
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
    for field in fields(Config):
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


def markdown_escape(value: str, maximum: int = 256) -> str:
    """Escape one value for ntfy's markdown rendering, bounded like the relay."""

    return MARKDOWN_PATTERN.sub(lambda match: f"\\{match.group(1)}", value[:maximum])


def _timestamp(now: datetime | None = None) -> str:
    moment = datetime.now(timezone.utc) if now is None else now
    return moment.strftime("%Y-%m-%dT%H:%M:%SZ")


def _write_private(path: Path, payload: bytes) -> None:
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(descriptor, "wb") as sink:
        sink.write(payload)
    os.chmod(path, 0o600)


def _record_lock_holder(descriptor: int, holder: str) -> None:
    """Write who holds the lock, for a refused deployment to name.

    Mirrors scripts/production_auto_deploy.py, whose record this is a second
    writer of: roles/deployment_bundle probes this file at the first task of
    every role, and a holder it cannot identify is one it will not refuse. Left
    unwritten, "no record" would mean either a prune or a poller too old to
    write one, and a converge would race a prune every Sunday to keep the
    upgrade window open. Written by the prune too, "no record" means exactly
    the pre-upgrade poller and nothing else.

    Best effort and advisory, like the poller's. The flock is the liveness
    truth. Written with pwrite after truncating so no reader can observe a
    half-replaced record at offset zero, and the payload is ASCII because the
    probe decodes it as ASCII.
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
    # topic attribute, title, priority, tags. A prune that reclaimed nothing is
    # not in here on purpose: a weekly no-op notification is noise, and the
    # weeks that reclaim nothing are most of them.
    "reclaimed": ("ntfy_topic_deployment", "Images pruned", 3, ("wastebasket",)),
    "failed": ("ntfy_topic_critical", "Image prune failed", 5, ("warning",)),
}


def render_notification(config: Config, outcome: str, summary: dict) -> dict:
    """Build ntfy's structured publish document for one prune outcome."""

    try:
        topic_attribute, title, priority, tags = OUTCOMES[outcome]
    except KeyError:
        raise ValueError(f"unknown prune outcome: {outcome}") from None
    lines = []
    if outcome == "failed":
        lines.append(f"**Pass:** `{markdown_escape(str(summary.get('pass', '?')))}`")
        lines.append(f"**Reason:** `{markdown_escape(str(summary.get('reason', '?')))}`")
    else:
        lines.append(f"**Reclaimed:** `{format_bytes(summary['reclaimed_bytes'])}`")
        lines.append(f"**Images removed:** `{summary['images_removed']}`")
        if summary.get("images_remaining") is not None:
            lines.append(f"**Images remaining:** `{summary['images_remaining']}`")
    lines.append(f"**Unused older than:** `{config.retention_hours}h`")
    lines.append(f"**Dangling older than:** `{config.dangling_retention_hours}h`")
    lines.append(f"**Duration:** `{format_duration(int(summary.get('seconds', 0)))}`")
    lines.append(f"**Log:** `{markdown_escape(str(summary.get('log', '')))}`")
    # A lock screen shows the title and little else, so the reclaimed size is
    # the one number worth putting there. A failure says so in the title
    # already and does not need it said twice.
    headline = (
        f"{title} · {format_bytes(summary['reclaimed_bytes'])}"
        if outcome == "reclaimed"
        else title
    )
    return {
        "topic": getattr(config, topic_attribute),
        "title": headline,
        "message": "\n".join(lines),
        "priority": priority,
        "tags": list(tags),
        "markdown": True,
    }


def publish(config: Config, notification: dict) -> bool:
    """Send one prepared ntfy document through the protected curl config."""

    body = json.dumps(notification, ensure_ascii=False, separators=(",", ":"))
    try:
        result = _run(
            [
                str(config.curl_path),
                "--disable",
                "--fail",
                "--silent",
                "--show-error",
                "--max-time",
                "10",
                "--config",
                str(config.ntfy_curl_config),
                "--data-binary",
                body,
            ],
            timeout=NOTIFICATION_TIMEOUT_SECONDS,
            config=config,
        )
    except (OSError, subprocess.SubprocessError):
        return False
    return result.returncode == 0


def notify(config: Config, outcome: str, summary: dict) -> bool:
    """Publish a secret-free prune outcome through the operator's curl config."""

    return publish(config, render_notification(config, outcome, summary))


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
        # The notifier credentials live beside this file, so an unusable
        # configuration cannot be reported through ntfy.
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
