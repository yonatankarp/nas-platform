#!/usr/bin/env python3
"""Deploy the current main revision on the NAS once its CI run is green."""

from __future__ import annotations

import contextlib
from contextlib import contextmanager
from dataclasses import dataclass, fields
from datetime import datetime, timedelta, timezone
import fcntl
from http.client import HTTPException
import json
import os
from pathlib import Path
import re
import selectors
import signal
import subprocess
import sys
import time
from typing import Iterator
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode, urlsplit
from urllib.request import Request, urlopen

SHA_PATTERN = re.compile(r"[0-9a-f]{40}")
ATTEMPT_LOG_PATTERN = re.compile(r"(\d{8}T\d{6}Z)-[0-9a-f]{40}")
TIMESTAMP_PATTERN = re.compile(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z")
# Bounds the attempted record. The count is the hard cap; the window keeps it
# from carrying revisions nobody remembers.
ATTEMPTED_RETENTION_COUNT = 50
ATTEMPTED_RETENTION_DAYS = 90
MAX_RESPONSE_BYTES = 1024 * 1024
READ_SIZE = 64 * 1024
NETWORK_TIMEOUT_SECONDS = 10
GIT_TIMEOUT_SECONDS = 10
NOTIFICATION_TIMEOUT_SECONDS = 10
COMMAND_TIMEOUT_SECONDS = 60 * 60
TOOLING_TIMEOUT_SECONDS = 15 * 60


class ConfigurationError(ValueError):
    """The on-disk configuration cannot be trusted to drive a deployment."""


class EligibilityError(RuntimeError):
    """No candidate revision could be established for this poll."""


class DeploymentError(RuntimeError):
    """The candidate revision could not be deployed."""


@dataclass(frozen=True)
class Config:
    repository: str
    repository_url: str
    workflow: str
    workflow_name: str
    branch: str
    checkout: Path
    state_root: Path
    log_root: Path
    vault_file: Path
    vault_password_file: Path
    ntfy_curl_config: Path
    platform_nas_address: str
    platform_public_host: str
    platform_callback_host: str
    github_api_base: str
    log_retention_days: int
    verify_tags: str
    # Discovered by the installer. NAS firmwares scatter binaries across
    # /usr/local, /usr/builtin and /opt, so no fixed directory is correct.
    git_path: Path
    curl_path: Path
    tool_path: str
    # Ansible refuses to run unless locale.getlocale() reports UTF-8, and cron
    # supplies no locale at all. Which UTF-8 locale exists varies by firmware,
    # so the installer discovers a working one rather than assuming.
    ansible_locale: str


_PATH_FIELDS = frozenset(
    {
        "checkout",
        "state_root",
        "log_root",
        "vault_file",
        "vault_password_file",
        "ntfy_curl_config",
        "git_path",
        "curl_path",
    }
)


def load_config(path: str | os.PathLike[str]) -> Config:
    """Read the non-secret poller configuration written by the installer role."""

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
        if field.name == "log_retention_days":
            if type(raw) is not int or raw < 1:
                raise ConfigurationError(
                    "log_retention_days must be a positive integer"
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
    for url_field in ("repository_url", "github_api_base"):
        if urlsplit(str(values[url_field])).scheme != "https":
            raise ConfigurationError(f"{url_field} must be https")
    return Config(**values)  # type: ignore[arg-type]


def _run(
    arguments,
    *,
    timeout: float,
    cwd: Path | None = None,
    env: dict[str, str] | None = None,
    log=None,
) -> subprocess.CompletedProcess:
    """Run one command, streaming output, under a real wall-clock deadline.

    The deadline has to cover the read loop, not just the final wait: a child
    that spawns its own children leaves the inherited stdout pipe open, so
    reading to EOF can outlive the timeout by however long the grandchild runs.
    """

    deadline = time.monotonic() + timeout
    process = subprocess.Popen(
        [str(argument) for argument in arguments],
        cwd=None if cwd is None else str(cwd),
        env=env,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        start_new_session=True,
    )
    collected = bytearray()
    timed_out = False
    assert process.stdout is not None
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    try:
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                timed_out = True
                break
            if not selector.select(remaining):
                continue
            chunk = process.stdout.read1(READ_SIZE)
            if not chunk:
                break
            collected += chunk
            if log is not None:
                log.write(chunk)
        if not timed_out:
            try:
                process.wait(timeout=max(0.0, deadline - time.monotonic()))
            except subprocess.TimeoutExpired:
                timed_out = True
    finally:
        selector.close()
        if timed_out:
            with contextlib.suppress(ProcessLookupError, PermissionError):
                os.killpg(os.getpgid(process.pid), signal.SIGKILL)
            process.wait()
        process.stdout.close()
    if timed_out:
        raise subprocess.TimeoutExpired(arguments, timeout, bytes(collected))
    return subprocess.CompletedProcess(
        arguments, process.returncode, bytes(collected), b""
    )


def resolve_main_sha(config: Config) -> str:
    """Resolve the exact production branch SHA over anonymous HTTPS git."""

    try:
        result = _run(
            [
                config.git_path,
                "ls-remote",
                "--exit-code",
                config.repository_url,
                f"refs/heads/{config.branch}",
            ],
            timeout=GIT_TIMEOUT_SECONDS,
            env={"PATH": config.tool_path, "LC_ALL": "C", "GIT_TERMINAL_PROMPT": "0"},
        )
    except (OSError, subprocess.SubprocessError) as error:
        raise EligibilityError("git query failed") from error
    if result.returncode != 0 or len(result.stdout) > MAX_RESPONSE_BYTES:
        raise EligibilityError("git query failed")
    lines = result.stdout.decode("ascii", "replace").splitlines()
    if len(lines) != 1:
        raise EligibilityError("git response is invalid")
    parts = lines[0].split("\t")
    if (
        len(parts) != 2
        or SHA_PATTERN.fullmatch(parts[0]) is None
        or parts[1] != f"refs/heads/{config.branch}"
    ):
        raise EligibilityError("git response is invalid")
    return parts[0]


def fetch_ci_runs(config: Config, sha: str) -> tuple[dict, ...]:
    """Fetch one bounded page of completed push runs for the exact SHA."""

    if SHA_PATTERN.fullmatch(sha) is None:
        raise EligibilityError("candidate SHA is invalid")
    query = urlencode(
        {
            "branch": config.branch,
            "event": "push",
            "status": "completed",
            "head_sha": sha,
            "per_page": "10",
        }
    )
    url = (
        f"{config.github_api_base.rstrip('/')}/repos/{config.repository}"
        f"/actions/workflows/{config.workflow}/runs?{query}"
    )
    request = Request(
        url,
        method="GET",
        headers={
            "Accept": "application/vnd.github+json",
            "User-Agent": "nas-platform-production-auto-deploy",
            "X-GitHub-Api-Version": "2022-11-28",
        },
    )
    try:
        with urlopen(request, timeout=NETWORK_TIMEOUT_SECONDS) as response:
            body = response.read(MAX_RESPONSE_BYTES + 1)
    except (HTTPError, URLError, HTTPException, OSError, TimeoutError) as error:
        raise EligibilityError("GitHub request failed") from error
    if len(body) > MAX_RESPONSE_BYTES:
        raise EligibilityError("GitHub response is too large")
    try:
        payload = json.loads(body.decode("utf-8"))
        runs = payload["workflow_runs"]
    except (KeyError, TypeError, UnicodeError, ValueError) as error:
        raise EligibilityError("GitHub response is invalid") from error
    if not isinstance(runs, list):
        raise EligibilityError("GitHub response is invalid")
    return tuple(run for run in runs if isinstance(run, dict))


def is_ci_green(config: Config, sha: str, runs) -> bool:
    """Accept exactly one completed successful push run of the CI workflow."""

    matching = [
        run
        for run in runs
        if run.get("head_sha") == sha
        and run.get("status") == "completed"
        and run.get("conclusion") == "success"
        and run.get("event") == "push"
        and run.get("head_branch") == config.branch
        and run.get("name") == config.workflow_name
    ]
    return len(matching) == 1


def _write_private(path: Path, payload: bytes) -> None:
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(descriptor, "wb") as handle:
        handle.write(payload)
        handle.flush()
        os.fsync(handle.fileno())


def _attempted_path(config: Config) -> Path:
    return config.state_root / "attempted"


def _read_attempts(config: Config) -> list[tuple[str, str | None]]:
    """Every recorded attempt in the order it was made, oldest first.

    Lines are "<sha> <timestamp>". A bare SHA is accepted so a record written by
    an older poller still parses; it sorts as unknown-age and is pruned first.
    """

    try:
        payload = _attempted_path(config).read_text(encoding="ascii")
    except (OSError, UnicodeError):
        return []
    attempts: list[tuple[str, str | None]] = []
    seen: set[str] = set()
    for line in payload.splitlines():
        parts = line.split()
        if not parts or SHA_PATTERN.fullmatch(parts[0]) is None:
            continue
        sha = parts[0]
        if sha in seen:
            continue
        seen.add(sha)
        stamp = parts[1] if len(parts) > 1 and TIMESTAMP_PATTERN.fullmatch(parts[1]) else None
        attempts.append((sha, stamp))
    return attempts


def _prune_attempts(
    attempts: list[tuple[str, str | None]],
    now: datetime,
) -> list[tuple[str, str | None]]:
    """Bound the record by count and by age.

    An entry survives while it is inside the newest ATTEMPTED_RETENTION_COUNT and
    inside the retention window. The caller always appends the current attempt
    before pruning, so the just-recorded revision is inherently retained: that is
    what stops a failed revision from being attempted again on the next tick.
    """

    if not attempts:
        return []
    cutoff = now - timedelta(days=ATTEMPTED_RETENTION_DAYS)
    recent = attempts[-ATTEMPTED_RETENTION_COUNT:]
    kept: list[tuple[str, str | None]] = []
    for sha, stamp in recent:
        if stamp is None:
            continue
        try:
            stamped = datetime.strptime(stamp, "%Y-%m-%dT%H:%M:%SZ").replace(
                tzinfo=timezone.utc
            )
        except ValueError:
            continue
        if stamped >= cutoff:
            kept.append((sha, stamp))
    return kept


def _store_attempts(config: Config, attempts: list[tuple[str, str | None]]) -> None:
    payload = "".join(
        f"{sha} {stamp}\n" if stamp else f"{sha}\n" for sha, stamp in attempts
    )
    _write_private(_attempted_path(config), payload.encode("ascii"))


def attempted_shas(config: Config) -> set[str]:
    """Every revision this poller has already tried, successfully or not."""

    return {sha for sha, _stamp in _read_attempts(config)}


def record_attempt(config: Config, sha: str, now: datetime | None = None) -> None:
    """Record the attempt before deploying, so a crash cannot cause a retry loop."""

    moment = datetime.now(timezone.utc) if now is None else now
    attempts = [entry for entry in _read_attempts(config) if entry[0] != sha]
    attempts.append((sha, _timestamp(moment)))
    _store_attempts(config, _prune_attempts(attempts, moment))


def forget_attempt(config: Config, sha: str) -> None:
    """Allow exactly one explicit operator retry of a previously attempted SHA."""

    _store_attempts(
        config, [entry for entry in _read_attempts(config) if entry[0] != sha]
    )


def record_success(config: Config, sha: str, timestamp: str) -> None:
    _write_private(
        config.state_root / "last-successful",
        f"{sha} {timestamp}\n".encode("ascii"),
    )


def read_state(config: Config) -> dict:
    state: dict = {"attempted": sorted(attempted_shas(config)), "last_successful": None}
    try:
        payload = (config.state_root / "last-successful").read_text(encoding="ascii")
    except (OSError, UnicodeError):
        return state
    parts = payload.split()
    if len(parts) == 2 and SHA_PATTERN.fullmatch(parts[0]):
        state["last_successful"] = {"sha": parts[0], "timestamp": parts[1]}
    return state


@contextmanager
def deployment_lock(config: Config) -> Iterator[bool]:
    """Serialise deployments; yield False when another holder already runs one."""

    descriptor = os.open(
        config.state_root / "deployment.lock", os.O_WRONLY | os.O_CREAT, 0o600
    )
    try:
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            yield False
            return
        yield True
    finally:
        os.close(descriptor)


def _tooling_bin(config: Config) -> Path:
    """The controller virtualenv the operator guide creates in the checkout."""

    return config.checkout / ".venv" / "bin"


def _collections_path(config: Config) -> Path:
    """Collections live beside the virtualenv, not under a shared HOME.

    pip installs ansible-core but not Galaxy collections, and HOME is pinned
    below, so an operator's ~/.ansible is deliberately not consulted.
    """

    return _tooling_bin(config).parent / "collections"


def _ansible_environment(config: Config) -> dict[str, str]:
    return {
        # ansible-core lives in the checkout's virtualenv, per the operator
        # guide, so the system path alone cannot find ansible-playbook.
        "PATH": f"{_tooling_bin(config)}{os.pathsep}{config.tool_path}",
        "HOME": str(config.checkout.parent),
        # Only LANG: setting LC_ALL and LANG to the same value is rejected as
        # an unsupported locale setting on some platforms.
        "LANG": config.ansible_locale,
        "GIT_TERMINAL_PROMPT": "0",
        "PLATFORM_NAS_ADDRESS": config.platform_nas_address,
        "PLATFORM_PUBLIC_HOST": config.platform_public_host,
        "PLATFORM_CALLBACK_HOST": config.platform_callback_host,
        "PLATFORM_VAULT_FILE": str(config.vault_file),
        "ANSIBLE_CONFIG": str(config.checkout / "ansible.cfg"),
        "ANSIBLE_COLLECTIONS_PATH": str(_collections_path(config)),
    }


def _vault_arguments(config: Config) -> list[str]:
    return [
        "-i",
        "inventory/local.yml",
        "--vault-password-file",
        str(config.vault_password_file),
        "-e",
        f"@{config.vault_file}",
        "-e",
        f"platform_vault_file={config.vault_file}",
    ]


def update_checkout(config: Config, sha: str) -> None:
    """Materialise the candidate revision in the controller checkout."""

    environment = {
        "PATH": config.tool_path,
        "LC_ALL": "C",
        "GIT_TERMINAL_PROMPT": "0",
    }
    for arguments in (
        [config.git_path, "fetch", "--prune", "origin", config.branch],
        [config.git_path, "checkout", "--detach", sha],
    ):
        result = _run(
            arguments,
            timeout=COMMAND_TIMEOUT_SECONDS,
            cwd=config.checkout,
            env=environment,
        )
        if result.returncode != 0:
            raise DeploymentError(f"git {arguments[1]} failed for {sha}")


def sync_tooling(config: Config, log=None) -> None:
    """Match the controller virtualenv to the candidate's own pins.

    This has to happen before any ansible process starts, which is why the
    checkout is done with git rather than ansible-pull: the tooling that would
    run ansible-pull is the very tooling being corrected.
    """

    requirements = config.checkout / "controller-requirements.txt"
    result = _run(
        [
            _tooling_bin(config) / "pip",
            "install",
            "--quiet",
            "--upgrade",
            "--requirement",
            str(requirements),
        ],
        timeout=TOOLING_TIMEOUT_SECONDS,
        cwd=config.checkout,
        env={"PATH": config.tool_path, "LC_ALL": "C"},
        log=log,
    )
    if result.returncode != 0:
        raise DeploymentError("controller tooling could not be synchronised")

    # Collections are a separate dependency set from the Python pins, and the
    # modules the playbooks call live in them.
    result = _run(
        [
            _tooling_bin(config) / "ansible-galaxy",
            "collection",
            "install",
            "--force",
            "--requirements-file",
            str(config.checkout / "requirements.yml"),
            "--collections-path",
            str(_collections_path(config)),
        ],
        timeout=TOOLING_TIMEOUT_SECONDS,
        cwd=config.checkout,
        env={
            "PATH": config.tool_path,
            "LANG": config.ansible_locale,
            "HOME": str(config.checkout.parent),
        },
        log=log,
    )
    if result.returncode != 0:
        raise DeploymentError("controller collections could not be synchronised")


def _deploy_invocations(config: Config):
    """Every play runs through ansible-playbook from the candidate checkout.

    verify.yml carries its tag list and the others must not receive it, so the
    tags belong to individual invocations rather than one shared command.
    """

    vault = _vault_arguments(config)
    return (
        ["ansible-playbook", *vault, "validate-vault.yml"],
        ["ansible-playbook", *vault, "site.yml"],
        ["ansible-playbook", *vault, "verify.yml", "--tags", config.verify_tags],
        ["ansible-playbook", *vault, "install-production-auto-deploy.yml"],
    )


def deploy(config: Config, sha: str, log) -> bool:
    """Deploy one candidate revision, stopping at the first failing play."""

    environment = _ansible_environment(config)
    try:
        update_checkout(config, sha)
        sync_tooling(config, log=log)
        for arguments in _deploy_invocations(config):
            result = _run(
                arguments,
                timeout=COMMAND_TIMEOUT_SECONDS,
                cwd=config.checkout,
                env=environment,
                log=log,
            )
            if result.returncode != 0:
                return False
    except (DeploymentError, OSError, subprocess.SubprocessError):
        return False
    return True


def _timestamp(now: datetime | None = None) -> str:
    moment = datetime.now(timezone.utc) if now is None else now
    return moment.strftime("%Y-%m-%dT%H:%M:%SZ")


@contextmanager
def attempt_log(config: Config, sha: str):
    """Open one private attempt log and point 'latest' at it."""

    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    path = config.log_root / f"{stamp}-{sha}"
    # Create privately first, then reopen by path so the sink carries a usable
    # .name for the notification payload.
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
    """Delete attempt logs older than the configured retention window."""

    cutoff = now - timedelta(days=config.log_retention_days)
    try:
        entries = list(config.log_root.iterdir())
    except OSError:
        return
    for entry in entries:
        match = ATTEMPT_LOG_PATTERN.fullmatch(entry.name)
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


def notify(
    config: Config,
    outcome: str,
    sha: str,
    started: str,
    finished: str,
    log_path: Path,
) -> bool:
    """Publish a secret-free outcome through the operator's protected curl config."""

    body = json.dumps(
        {
            "outcome": outcome,
            "sha": sha,
            "started": started,
            "finished": finished,
            "log_path": str(log_path),
        },
        separators=(",", ":"),
        sort_keys=True,
    )
    try:
        result = _run(
            [
                config.curl_path,
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
            env={"PATH": config.tool_path, "LC_ALL": "C"},
        )
    except (OSError, subprocess.SubprocessError):
        return False
    return result.returncode == 0


def poll(config: Config, retry_sha: str | None = None) -> bool | None:
    """Attempt at most one eligible revision. None means nothing was attempted."""

    if retry_sha is not None and SHA_PATTERN.fullmatch(retry_sha) is None:
        raise EligibilityError("retry SHA is invalid")
    with deployment_lock(config) as acquired:
        if not acquired:
            return None
        rotate_logs(config, datetime.now(timezone.utc))
        head = resolve_main_sha(config)
        if retry_sha is not None:
            successful = read_state(config)["last_successful"]
            if (
                head != retry_sha
                or retry_sha not in attempted_shas(config)
                or (successful is not None and successful["sha"] == retry_sha)
            ):
                return None
            forget_attempt(config, retry_sha)
        elif head in attempted_shas(config):
            return None
        if not is_ci_green(config, head, fetch_ci_runs(config, head)):
            return None

        # Recorded before the attempt: a crash mid-deploy must not become a
        # retry loop on the next five-minute tick.
        record_attempt(config, head)
        started = _timestamp()
        with attempt_log(config, head) as log:
            log_path = Path(log.name)
            succeeded = deploy(config, head, log)
            finished = _timestamp()
            if succeeded:
                record_success(config, head, finished)
            # Best effort, but never silent: a misconfigured publisher would
            # otherwise lose every outcome with nothing to show for it.
            if not notify(
                config,
                "success" if succeeded else "failed",
                head,
                started,
                finished,
                log_path,
            ):
                warning = "production auto-deploy: outcome notification failed"
                log.write(warning.encode("ascii") + b"\n")
                print(warning, file=sys.stderr)
        return succeeded


def print_status(config: Config) -> None:
    """Print the recorded, non-secret deployment state."""

    state = read_state(config)
    successful = state["last_successful"]
    if successful is None:
        print("last successful: none")
    else:
        print(f"last successful: {successful['sha']} at {successful['timestamp']}")
    attempted = state["attempted"]
    print(f"attempted revisions: {len(attempted)}")
    for sha in attempted:
        marker = " (successful)" if successful and successful["sha"] == sha else ""
        print(f"  {sha}{marker}")


def _parse_arguments(argv):
    config_path = None
    mode = None
    retry_sha = None
    remaining = list(argv)
    while remaining:
        argument = remaining.pop(0)
        if argument == "--config" and remaining and config_path is None:
            config_path = remaining.pop(0)
        elif argument == "--poll" and mode is None:
            mode = "poll"
        elif argument == "--status" and mode is None:
            mode = "status"
        elif argument == "--retry-failed" and remaining and mode is None:
            mode = "retry"
            retry_sha = remaining.pop(0)
        else:
            return None
    if config_path is None or mode is None:
        return None
    if mode == "retry" and (
        retry_sha is None or SHA_PATTERN.fullmatch(retry_sha) is None
    ):
        return None
    return config_path, mode, retry_sha


def main(argv=None) -> int:
    """Run one explicit production auto-deployment mode."""

    parsed = _parse_arguments(list(sys.argv[1:] if argv is None else argv))
    if parsed is None:
        print("production auto-deploy: invalid arguments", file=sys.stderr)
        return 2
    config_path, mode, retry_sha = parsed
    try:
        config = load_config(config_path)
        if mode == "status":
            print_status(config)
            return 0
        outcome = poll(config, retry_sha=retry_sha)
    except ConfigurationError:
        print("production auto-deploy: unusable configuration", file=sys.stderr)
        return 1
    except EligibilityError:
        print("production auto-deploy: no eligible revision", file=sys.stderr)
        return 0
    if outcome is False:
        print("production auto-deploy: attempt failed", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
