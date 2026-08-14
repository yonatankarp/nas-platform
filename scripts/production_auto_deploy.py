#!/usr/bin/env python3
"""Fail-closed GitHub Actions eligibility gate for production deployments."""

from __future__ import annotations

from contextlib import contextmanager
from dataclasses import dataclass, fields
from datetime import datetime, timezone
import errno
import fcntl
from http.client import HTTPException
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import signal
import stat
import subprocess
import sys
import threading
import time
from typing import Any, Sequence
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode, urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener

EXPECTED_REPOSITORY = "yonatankarp/nas-platform"
EXPECTED_REPOSITORY_URL = "https://github.com/yonatankarp/nas-platform.git"
EXPECTED_WORKFLOW = "ci.yml"
EXPECTED_WORKFLOW_NAME = "CI"
EXPECTED_BRANCH = "main"
EXPECTED_NAS_ADDRESS = "192.168.0.139"
EXPECTED_GITHUB_API_BASE = "https://api.github.com"
EXPECTED_LOG_RETENTION_COUNT = 20
EXPECTED_LOG_RETENTION_DAYS = 30
DEFAULT_CONFIG_PATH = Path("/var/lib/nas-platform-auto-deploy/config.json")
MAX_RESPONSE_BYTES = 1024 * 1024
NETWORK_TIMEOUT_SECONDS = 10
GIT_TIMEOUT_SECONDS = 10
HTTP_READ_SIZE = 64 * 1024
SHA_PATTERN = re.compile(r"[0-9a-f]{40}")
TIMESTAMP_PATTERN = re.compile(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z")
LOCK_FILE_NAME = "deployment.lock"
LOCK_IDENTITY_FILE_NAME = ".deployment.lock.identity"
ATTEMPT_RESERVATION_FILE_NAME = ".deployment.attempt-reservation"
LOCK_BOOTSTRAP_ATTEMPTS = 3
STATE_ROOT_CONVERGENCE_ATTEMPTS = 3
STATE_ROOT_CONVERGENCE_DELAY_SECONDS = 0.01
STATE_MAX_BYTES = 4096


class ConfigurationError(ValueError):
    """The fixed production configuration is invalid or unsafe."""


class EligibilityError(RuntimeError):
    """The candidate's CI eligibility could not be established safely."""


class StateError(ConfigurationError):
    """Protected deployment state is absent, malformed, or unsafe."""


class HttpDeadlineExpired(TimeoutError):
    """The complete GitHub HTTP transaction exceeded its wall-clock budget."""


class RejectRedirects(HTTPRedirectHandler):
    """Disable urllib's automatic redirect handling for the GitHub API."""

    def redirect_request(
        self,
        _request,
        _file_pointer,
        _code,
        _message,
        _headers,
        _url,
    ):
        return None


_HTTP_OPENER = build_opener(RejectRedirects())


def urlopen(request: Request, *, timeout: float):
    """Open an HTTP request without following redirects."""

    return _HTTP_OPENER.open(request, timeout=timeout)


@contextmanager
def http_wall_clock_deadline(seconds: float):
    """Interrupt a complete POSIX HTTP transaction at one wall-clock deadline."""

    if threading.current_thread() is not threading.main_thread():
        raise EligibilityError("GitHub request requires the main thread")

    def expire(_signal_number, _frame):
        raise HttpDeadlineExpired("GitHub request timed out")

    started = time.monotonic()
    previous_handler = None
    try:
        active_timer = signal.getitimer(signal.ITIMER_REAL)
        timer_seconds = seconds
        if active_timer[0] > 0:
            timer_seconds = min(timer_seconds, active_timer[0])
        previous_handler = signal.signal(signal.SIGALRM, expire)
        previous_timer = signal.setitimer(signal.ITIMER_REAL, timer_seconds)
    except (AttributeError, OSError, ValueError) as error:
        if previous_handler is not None:
            signal.signal(signal.SIGALRM, previous_handler)
        raise EligibilityError("GitHub request deadline is unavailable") from error

    try:
        yield
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
        signal.signal(signal.SIGALRM, previous_handler)
        previous_delay, previous_interval = previous_timer
        if previous_delay > 0:
            elapsed = time.monotonic() - started
            signal.setitimer(
                signal.ITIMER_REAL,
                max(0.000001, previous_delay - elapsed),
                previous_interval,
            )


@dataclass(frozen=True)
class Config:
    repository: str
    repository_url: str
    workflow: str
    workflow_name: str
    branch: str
    controller_root: Path
    tooling_root: Path
    state_root: Path
    log_root: Path
    vault_file: Path
    vault_password_file: Path
    ntfy_curl_config: Path
    platform_nas_address: str
    platform_public_host: str
    platform_callback_host: str
    github_api_base: str
    log_retention_count: int
    log_retention_days: int


@dataclass(frozen=True)
class CiRun:
    head_sha: str
    status: str
    conclusion: str
    event: str
    head_branch: str
    name: str


@dataclass(frozen=True)
class ShaState:
    sha: str
    timestamp: str
    outcome: str


def _is_exact_int(value: object) -> bool:
    return type(value) is int


def _validate_repository_url(repository_url: str) -> None:
    try:
        parsed = urlsplit(repository_url)
        port = parsed.port
    except ValueError as error:
        raise ConfigurationError("invalid repository URL") from error

    if (
        repository_url != EXPECTED_REPOSITORY_URL
        or parsed.scheme != "https"
        or parsed.netloc != "github.com"
        or parsed.hostname != "github.com"
        or parsed.username is not None
        or parsed.password is not None
        or port is not None
        or parsed.path != "/yonatankarp/nas-platform.git"
        or parsed.query
        or parsed.fragment
    ):
        raise ConfigurationError("unsafe repository URL")


def _validate_api_base(api_base: str) -> None:
    try:
        parsed = urlsplit(api_base)
        port = parsed.port
    except ValueError as error:
        raise ConfigurationError("invalid GitHub API base") from error
    if (
        api_base != EXPECTED_GITHUB_API_BASE
        or parsed.scheme != "https"
        or parsed.netloc != "api.github.com"
        or parsed.hostname != "api.github.com"
        or parsed.username is not None
        or parsed.password is not None
        or parsed.query
        or parsed.fragment
        or parsed.path
        or port is not None
    ):
        raise ConfigurationError("unsafe GitHub API base")


def load_config(path: str | os.PathLike[str]) -> Config:
    """Load the exact, closed production configuration schema."""

    try:
        with Path(path).open("r", encoding="utf-8") as config_file:
            payload = json.load(config_file)
    except (OSError, UnicodeError, ValueError, RecursionError) as error:
        raise ConfigurationError("configuration is unreadable") from error

    expected_keys = {field.name for field in fields(Config)}
    if not isinstance(payload, dict) or set(payload) != expected_keys:
        raise ConfigurationError("configuration keys do not match schema")

    string_fields = expected_keys - {
        "log_retention_count",
        "log_retention_days",
    }
    if any(type(payload[key]) is not str or not payload[key] for key in string_fields):
        raise ConfigurationError("configuration contains an invalid string")
    if (
        not _is_exact_int(payload["log_retention_count"])
        or not _is_exact_int(payload["log_retention_days"])
        or payload["log_retention_count"] <= 0
        or payload["log_retention_days"] <= 0
    ):
        raise ConfigurationError("configuration contains invalid retention")

    fixed_values = {
        "repository": EXPECTED_REPOSITORY,
        "workflow": EXPECTED_WORKFLOW,
        "workflow_name": EXPECTED_WORKFLOW_NAME,
        "branch": EXPECTED_BRANCH,
        "platform_nas_address": EXPECTED_NAS_ADDRESS,
        "platform_public_host": EXPECTED_NAS_ADDRESS,
        "platform_callback_host": EXPECTED_NAS_ADDRESS,
        "log_retention_count": EXPECTED_LOG_RETENTION_COUNT,
        "log_retention_days": EXPECTED_LOG_RETENTION_DAYS,
    }
    if any(payload[key] != value for key, value in fixed_values.items()):
        raise ConfigurationError("configuration identity does not match production")

    _validate_repository_url(payload["repository_url"])
    _validate_api_base(payload["github_api_base"])

    path_fields = {
        "controller_root",
        "tooling_root",
        "state_root",
        "log_root",
        "vault_file",
        "vault_password_file",
        "ntfy_curl_config",
    }
    for key in path_fields:
        if not Path(payload[key]).is_absolute():
            raise ConfigurationError("configuration paths must be absolute")

    values = {
        key: Path(value) if key in path_fields else value
        for key, value in payload.items()
    }
    return Config(**values)


def _mode(path_stat: os.stat_result) -> int:
    return stat.S_IMODE(path_stat.st_mode)


def _validate_owned_directory(path: Path) -> os.stat_result:
    try:
        path_stat = path.lstat()
    except OSError as error:
        raise StateError("protected directory is unsafe") from error
    if (
        not stat.S_ISDIR(path_stat.st_mode)
        or path_stat.st_uid != os.geteuid()
        or _mode(path_stat) != 0o700
        or Path(os.path.realpath(str(path))) != path
    ):
        raise StateError("protected directory is unsafe")
    return path_stat


def _validate_owned_file(path: Path) -> os.stat_result:
    try:
        path_stat = path.lstat()
    except OSError as error:
        raise StateError("protected file is unsafe") from error
    if (
        not stat.S_ISREG(path_stat.st_mode)
        or path_stat.st_uid != os.geteuid()
        or _mode(path_stat) != 0o600
        or Path(os.path.realpath(str(path))) != path
    ):
        raise StateError("protected file is unsafe")
    return path_stat


def _require_within(root: Path, path: Path) -> tuple[str, ...]:
    normalized_root = Path(os.path.normpath(str(root)))
    normalized_path = Path(os.path.normpath(str(path)))
    try:
        relative = normalized_path.relative_to(normalized_root)
    except ValueError as error:
        raise StateError("protected path is outside the owned root") from error
    return relative.parts


def _validate_path_from_root(root: Path, path: Path, *, file: bool) -> None:
    parts = _require_within(root, path)
    current = root
    _validate_owned_directory(current)
    for index, part in enumerate(parts):
        current = current / part
        if file and index == len(parts) - 1:
            _validate_owned_file(current)
        else:
            _validate_owned_directory(current)


def _owned_root(config: Config) -> Path:
    """Return the explicit trust boundary containing all protected paths."""

    return config.controller_root.parent


def _validate_protected_config(config: Config) -> None:
    owned_root = _owned_root(config)
    directories = {
        config.controller_root,
        config.tooling_root,
        config.state_root,
        config.log_root,
        config.vault_file.parent,
        config.vault_password_file.parent,
        config.ntfy_curl_config.parent,
    }
    protected_files = {
        config.vault_file,
        config.vault_password_file,
        config.ntfy_curl_config,
    }
    for directory in directories:
        _validate_path_from_root(owned_root, directory, file=False)
    for protected_file in protected_files:
        _validate_path_from_root(owned_root, protected_file, file=True)


def _same_inode(left: os.stat_result, right: os.stat_result) -> bool:
    return (left.st_dev, left.st_ino) == (right.st_dev, right.st_ino)


def _validate_open_directory_path(directory_fd: int, path: Path) -> None:
    path_stat = _validate_owned_directory(path)
    try:
        opened_stat = os.fstat(directory_fd)
    except OSError as error:
        raise StateError("protected directory is unsafe") from error
    if (
        not stat.S_ISDIR(opened_stat.st_mode)
        or opened_stat.st_uid != os.geteuid()
        or _mode(opened_stat) != 0o700
        or not _same_inode(path_stat, opened_stat)
    ):
        raise StateError("protected directory is unsafe")


@contextmanager
def _open_owned_directory(path: Path):
    path_stat = _validate_owned_directory(path)
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
    try:
        directory_fd = os.open(path, flags)
    except OSError as error:
        raise StateError("protected directory is unsafe") from error
    try:
        opened_stat = os.fstat(directory_fd)
        if (
            not stat.S_ISDIR(opened_stat.st_mode)
            or opened_stat.st_uid != os.geteuid()
            or _mode(opened_stat) != 0o700
            or not _same_inode(path_stat, opened_stat)
        ):
            raise StateError("protected directory is unsafe")
        _validate_open_directory_path(directory_fd, path)
        yield directory_fd
    except OSError as error:
        raise StateError("protected directory is unsafe") from error
    finally:
        try:
            os.close(directory_fd)
        except OSError as error:
            raise StateError("protected directory is unsafe") from error


def _validate_state_values(sha: object, timestamp: object, outcome: object) -> None:
    if type(sha) is not str or SHA_PATTERN.fullmatch(sha) is None:
        raise StateError("deployment state is invalid")
    if type(timestamp) is not str or TIMESTAMP_PATTERN.fullmatch(timestamp) is None:
        raise StateError("deployment state is invalid")
    try:
        datetime.strptime(timestamp, "%Y-%m-%dT%H:%M:%SZ")
    except ValueError as error:
        raise StateError("deployment state is invalid") from error
    if outcome not in ("success", "failed"):
        raise StateError("deployment state is invalid")


def _unique_json_object(pairs):
    payload = {}
    for key, value in pairs:
        if key in payload:
            raise StateError("deployment state is invalid")
        payload[key] = value
    return payload


def _validate_open_state_file(file_descriptor: int) -> None:
    try:
        opened_stat = os.fstat(file_descriptor)
    except OSError as error:
        raise StateError("protected file is unsafe") from error
    if (
        not stat.S_ISREG(opened_stat.st_mode)
        or opened_stat.st_uid != os.geteuid()
        or _mode(opened_stat) != 0o600
    ):
        raise StateError("protected file is unsafe")


def _read_sha_state_at(directory_fd: int, name: str) -> ShaState | None:
    flags = os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW
    try:
        file_descriptor = os.open(name, flags, dir_fd=directory_fd)
    except FileNotFoundError:
        return None
    except OSError as error:
        raise StateError("protected state is unreadable") from error
    try:
        _validate_open_state_file(file_descriptor)
        with os.fdopen(file_descriptor, "rb", closefd=False) as state_file:
            body = state_file.read(STATE_MAX_BYTES + 1)
    except OSError as error:
        raise StateError("protected state is unreadable") from error
    finally:
        os.close(file_descriptor)
    if len(body) > STATE_MAX_BYTES:
        raise StateError("deployment state is invalid")
    try:
        payload = json.loads(
            body.decode("utf-8"),
            object_pairs_hook=_unique_json_object,
        )
    except (UnicodeError, ValueError, RecursionError) as error:
        raise StateError("deployment state is invalid") from error
    if not isinstance(payload, dict) or set(payload) != {
        "sha",
        "timestamp",
        "outcome",
    }:
        raise StateError("deployment state is invalid")
    _validate_state_values(
        payload["sha"],
        payload["timestamp"],
        payload["outcome"],
    )
    return ShaState(
        sha=payload["sha"],
        timestamp=payload["timestamp"],
        outcome=payload["outcome"],
    )


def _state_path(path: str | os.PathLike[str]) -> tuple[Path, str]:
    state_path = Path(path)
    if not state_path.is_absolute() or state_path.name in ("", ".", ".."):
        raise StateError("protected state path is unsafe")
    return state_path.parent, state_path.name


def read_sha_state(path: str | os.PathLike[str]) -> ShaState | None:
    """Read one state record relative to a validated stable directory handle."""

    parent, name = _state_path(path)
    with _open_owned_directory(parent) as directory_fd:
        return _read_sha_state_at(directory_fd, name)


def _validate_existing_state_at(directory_fd: int, name: str) -> None:
    flags = os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW
    try:
        file_descriptor = os.open(name, flags, dir_fd=directory_fd)
    except FileNotFoundError:
        return
    except OSError as error:
        raise StateError("protected file is unsafe") from error
    try:
        _validate_open_state_file(file_descriptor)
    finally:
        os.close(file_descriptor)


def _write_sha_state_at(
    directory_fd: int,
    name: str,
    sha: str,
    timestamp: str,
    outcome: str,
) -> None:
    """Durably replace one state record through a protected adjacent file."""

    _validate_state_values(sha, timestamp, outcome)
    _validate_existing_state_at(directory_fd, name)
    payload = json.dumps(
        {"sha": sha, "timestamp": timestamp, "outcome": outcome},
        separators=(",", ":"),
        sort_keys=True,
    ).encode("utf-8")
    file_descriptor = -1
    temporary_name = None
    try:
        temporary_name = f".{name}.{secrets.token_hex(16)}.tmp"
        flags = os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW
        file_descriptor = os.open(
            temporary_name,
            flags,
            0o600,
            dir_fd=directory_fd,
        )
        os.fchmod(file_descriptor, 0o600)
        temporary_stat = os.fstat(file_descriptor)
        if (
            temporary_stat.st_uid != os.geteuid()
            or _mode(temporary_stat) != 0o600
            or not stat.S_ISREG(temporary_stat.st_mode)
        ):
            raise StateError("temporary state file is unsafe")
        with os.fdopen(file_descriptor, "wb", closefd=False) as state_file:
            state_file.write(payload)
            state_file.flush()
            os.fsync(file_descriptor)
        os.close(file_descriptor)
        file_descriptor = -1
        os.replace(
            temporary_name,
            name,
            src_dir_fd=directory_fd,
            dst_dir_fd=directory_fd,
        )
        temporary_name = None
        os.fsync(directory_fd)
    finally:
        if file_descriptor >= 0:
            os.close(file_descriptor)
        if temporary_name is not None:
            try:
                os.unlink(temporary_name, dir_fd=directory_fd)
            except FileNotFoundError:
                pass


def write_sha_state(
    path: str | os.PathLike[str],
    sha: str,
    timestamp: str,
    outcome: str,
) -> None:
    """Durably replace one state record without leaking filesystem errors."""

    parent, name = _state_path(path)
    try:
        with _open_owned_directory(parent) as directory_fd:
            _write_sha_state_at(directory_fd, name, sha, timestamp, outcome)
    except OSError as error:
        raise StateError("deployment state write failed") from error


def _remove_matching_sha_state_at(directory_fd: int, name: str, sha: str) -> None:
    state = _read_sha_state_at(directory_fd, name)
    if state is None or state.sha != sha:
        raise StateError("deployment state changed unexpectedly")
    try:
        os.unlink(name, dir_fd=directory_fd)
        os.fsync(directory_fd)
    except OSError as error:
        raise StateError("deployment state removal failed") from error


def _open_lock_entry_at(directory_fd: int, name: str) -> int:
    try:
        file_descriptor = os.open(
            name,
            os.O_RDWR | os.O_NONBLOCK | os.O_NOFOLLOW,
            dir_fd=directory_fd,
        )
    except FileNotFoundError:
        raise
    except OSError as error:
        raise StateError("deployment lock is unsafe") from error
    try:
        _validate_open_state_file(file_descriptor)
    except BaseException:
        os.close(file_descriptor)
        raise
    return file_descriptor


def _create_lock_identity_at(directory_fd: int) -> int:
    flags = os.O_CREAT | os.O_EXCL | os.O_RDWR | os.O_NONBLOCK | os.O_NOFOLLOW
    try:
        identity_fd = os.open(
            LOCK_IDENTITY_FILE_NAME,
            flags,
            0o600,
            dir_fd=directory_fd,
        )
    except FileExistsError:
        raise
    except OSError as error:
        raise StateError("deployment lock is unsafe") from error

    try:
        os.fchmod(identity_fd, 0o600)
        _validate_open_state_file(identity_fd)
        os.fsync(identity_fd)
        os.fsync(directory_fd)
    except BaseException:
        os.close(identity_fd)
        raise
    return identity_fd


def _open_or_create_lock_identity_at(directory_fd: int) -> int:
    for _attempt in range(LOCK_BOOTSTRAP_ATTEMPTS):
        try:
            return _open_lock_entry_at(
                directory_fd,
                LOCK_IDENTITY_FILE_NAME,
            )
        except FileNotFoundError:
            pass
        try:
            return _create_lock_identity_at(directory_fd)
        except FileExistsError:
            continue
    raise StateError("deployment lock is unsafe")


def _validate_lock_identity(identity_fd: int, lock_fd: int) -> None:
    try:
        identity_stat = os.fstat(identity_fd)
        lock_stat = os.fstat(lock_fd)
    except OSError as error:
        raise StateError("deployment lock is unsafe") from error
    if (
        not _same_inode(identity_stat, lock_stat)
        or identity_stat.st_nlink != 2
        or lock_stat.st_nlink != 2
    ):
        raise StateError("deployment lock is unsafe")


def _open_lock_at(directory_fd: int) -> int:
    for _attempt in range(LOCK_BOOTSTRAP_ATTEMPTS):
        identity_fd = _open_or_create_lock_identity_at(directory_fd)
        lock_fd = -1
        try:
            try:
                lock_fd = _open_lock_entry_at(directory_fd, LOCK_FILE_NAME)
            except FileNotFoundError:
                try:
                    identity_links = os.fstat(identity_fd).st_nlink
                except OSError as error:
                    raise StateError("deployment lock is unsafe") from error
                if identity_links == 1:
                    try:
                        os.link(
                            LOCK_IDENTITY_FILE_NAME,
                            LOCK_FILE_NAME,
                            src_dir_fd=directory_fd,
                            dst_dir_fd=directory_fd,
                            follow_symlinks=False,
                        )
                        os.fsync(directory_fd)
                    except FileExistsError:
                        pass
                    except OSError as error:
                        raise StateError("deployment lock is unsafe") from error
                elif identity_links != 2:
                    raise StateError("deployment lock is unsafe")
                try:
                    lock_fd = _open_lock_entry_at(directory_fd, LOCK_FILE_NAME)
                except FileNotFoundError:
                    continue
            _validate_lock_identity(identity_fd, lock_fd)
            return lock_fd
        except BaseException:
            if lock_fd >= 0:
                os.close(lock_fd)
            raise
        finally:
            os.close(identity_fd)
    raise StateError("deployment lock is unsafe")


def _acquire_deployment_flock(file_descriptor: int) -> bool:
    try:
        fcntl.flock(file_descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError as error:
        if error.errno in (errno.EACCES, errno.EAGAIN):
            return False
        raise StateError("deployment lock is unavailable") from error
    return True


@contextmanager
def _deployment_lock_under_trust(config: Config):
    """Lock the visible state namespace while its trust root is locked."""

    _validate_protected_config(config)
    with _open_owned_directory(config.state_root) as state_directory_fd:
        directory_locked = False
        file_descriptor = -1
        try:
            if not _acquire_deployment_flock(state_directory_fd):
                yield None
                return
            directory_locked = True
            file_descriptor = _open_lock_at(state_directory_fd)
            try:
                if not _acquire_deployment_flock(file_descriptor):
                    yield None
                    return
                try:
                    _validate_protected_config(config)
                    _validate_open_directory_path(
                        state_directory_fd,
                        config.state_root,
                    )
                    yield state_directory_fd
                finally:
                    fcntl.flock(file_descriptor, fcntl.LOCK_UN)
            finally:
                os.close(file_descriptor)
                file_descriptor = -1
        finally:
            if file_descriptor >= 0:
                os.close(file_descriptor)
            if directory_locked:
                fcntl.flock(state_directory_fd, fcntl.LOCK_UN)


@contextmanager
def _deployment_lock_fds(config: Config):
    """Yield pinned trust-root and state FDs under the complete lock order."""

    _validate_protected_config(config)
    trust_root = _owned_root(config)
    with _open_owned_directory(trust_root) as trust_directory_fd:
        trust_locked = False
        try:
            if not _acquire_deployment_flock(trust_directory_fd):
                yield None
                return
            trust_locked = True
            _validate_protected_config(config)
            _validate_open_directory_path(trust_directory_fd, trust_root)
            with _deployment_lock_under_trust(config) as state_directory_fd:
                if state_directory_fd is None:
                    yield None
                else:
                    yield trust_directory_fd, state_directory_fd
        finally:
            if trust_locked:
                fcntl.flock(trust_directory_fd, fcntl.LOCK_UN)


@contextmanager
def deployment_lock(config: Config):
    """Acquire stable trust-root, state-directory, and file locks in order."""

    with _deployment_lock_fds(config) as locked_directories:
        if locked_directories is None:
            yield None
        else:
            _trust_directory_fd, state_directory_fd = locked_directories
            yield state_directory_fd


def resolve_main_sha(config: Config) -> str:
    """Resolve the exact production branch SHA through anonymous HTTPS Git."""

    _validate_repository_url(config.repository_url)
    git_path = shutil.which("git")
    if git_path is None:
        raise EligibilityError("git is unavailable")

    environment = {
        "LANG": "C",
        "LC_ALL": "C",
        "PATH": os.environ.get("PATH", os.defpath),
    }
    try:
        result = subprocess.run(
            [
                git_path,
                "ls-remote",
                "--exit-code",
                config.repository_url,
                f"refs/heads/{config.branch}",
            ],
            capture_output=True,
            check=False,
            env=environment,
            stdin=subprocess.DEVNULL,
            shell=False,
            timeout=GIT_TIMEOUT_SECONDS,
        )
    except (OSError, subprocess.SubprocessError) as error:
        raise EligibilityError("git query failed") from error

    if (
        result.returncode != 0
        or len(result.stdout) > MAX_RESPONSE_BYTES
        or len(result.stderr) > MAX_RESPONSE_BYTES
    ):
        raise EligibilityError("git query failed")
    try:
        output = result.stdout.decode("ascii")
    except UnicodeDecodeError as error:
        raise EligibilityError("git response is invalid") from error
    lines = output.splitlines()
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


def _required_string(mapping: dict[str, Any], key: str) -> str:
    value = mapping.get(key)
    if type(value) is not str:
        raise EligibilityError("GitHub response has invalid types")
    return value


def _parse_ci_run(config: Config, payload: object) -> CiRun | None:
    if not isinstance(payload, dict):
        raise EligibilityError("GitHub response has invalid types")

    repository = payload.get("repository")
    if not isinstance(repository, dict):
        raise EligibilityError("GitHub response has invalid types")
    repository_name = _required_string(repository, "full_name")
    workflow_path = _required_string(payload, "path")

    run = CiRun(
        head_sha=_required_string(payload, "head_sha"),
        status=_required_string(payload, "status"),
        conclusion=_required_string(payload, "conclusion"),
        event=_required_string(payload, "event"),
        head_branch=_required_string(payload, "head_branch"),
        name=_required_string(payload, "name"),
    )
    expected_workflow_path = f".github/workflows/{config.workflow}"
    if repository_name != config.repository or workflow_path != expected_workflow_path:
        return None
    return run


def _remaining_http_time(deadline: float) -> float:
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise EligibilityError("GitHub request timed out")
    return remaining


def _set_response_socket_timeout(response, timeout: float) -> None:
    try:
        response.fp.raw._sock.settimeout(timeout)
    except AttributeError:
        pass


def _read_response_body(response, deadline: float) -> bytes:
    chunks = []
    body_size = 0
    read = getattr(response, "read1", response.read)
    while body_size <= MAX_RESPONSE_BYTES:
        remaining = _remaining_http_time(deadline)
        _set_response_socket_timeout(response, remaining)
        chunk = read(min(HTTP_READ_SIZE, MAX_RESPONSE_BYTES + 1 - body_size))
        if not chunk:
            return b"".join(chunks)
        if not isinstance(chunk, bytes):
            raise EligibilityError("GitHub response body has invalid type")
        chunks.append(chunk)
        body_size += len(chunk)
    raise EligibilityError("GitHub response is too large")


def fetch_ci_runs(config: Config, head_sha: str) -> tuple[CiRun, ...]:
    """Fetch one bounded page of completed push runs for the exact SHA."""

    if SHA_PATTERN.fullmatch(head_sha) is None:
        raise EligibilityError("candidate SHA is invalid")
    query = urlencode(
        {
            "branch": config.branch,
            "event": "push",
            "status": "completed",
            "head_sha": head_sha,
            "per_page": "10",
        }
    )
    url = (
        f"{config.github_api_base.rstrip('/')}"
        f"/repos/{config.repository}/actions/workflows/{config.workflow}/runs?{query}"
    )
    request = Request(
        url,
        headers={
            "Accept": "application/vnd.github+json",
            "User-Agent": "nas-platform-production-auto-deploy",
            "X-GitHub-Api-Version": "2022-11-28",
        },
        method="GET",
    )
    deadline = time.monotonic() + NETWORK_TIMEOUT_SECONDS
    try:
        with http_wall_clock_deadline(NETWORK_TIMEOUT_SECONDS):
            with urlopen(
                request,
                timeout=_remaining_http_time(deadline),
            ) as response:
                content_length = response.headers.get("Content-Length")
                if content_length is not None:
                    try:
                        if int(content_length) > MAX_RESPONSE_BYTES:
                            raise EligibilityError("GitHub response is too large")
                    except ValueError as error:
                        raise EligibilityError(
                            "GitHub response length is invalid"
                        ) from error
                body = _read_response_body(response, deadline)
    except EligibilityError:
        raise
    except HTTPError as error:
        error.close()
        raise EligibilityError("GitHub request failed") from error
    except (HTTPException, URLError, OSError, TimeoutError) as error:
        raise EligibilityError("GitHub request failed") from error

    if len(body) > MAX_RESPONSE_BYTES:
        raise EligibilityError("GitHub response is too large")
    try:
        payload = json.loads(body.decode("utf-8"))
    except (UnicodeError, ValueError, RecursionError) as error:
        raise EligibilityError("GitHub response is invalid JSON") from error
    if not isinstance(payload, dict):
        raise EligibilityError("GitHub response has invalid types")
    total_count = payload.get("total_count")
    workflow_runs = payload.get("workflow_runs")
    if (
        type(total_count) is not int
        or total_count < 0
        or not isinstance(workflow_runs, list)
        or total_count != len(workflow_runs)
        or total_count > 10
    ):
        raise EligibilityError("GitHub response has invalid types")

    runs = []
    for raw_run in workflow_runs:
        run = _parse_ci_run(config, raw_run)
        if run is not None:
            runs.append(run)
    return tuple(runs)


def eligible_ci_run(
    config: Config,
    head_sha: str,
    runs: Sequence[CiRun],
) -> CiRun | None:
    """Return the sole exact successful push run, or reject ambiguity."""

    matching_runs = [
        run
        for run in runs
        if run.head_sha == head_sha
        and run.status == "completed"
        and run.conclusion == "success"
        and run.event == "push"
        and run.head_branch == config.branch
        and run.name == config.workflow_name
    ]
    if len(matching_runs) != 1:
        return None
    return matching_runs[0]


def attempt_candidate(_config: Config, _sha: str) -> bool:
    """Fail closed until the exact deployment implementation is installed."""

    return False


def _timestamp_now() -> str:
    return (
        datetime.now(timezone.utc)
        .replace(microsecond=0)
        .isoformat()
        .replace("+00:00", "Z")
    )


def _read_deployment_states_at(
    state_directory_fd: int,
) -> tuple[ShaState | None, ShaState | None]:
    successful = _read_sha_state_at(state_directory_fd, "last-successful")
    failed = _read_sha_state_at(state_directory_fd, "last-failed")
    if successful is not None and successful.outcome != "success":
        raise StateError("deployment state is invalid")
    if failed is not None and failed.outcome != "failed":
        raise StateError("deployment state is invalid")
    return successful, failed


def _read_attempt_reservation_at(trust_directory_fd: int) -> ShaState | None:
    reservation = _read_sha_state_at(
        trust_directory_fd,
        ATTEMPT_RESERVATION_FILE_NAME,
    )
    if reservation is not None and reservation.outcome != "failed":
        raise StateError("deployment state is invalid")
    return reservation


def _state_directory_is_current(config: Config, state_directory_fd: int) -> bool:
    try:
        _validate_protected_config(config)
        _validate_open_directory_path(state_directory_fd, config.state_root)
    except ConfigurationError:
        return False
    return True


def _quarantine_current_state_root(
    config: Config,
    sha: str,
    timestamp: str,
) -> None:
    last_error = None
    for attempt in range(STATE_ROOT_CONVERGENCE_ATTEMPTS):
        try:
            with _deployment_lock_under_trust(config) as state_directory_fd:
                if state_directory_fd is None:
                    if attempt + 1 < STATE_ROOT_CONVERGENCE_ATTEMPTS:
                        time.sleep(STATE_ROOT_CONVERGENCE_DELAY_SECONDS)
                    continue
                _write_sha_state_at(
                    state_directory_fd,
                    "last-failed",
                    sha,
                    timestamp,
                    "failed",
                )
                _validate_protected_config(config)
                _validate_open_directory_path(
                    state_directory_fd,
                    config.state_root,
                )
                return
        except StateError as error:
            last_error = error
        if attempt + 1 < STATE_ROOT_CONVERGENCE_ATTEMPTS:
            time.sleep(STATE_ROOT_CONVERGENCE_DELAY_SECONDS)
    raise StateError("deployment state recovery failed") from last_error


def _quarantine_if_state_root_replaced(
    config: Config,
    state_directory_fd: int,
    sha: str,
    timestamp: str,
) -> bool:
    if _state_directory_is_current(config, state_directory_fd):
        return False
    _quarantine_current_state_root(config, sha, timestamp)
    return True


def _make_failed_state_visible(
    config: Config,
    state_directory_fd: int,
    sha: str,
    timestamp: str,
) -> None:
    if _state_directory_is_current(config, state_directory_fd):
        _write_sha_state_at(
            state_directory_fd,
            "last-failed",
            sha,
            timestamp,
            "failed",
        )
        if _state_directory_is_current(config, state_directory_fd):
            return
    _quarantine_current_state_root(config, sha, timestamp)


def _reconcile_attempt_reservation(
    config: Config,
    state_directory_fd: int,
    reservation: ShaState,
    successful: ShaState | None,
    failed: ShaState | None,
) -> None:
    represented = any(
        state is not None and state.sha == reservation.sha
        for state in (successful, failed)
    )
    if represented and _state_directory_is_current(config, state_directory_fd):
        return
    _make_failed_state_visible(
        config,
        state_directory_fd,
        reservation.sha,
        reservation.timestamp,
    )


def poll(config: Config, retry_sha: str | None = None) -> bool | None:
    """Attempt one eligible unrecorded SHA while holding the deployment lock."""

    if retry_sha is not None and SHA_PATTERN.fullmatch(retry_sha) is None:
        raise EligibilityError("retry SHA is invalid")
    with _deployment_lock_fds(config) as locked_directories:
        if locked_directories is None:
            return None
        trust_directory_fd, state_directory_fd = locked_directories
        successful, failed = _read_deployment_states_at(state_directory_fd)
        reservation = _read_attempt_reservation_at(trust_directory_fd)
        if reservation is not None:
            _reconcile_attempt_reservation(
                config,
                state_directory_fd,
                reservation,
                successful,
                failed,
            )
            if not _state_directory_is_current(config, state_directory_fd):
                return None
            successful, failed = _read_deployment_states_at(state_directory_fd)
        if (
            successful is not None
            and failed is not None
            and successful.sha == failed.sha
        ):
            _remove_matching_sha_state_at(
                state_directory_fd,
                "last-failed",
                successful.sha,
            )
            failed = None
        if retry_sha is not None:
            if (
                failed is None
                or failed.sha != retry_sha
                or failed.outcome != "failed"
                or (successful is not None and successful.sha == retry_sha)
            ):
                return None

        head_sha = resolve_main_sha(config)
        if retry_sha is not None:
            if head_sha != retry_sha:
                return None
        elif (successful is not None and successful.sha == head_sha) or (
            failed is not None and failed.sha == head_sha
        ):
            return None

        runs = fetch_ci_runs(config, head_sha)
        if eligible_ci_run(config, head_sha, runs) is None:
            return None

        attempt_timestamp = _timestamp_now()
        _write_sha_state_at(
            trust_directory_fd,
            ATTEMPT_RESERVATION_FILE_NAME,
            head_sha,
            attempt_timestamp,
            "failed",
        )
        try:
            _write_sha_state_at(
                state_directory_fd,
                "last-failed",
                head_sha,
                attempt_timestamp,
                "failed",
            )
        except Exception:
            if not _state_directory_is_current(config, state_directory_fd):
                _make_failed_state_visible(
                    config,
                    state_directory_fd,
                    head_sha,
                    attempt_timestamp,
                )
                return False
            raise
        if _quarantine_if_state_root_replaced(
            config,
            state_directory_fd,
            head_sha,
            attempt_timestamp,
        ):
            return False
        try:
            succeeded = attempt_candidate(config, head_sha) is True
        except Exception:
            succeeded = False
        if _quarantine_if_state_root_replaced(
            config,
            state_directory_fd,
            head_sha,
            attempt_timestamp,
        ):
            return False
        if not succeeded:
            return False
        try:
            _write_sha_state_at(
                state_directory_fd,
                "last-successful",
                head_sha,
                _timestamp_now(),
                "success",
            )
            if _quarantine_if_state_root_replaced(
                config,
                state_directory_fd,
                head_sha,
                attempt_timestamp,
            ):
                return False
            _remove_matching_sha_state_at(
                state_directory_fd,
                "last-failed",
                head_sha,
            )
        except Exception:
            if _quarantine_if_state_root_replaced(
                config,
                state_directory_fd,
                head_sha,
                attempt_timestamp,
            ):
                return False
            raise
        if _quarantine_if_state_root_replaced(
            config,
            state_directory_fd,
            head_sha,
            attempt_timestamp,
        ):
            return False
        return True


def print_status(config: Config) -> None:
    """Print only validated, non-secret deployment state records."""

    _validate_protected_config(config)
    trust_root = _owned_root(config)
    with _open_owned_directory(trust_root) as trust_directory_fd:
        reservation = _read_attempt_reservation_at(trust_directory_fd)
        with _open_owned_directory(config.state_root) as state_directory_fd:
            _validate_protected_config(config)
            _validate_open_directory_path(trust_directory_fd, trust_root)
            _validate_open_directory_path(state_directory_fd, config.state_root)
            successful, failed = _read_deployment_states_at(state_directory_fd)
            if (
                successful is not None
                and failed is not None
                and successful.sha == failed.sha
            ):
                failed = None
            if reservation is not None and any(
                state is not None and state.sha == reservation.sha
                for state in (successful, failed)
            ):
                reservation = None
            for state in (successful, failed, reservation):
                if state is not None:
                    print(
                        json.dumps(
                            {
                                "sha": state.sha,
                                "timestamp": state.timestamp,
                                "outcome": state.outcome,
                            },
                            separators=(",", ":"),
                        )
                    )


def _evaluate_ci(config: Config) -> CiRun | None:
    head_sha = resolve_main_sha(config)
    runs = fetch_ci_runs(config, head_sha)
    return eligible_ci_run(config, head_sha, runs)


def main(
    argv: Sequence[str] | None = None,
    *,
    config_path: str | os.PathLike[str] = DEFAULT_CONFIG_PATH,
) -> int:
    """Run one explicit production auto-deployment mode."""

    arguments = list(sys.argv[1:] if argv is None else argv)
    mode = "eligibility"
    retry_sha = None
    if arguments == ["--poll"]:
        mode = "poll"
    elif arguments == ["--status"]:
        mode = "status"
    elif len(arguments) == 2 and arguments[0] == "--retry-failed":
        if SHA_PATTERN.fullmatch(arguments[1]) is None:
            print("production auto-deploy: invalid arguments", file=sys.stderr)
            return 2
        mode = "retry"
        retry_sha = arguments[1]
    elif arguments:
        print("production auto-deploy: invalid arguments", file=sys.stderr)
        return 2

    try:
        config = load_config(config_path)
        if mode == "status":
            print_status(config)
            return 0
        if mode in ("poll", "retry"):
            poll_result = poll(config, retry_sha=retry_sha)
            if poll_result is False:
                print("production auto-deploy: attempt failed", file=sys.stderr)
                return 1
            return 0
        run = _evaluate_ci(config)
    except (ConfigurationError, OSError):
        print("production auto-deploy: unsafe configuration", file=sys.stderr)
        return 1
    except EligibilityError:
        print("production auto-deploy: no eligible CI run", file=sys.stderr)
        return 0

    if run is None:
        print("production auto-deploy: no eligible CI run", file=sys.stderr)
        return 0
    print(f"production auto-deploy: CI eligible for {run.head_sha}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
