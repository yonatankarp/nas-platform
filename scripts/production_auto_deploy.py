#!/usr/bin/env python3
"""Fail-closed GitHub Actions eligibility gate for production deployments."""

from __future__ import annotations

from contextlib import contextmanager
import ctypes
from dataclasses import dataclass, fields
from datetime import datetime, timezone
import errno
import fcntl
import hashlib
from http.client import HTTPException
import json
import os
from pathlib import Path
import re
import secrets
import selectors
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
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
COMMAND_TIMEOUT_SECONDS = 60 * 60
TOOLING_TIMEOUT_SECONDS = 15 * 60
SYSTEM_GIT_PATH = Path("/usr/bin/git")
SAFE_SYSTEM_PATH = "/usr/bin:/bin"
PROCESS_TERM_GRACE_SECONDS = 0.25
PROCESS_KILL_WAIT_SECONDS = 2.0
PROCESS_GROUP_POLL_SECONDS = 0.01
LINUX_PR_SET_CHILD_SUBREAPER = 36
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
GIT_SAFE_CONFIG = (
    "core.hooksPath=/dev/null",
    "core.fsmonitor=false",
    "core.attributesFile=/dev/null",
    "credential.helper=",
)
EXPECTED_CONTROLLER_REQUIREMENTS = b"ansible-core==2.21.2\nansible-lint==26.6.0\n"


class ConfigurationError(ValueError):
    """The fixed production configuration is invalid or unsafe."""


class EligibilityError(RuntimeError):
    """The candidate's CI eligibility could not be established safely."""


class DeploymentError(RuntimeError):
    """The exact candidate could not be deployed safely."""


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
    controller_python: Path
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


@dataclass(frozen=True)
class Tooling:
    ansible_playbook: Path
    python: Path
    collections: Path


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
        "controller_python",
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


def _minimal_environment(home: Path) -> dict[str, str]:
    return {
        "PATH": SAFE_SYSTEM_PATH,
        "LANG": "C.UTF-8",
        "LC_ALL": "C.UTF-8",
        "HOME": str(home),
    }


def _validate_trusted_executable(path: Path) -> Path:
    if not path.is_absolute():
        raise DeploymentError("trusted executable path is unsafe")
    try:
        path_stat = path.lstat()
    except OSError as error:
        raise DeploymentError("trusted executable is unavailable") from error
    if (
        not stat.S_ISREG(path_stat.st_mode)
        or path_stat.st_uid != 0
        or path_stat.st_mode & (stat.S_IWGRP | stat.S_IWOTH)
        or not path_stat.st_mode & (stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
        or Path(os.path.realpath(str(path))) != path
    ):
        raise DeploymentError("trusted executable path is unsafe")
    for ancestor in path.parents:
        try:
            ancestor_stat = ancestor.lstat()
        except OSError as error:
            raise DeploymentError("trusted executable path is unsafe") from error
        if (
            not stat.S_ISDIR(ancestor_stat.st_mode)
            or ancestor_stat.st_uid != 0
            or ancestor_stat.st_mode & (stat.S_IWGRP | stat.S_IWOTH)
        ):
            raise DeploymentError("trusted executable path is unsafe")
    return path


def _trusted_git_path() -> Path:
    return _validate_trusted_executable(SYSTEM_GIT_PATH)


def _validate_controller_python(config: Config) -> Path:
    python = _validate_trusted_executable(config.controller_python)
    version = _run_command(
        [
            str(python),
            "-c",
            "import sys; print(f'{sys.version_info[0]}.{sys.version_info[1]}')",
        ],
        cwd=config.controller_root,
        env=_minimal_environment(_owned_root(config)),
        timeout=GIT_TIMEOUT_SECONDS,
    )
    version_text = _decode_single_line(_checked_output(version))
    try:
        major, minor = (int(part) for part in version_text.split("."))
    except (TypeError, ValueError) as error:
        raise DeploymentError("controller Python version is invalid") from error
    if (major, minor) < (3, 12):
        raise DeploymentError("controller Python 3.12 or newer is required")
    return python


def _process_group_exists(process_group: int) -> bool:
    try:
        os.killpg(process_group, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def _linux_process_table() -> dict[int, int]:
    if not sys.platform.startswith("linux"):
        return {}
    processes = {}
    try:
        entries = list(Path("/proc").iterdir())
    except OSError as error:
        raise DeploymentError("deployment process tree is unavailable") from error
    for entry in entries:
        if not entry.name.isdigit():
            continue
        try:
            stat_fields = (
                (entry / "stat").read_text(encoding="ascii").rsplit(")", 1)[1].split()
            )
            processes[int(entry.name)] = int(stat_fields[1])
        except (IndexError, OSError, UnicodeError, ValueError):
            continue
    return processes


def _refresh_descendant_processes(
    process: subprocess.Popen,
    descendants: set[int],
    baseline_children: set[int],
) -> None:
    if not sys.platform.startswith("linux"):
        return
    process_table = _linux_process_table()
    descendants.add(process.pid)
    descendants.intersection_update(process_table)
    descendants.update(
        pid
        for pid, parent in process_table.items()
        if parent == os.getpid() and pid not in baseline_children
    )
    while True:
        discovered = {
            pid
            for pid, parent in process_table.items()
            if parent in descendants and pid not in descendants
        }
        if not discovered:
            return
        descendants.update(discovered)


def _process_tree_exists(process_group: int, descendants: set[int]) -> bool:
    if _process_group_exists(process_group):
        return True
    for pid in descendants:
        if pid <= 1 or pid == os.getpid():
            raise DeploymentError("deployment descendant identity is unsafe")
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            continue
        except PermissionError:
            return True
        return True
    return False


def _enable_child_subreaper() -> None:
    if not sys.platform.startswith("linux"):
        return
    try:
        libc = ctypes.CDLL(None, use_errno=True)
        result = libc.prctl(LINUX_PR_SET_CHILD_SUBREAPER, 1, 0, 0, 0)
    except (AttributeError, OSError) as error:
        raise DeploymentError("deployment subreaper is unavailable") from error
    if result != 0:
        raise DeploymentError("deployment subreaper could not be enabled")


def _reap_process_tree_children(
    process: subprocess.Popen,
    process_group: int,
    descendants: set[int],
) -> None:
    process.poll()
    for pid in tuple(descendants):
        if pid <= 1 or pid == os.getpid():
            raise DeploymentError("deployment descendant identity is unsafe")
        try:
            reaped_pid, _status = os.waitpid(pid, os.WNOHANG)
        except ChildProcessError:
            continue
        if reaped_pid > 0:
            descendants.discard(reaped_pid)


def _wait_for_process_group_exit(
    process: subprocess.Popen,
    process_group: int,
    descendants: set[int],
    baseline_children: set[int],
    timeout: float,
) -> bool:
    deadline = time.monotonic() + timeout
    while True:
        _refresh_descendant_processes(process, descendants, baseline_children)
        _reap_process_tree_children(process, process_group, descendants)
        if not _process_tree_exists(process_group, descendants):
            return True
        if time.monotonic() >= deadline:
            return False
        time.sleep(PROCESS_GROUP_POLL_SECONDS)


def _terminate_process_group(
    process: subprocess.Popen,
    process_group: int,
    descendants: set[int],
    baseline_children: set[int],
) -> None:
    if process_group <= 1 or process_group != process.pid:
        raise DeploymentError("deployment process group is unsafe")
    _refresh_descendant_processes(process, descendants, baseline_children)

    def signal_tree(signal_number: int) -> None:
        for pid in sorted(descendants, reverse=True):
            if pid <= 1 or pid == os.getpid():
                raise DeploymentError("deployment descendant identity is unsafe")
            try:
                os.kill(pid, signal_number)
            except ProcessLookupError:
                pass
        try:
            os.killpg(process_group, signal_number)
        except ProcessLookupError:
            pass

    signal_tree(signal.SIGTERM)
    if not _wait_for_process_group_exit(
        process,
        process_group,
        descendants,
        baseline_children,
        PROCESS_TERM_GRACE_SECONDS,
    ):
        signal_tree(signal.SIGKILL)
        if not _wait_for_process_group_exit(
            process,
            process_group,
            descendants,
            baseline_children,
            PROCESS_KILL_WAIT_SECONDS,
        ):
            raise DeploymentError("deployment process group survived termination")
    try:
        process.wait(timeout=PROCESS_KILL_WAIT_SECONDS)
    except subprocess.TimeoutExpired as error:
        raise DeploymentError("deployment process did not exit") from error
    if process.stdout is not None:
        process.stdout.close()


@contextmanager
def _command_signal_guard(
    process: subprocess.Popen,
    process_group: int,
    descendants: set[int],
    baseline_children: set[int],
):
    if threading.current_thread() is not threading.main_thread():
        yield
        return

    handled_signals = (signal.SIGINT, signal.SIGTERM)
    previous_handlers = {
        signal_number: signal.getsignal(signal_number)
        for signal_number in handled_signals
    }

    def terminate_then_exit(signal_number, _frame):
        _terminate_process_group(
            process,
            process_group,
            descendants,
            baseline_children,
        )
        if signal_number == signal.SIGINT:
            raise KeyboardInterrupt
        raise SystemExit(128 + signal_number)

    try:
        for signal_number in handled_signals:
            signal.signal(signal_number, terminate_then_exit)
        yield
    finally:
        for signal_number, previous_handler in previous_handlers.items():
            signal.signal(signal_number, previous_handler)


def _write_command_output(log, output: bytes) -> None:
    if log is None or not output:
        return
    log.write(output)
    flush = getattr(log, "flush", None)
    if flush is not None:
        flush()


def _run_command(
    arguments: Sequence[str | os.PathLike[str]],
    *,
    cwd: Path,
    env: dict[str, str],
    timeout: float,
    log=None,
) -> subprocess.CompletedProcess:
    """Run one argument-array command in a killable process group."""

    command = [str(argument) for argument in arguments]
    _enable_child_subreaper()
    process_table = _linux_process_table()
    baseline_children = {
        pid for pid, parent in process_table.items() if parent == os.getpid()
    }
    try:
        process = subprocess.Popen(
            command,
            cwd=str(cwd),
            env=dict(env),
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            shell=False,
            start_new_session=True,
        )
    except OSError as error:
        raise DeploymentError("deployment command could not start") from error
    process_group = process.pid
    descendants = {process.pid}
    try:
        actual_process_group = os.getpgid(process.pid)
    except ProcessLookupError:
        actual_process_group = process_group
    if actual_process_group != process_group or process_group <= 1:
        process.kill()
        if process.stdout is not None:
            process.stdout.close()
        process.wait()
        raise DeploymentError("deployment process group is unsafe")
    output = bytearray()
    deadline = time.monotonic() + timeout
    if process.stdout is None:
        _terminate_process_group(process, process_group, descendants, baseline_children)
        raise DeploymentError("deployment command output is unavailable")
    output_fd = process.stdout.fileno()
    os.set_blocking(output_fd, False)
    selector = selectors.DefaultSelector()
    selector.register(output_fd, selectors.EVENT_READ)
    try:
        with _command_signal_guard(
            process,
            process_group,
            descendants,
            baseline_children,
        ):
            output_open = True
            while output_open or process.poll() is None:
                _refresh_descendant_processes(
                    process,
                    descendants,
                    baseline_children,
                )
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise subprocess.TimeoutExpired(command, timeout)
                for _key, _events in selector.select(
                    min(remaining, PROCESS_GROUP_POLL_SECONDS)
                ):
                    chunk = os.read(output_fd, HTTP_READ_SIZE)
                    if not chunk:
                        selector.unregister(output_fd)
                        output_open = False
                        break
                    available = MAX_RESPONSE_BYTES - len(output)
                    accepted = chunk[:available]
                    output.extend(accepted)
                    _write_command_output(log, accepted)
                    if len(chunk) > available:
                        raise DeploymentError("deployment command output is too large")
    except subprocess.TimeoutExpired as error:
        _terminate_process_group(process, process_group, descendants, baseline_children)
        raise DeploymentError("deployment command timed out") from error
    except BaseException:
        _terminate_process_group(process, process_group, descendants, baseline_children)
        raise
    finally:
        selector.close()
    _refresh_descendant_processes(process, descendants, baseline_children)
    _reap_process_tree_children(process, process_group, descendants)
    if _process_tree_exists(process_group, descendants):
        _terminate_process_group(process, process_group, descendants, baseline_children)
        raise DeploymentError("deployment command left background processes")
    process.stdout.close()
    output_bytes = bytes(output)
    return subprocess.CompletedProcess(command, process.returncode, output_bytes, b"")


def _checked_output(result: subprocess.CompletedProcess) -> bytes:
    if result.returncode != 0 or not isinstance(result.stdout, bytes):
        raise DeploymentError("deployment command failed")
    if len(result.stdout) > MAX_RESPONSE_BYTES:
        raise DeploymentError("deployment command output is too large")
    return result.stdout


def _git_command(
    config: Config, arguments: Sequence[str]
) -> subprocess.CompletedProcess:
    git_path = _trusted_git_path()
    safe_config_arguments = [
        argument for setting in GIT_SAFE_CONFIG for argument in ("-c", setting)
    ]
    return _run_command(
        [str(git_path), "--no-replace-objects", *safe_config_arguments, *arguments],
        cwd=config.controller_root,
        env=_minimal_environment(_owned_root(config)),
        timeout=GIT_TIMEOUT_SECONDS,
    )


def _reject_ambient_git_overrides() -> None:
    exact_names = {
        "GIT_ALTERNATE_OBJECT_DIRECTORIES",
        "GIT_COMMON_DIR",
        "GIT_CONFIG",
        "GIT_CONFIG_COUNT",
        "GIT_CONFIG_GLOBAL",
        "GIT_CONFIG_NOSYSTEM",
        "GIT_CONFIG_SYSTEM",
        "GIT_DIR",
        "GIT_INDEX_FILE",
        "GIT_OBJECT_DIRECTORY",
        "GIT_REPLACE_REF_BASE",
        "GIT_SHALLOW_FILE",
        "GIT_WORK_TREE",
    }
    if any(name in os.environ for name in exact_names) or any(
        name.startswith(("GIT_CONFIG_KEY_", "GIT_CONFIG_VALUE_")) for name in os.environ
    ):
        raise DeploymentError("ambient Git configuration is unsafe")


def _decode_single_line(output: bytes) -> str:
    try:
        text = output.decode("utf-8")
    except UnicodeDecodeError as error:
        raise DeploymentError("deployment command output is invalid") from error
    lines = text.splitlines()
    if len(lines) != 1:
        raise DeploymentError("deployment command output is invalid")
    return lines[0]


def _reject_sparse_index(config: Config) -> None:
    index = _checked_output(_git_command(config, ["ls-files", "-v"]))
    for line in index.splitlines():
        if len(line) < 3 or line[1:2] != b" ":
            raise DeploymentError("controller index is invalid")
        tag = line[0]
        if tag == ord("S") or ord("a") <= tag <= ord("z"):
            raise DeploymentError("controller index is sparse")


def _reject_unsafe_tree_entries(config: Config, revision: str) -> None:
    tree = _checked_output(
        _git_command(config, ["ls-tree", "-r", "--full-tree", revision])
    )
    for line in tree.splitlines():
        if line.startswith(b"160000 "):
            raise DeploymentError("candidate contains a submodule")
        if line.startswith(b"120000 "):
            raise DeploymentError("candidate contains a symbolic link")
        _metadata, separator, path = line.partition(b"\t")
        if separator and b".gitattributes" in path.split(b"/"):
            raise DeploymentError("candidate contains Git attributes")


def _validate_controller_git_paths(config: Config) -> None:
    checkout = config.controller_root
    expected_git_directory = checkout / ".git"
    top_level = Path(
        _decode_single_line(
            _checked_output(_git_command(config, ["rev-parse", "--show-toplevel"]))
        )
    )
    git_directory = Path(
        _decode_single_line(
            _checked_output(_git_command(config, ["rev-parse", "--absolute-git-dir"]))
        )
    )
    common_git_directory = Path(
        _decode_single_line(
            _checked_output(
                _git_command(
                    config,
                    ["rev-parse", "--path-format=absolute", "--git-common-dir"],
                )
            )
        )
    )
    if (
        not top_level.is_absolute()
        or Path(os.path.realpath(str(top_level))) != checkout
        or not git_directory.is_absolute()
        or Path(os.path.realpath(str(git_directory))) != expected_git_directory
        or not common_git_directory.is_absolute()
        or Path(os.path.realpath(str(common_git_directory))) != expected_git_directory
    ):
        raise DeploymentError("controller Git paths are unsafe")


def _reject_replacement_refs(config: Config) -> None:
    replacements = _checked_output(
        _git_command(
            config,
            ["for-each-ref", "--format=%(refname)", "refs/replace/"],
        )
    )
    if replacements:
        raise DeploymentError("controller replacement refs are unsafe")


def _validate_materialized_checkout(config: Config, sha: str) -> None:
    """Revalidate the dedicated checkout at a stage boundary.

    The deployment lock excludes cooperating poller/installer mutations. Other
    processes running as the same account are inside the controller trust boundary.
    """

    if SHA_PATTERN.fullmatch(sha) is None:
        raise DeploymentError("candidate SHA is invalid")
    _validate_protected_config(config)
    _reject_ambient_git_overrides()
    checkout = config.controller_root
    git_directory = checkout / ".git"
    try:
        git_directory_stat = git_directory.lstat()
    except OSError as error:
        raise DeploymentError("controller Git metadata is unsafe") from error
    unsafe_metadata = (
        git_directory / "objects" / "info" / "alternates",
        git_directory / "objects" / "info" / "http-alternates",
        git_directory / "info" / "attributes",
        git_directory / "info" / "grafts",
        git_directory / "commondir",
        git_directory / "shallow",
    )
    if (
        not stat.S_ISDIR(git_directory_stat.st_mode)
        or Path(os.path.realpath(str(git_directory))) != git_directory
        or (checkout / ".gitmodules").exists()
        or any(path.exists() or path.is_symlink() for path in unsafe_metadata)
    ):
        raise DeploymentError("controller checkout is unsafe")
    unsafe_config = _git_command(
        config,
        [
            "config",
            "--local",
            "--get-regexp",
            r"^(core\.alternateRefsCommand|core\.attributesFile|core\.fsmonitor|core\.hooksPath|core\.sparseCheckout|core\.sparseCheckoutCone|core\.worktree|extensions\.partialClone|filter\..*\.(clean|process|required|smudge)|remote\..*\.promisor|url\..*\.insteadOf)$",
        ],
    )
    if unsafe_config.returncode not in (0, 1) or unsafe_config.stdout:
        raise DeploymentError("controller Git configuration is unsafe")
    _validate_controller_git_paths(config)
    _reject_replacement_refs(config)
    _reject_unsafe_tree_entries(config, sha)
    _reject_unsafe_tree_entries(config, "HEAD")
    _reject_sparse_index(config)
    status = _checked_output(
        _git_command(
            config,
            [
                "status",
                "--porcelain=v1",
                "--untracked-files=all",
                "--ignored=matching",
            ],
        )
    )
    remote = _decode_single_line(
        _checked_output(_git_command(config, ["remote", "get-url", "origin"]))
    )
    remotes = _checked_output(_git_command(config, ["remote"])).splitlines()
    head_sha = _decode_single_line(
        _checked_output(_git_command(config, ["rev-parse", "HEAD"]))
    )
    origin_sha = _decode_single_line(
        _checked_output(_git_command(config, ["rev-parse", "refs/remotes/origin/main"]))
    )
    symbolic_ref = _git_command(config, ["symbolic-ref", "-q", "HEAD"])
    gitmodules = _git_command(config, ["cat-file", "-e", f"{sha}:.gitmodules"])
    if (
        status
        or remote != config.repository_url
        or remotes != [b"origin"]
        or head_sha != sha
        or origin_sha != sha
        or symbolic_ref.returncode != 1
        or symbolic_ref.stdout
        or gitmodules.returncode != 1
    ):
        raise DeploymentError("materialized checkout does not match candidate")


def prepare_checkout(config: Config, sha: str) -> Path:
    """Fetch and detach the clean dedicated controller at the exact SHA."""

    if SHA_PATTERN.fullmatch(sha) is None:
        raise DeploymentError("candidate SHA is invalid")
    _validate_protected_config(config)
    _reject_ambient_git_overrides()
    checkout = config.controller_root
    git_directory = checkout / ".git"
    try:
        git_directory_stat = git_directory.lstat()
    except OSError as error:
        raise DeploymentError("controller Git metadata is unsafe") from error
    if (
        not stat.S_ISDIR(git_directory_stat.st_mode)
        or Path(os.path.realpath(str(git_directory))) != git_directory
    ):
        raise DeploymentError("controller Git metadata is unsafe")
    alternate_files = (
        git_directory / "objects" / "info" / "alternates",
        git_directory / "objects" / "info" / "http-alternates",
        git_directory / "info" / "attributes",
        git_directory / "info" / "grafts",
        git_directory / "commondir",
        git_directory / "shallow",
    )
    if (checkout / ".gitmodules").exists() or any(
        path.exists() or path.is_symlink() for path in alternate_files
    ):
        raise DeploymentError("controller checkout is unsafe")

    unsafe_config = _git_command(
        config,
        [
            "config",
            "--local",
            "--get-regexp",
            r"^(core\.alternateRefsCommand|core\.attributesFile|core\.fsmonitor|core\.hooksPath|core\.sparseCheckout|core\.sparseCheckoutCone|core\.worktree|extensions\.partialClone|filter\..*\.(clean|process|required|smudge)|remote\..*\.promisor|url\..*\.insteadOf)$",
        ],
    )
    if unsafe_config.returncode not in (0, 1):
        raise DeploymentError("controller Git configuration is unreadable")
    if unsafe_config.stdout:
        raise DeploymentError("controller Git configuration is unsafe")
    _validate_controller_git_paths(config)
    _reject_replacement_refs(config)
    _reject_unsafe_tree_entries(config, "HEAD")
    _reject_sparse_index(config)

    status_arguments = [
        "status",
        "--porcelain=v1",
        "--untracked-files=all",
        "--ignored=matching",
    ]
    if _checked_output(_git_command(config, status_arguments)):
        raise DeploymentError("controller checkout is dirty")
    remote = _decode_single_line(
        _checked_output(_git_command(config, ["remote", "get-url", "origin"]))
    )
    if remote != config.repository_url:
        raise DeploymentError("controller origin is unsafe")
    remotes = _checked_output(_git_command(config, ["remote"])).splitlines()
    if remotes != [b"origin"]:
        raise DeploymentError("controller remotes are unsafe")

    fetch = _git_command(
        config,
        [
            "fetch",
            "--no-tags",
            "--prune",
            "origin",
            "+refs/heads/main:refs/remotes/origin/main",
        ],
    )
    _checked_output(fetch)
    fetched_sha = _decode_single_line(
        _checked_output(_git_command(config, ["rev-parse", "refs/remotes/origin/main"]))
    )
    if fetched_sha != sha:
        raise DeploymentError("fetched SHA does not match candidate")

    gitmodules = _git_command(config, ["cat-file", "-e", f"{sha}:.gitmodules"])
    if gitmodules.returncode == 0:
        raise DeploymentError("candidate contains .gitmodules")
    if gitmodules.returncode != 1:
        raise DeploymentError("candidate tree could not be inspected")
    _reject_unsafe_tree_entries(config, sha)

    _checked_output(_git_command(config, ["checkout", "--detach", sha]))
    head_sha = _decode_single_line(
        _checked_output(_git_command(config, ["rev-parse", "HEAD"]))
    )
    final_origin_sha = _decode_single_line(
        _checked_output(_git_command(config, ["rev-parse", "refs/remotes/origin/main"]))
    )
    symbolic_ref = _git_command(config, ["symbolic-ref", "-q", "HEAD"])
    _reject_sparse_index(config)
    if (
        head_sha != sha
        or final_origin_sha != sha
        or symbolic_ref.returncode != 1
        or symbolic_ref.stdout
        or _checked_output(_git_command(config, status_arguments))
    ):
        raise DeploymentError("detached checkout does not match candidate")
    if (checkout / ".gitmodules").exists():
        raise DeploymentError("candidate contains .gitmodules")
    _validate_materialized_checkout(config, sha)
    return checkout


def _read_tooling_requirement(checkout: Path, relative_path: str) -> bytes:
    path = checkout / relative_path
    try:
        before = path.lstat()
        if (
            not stat.S_ISREG(before.st_mode)
            or Path(os.path.realpath(str(path))) != path
        ):
            raise DeploymentError("tooling requirements are unsafe")
        flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
        descriptor = os.open(path, flags)
        try:
            opened = os.fstat(descriptor)
            if not stat.S_ISREG(opened.st_mode) or not _same_inode(before, opened):
                raise DeploymentError("tooling requirements are unsafe")
            with os.fdopen(descriptor, "rb") as requirement_file:
                descriptor = -1
                payload = requirement_file.read()
        finally:
            if descriptor >= 0:
                os.close(descriptor)
        after = path.lstat()
        if not _same_inode(before, after):
            raise DeploymentError("tooling requirements are unsafe")
    except OSError as error:
        raise DeploymentError("tooling requirements are unreadable") from error
    if (
        relative_path == "controller-requirements.txt"
        and payload != EXPECTED_CONTROLLER_REQUIREMENTS
    ):
        raise DeploymentError("controller requirements do not match exact pins")
    return payload


def tooling_identity(checkout: Path) -> str:
    """Hash exact length-prefixed controller and collection requirements."""

    payloads = [
        _read_tooling_requirement(checkout, relative_path)
        for relative_path in ("controller-requirements.txt", "requirements.yml")
    ]
    return _tooling_identity_payloads(payloads)


def _tooling_identity_payloads(payloads: Sequence[bytes]) -> str:
    digest = hashlib.sha256()
    for payload in payloads:
        digest.update(len(payload).to_bytes(8, "big"))
        digest.update(payload)
    return digest.hexdigest()


def _read_reviewed_requirement(config: Config, sha: str, relative_path: str) -> bytes:
    _validate_materialized_checkout(config, sha)
    payload = _read_tooling_requirement(config.controller_root, relative_path)
    _validate_materialized_checkout(config, sha)
    return payload


def _tooling_paths(root: Path) -> Tooling:
    return Tooling(
        ansible_playbook=(root / "venv" / "bin" / "ansible-playbook").absolute(),
        python=(root / "venv" / "bin" / "python").absolute(),
        collections=(root / "collections").absolute(),
    )


def _hash_file(path: Path) -> str:
    digest = hashlib.sha256()
    try:
        with path.open("rb") as input_file:
            while True:
                chunk = input_file.read(HTTP_READ_SIZE)
                if not chunk:
                    return digest.hexdigest()
                digest.update(chunk)
    except OSError as error:
        raise DeploymentError("published tooling is incomplete") from error


def _tooling_manifest(root: Path) -> bytes:
    entries = []
    try:
        root_owner = root.lstat().st_uid
        paths = sorted(
            root.rglob("*"),
            key=lambda path: path.relative_to(root).as_posix(),
        )
        for path in paths:
            relative = path.relative_to(root).as_posix()
            if relative in (".complete", ".manifest"):
                continue
            path_stat = path.lstat()
            if path_stat.st_uid != root_owner:
                raise DeploymentError("published tooling is incomplete")
            mode = _mode(path_stat)
            if stat.S_ISREG(path_stat.st_mode):
                if path_stat.st_nlink != 1:
                    raise DeploymentError("published tooling is incomplete")
                entries.append([relative, "file", mode, _hash_file(path)])
            elif stat.S_ISDIR(path_stat.st_mode):
                entries.append([relative, "directory", mode, ""])
            elif stat.S_ISLNK(path_stat.st_mode):
                raise DeploymentError("published tooling is incomplete")
            else:
                raise DeploymentError("published tooling is incomplete")
    except OSError as error:
        raise DeploymentError("published tooling is incomplete") from error
    return (
        json.dumps(entries, separators=(",", ":"), ensure_ascii=True).encode("ascii")
        + b"\n"
    )


def _validate_tooling(root: Path, identity: str, home: Path) -> Tooling:
    try:
        root_stat = root.lstat()
        marker = root / ".complete"
        marker_stat = marker.lstat()
        marker_bytes = marker.read_bytes()
        manifest = root / ".manifest"
        manifest_stat = manifest.lstat()
        manifest_bytes = manifest.read_bytes()
        installed_manifest = root / ".installed"
        installed_manifest_stat = installed_manifest.lstat()
        installed_manifest_bytes = installed_manifest.read_bytes()
    except OSError as error:
        raise DeploymentError("published tooling is incomplete") from error
    if (
        not stat.S_ISDIR(root_stat.st_mode)
        or root_stat.st_uid != os.geteuid()
        or _mode(root_stat) != 0o500
        or Path(os.path.realpath(str(root))) != root
        or not stat.S_ISREG(marker_stat.st_mode)
        or marker_stat.st_uid != root_stat.st_uid
        or marker_stat.st_nlink != 1
        or _mode(marker_stat) != 0o400
        or marker_bytes != (identity + "\n").encode("ascii")
        or not stat.S_ISREG(manifest_stat.st_mode)
        or manifest_stat.st_uid != root_stat.st_uid
        or manifest_stat.st_nlink != 1
        or _mode(manifest_stat) != 0o400
        or manifest_bytes != _tooling_manifest(root)
        or not stat.S_ISREG(installed_manifest_stat.st_mode)
        or installed_manifest_stat.st_uid != root_stat.st_uid
        or _mode(installed_manifest_stat) != 0o400
        or installed_manifest_stat.st_nlink != 1
    ):
        raise DeploymentError("published tooling is incomplete")
    tooling = _tooling_paths(root)
    for executable in (tooling.python, tooling.ansible_playbook):
        try:
            executable_stat = executable.lstat()
        except OSError as error:
            raise DeploymentError("published tooling is incomplete") from error
        if (
            not stat.S_ISREG(executable_stat.st_mode)
            or not os.access(executable, os.X_OK)
            or root not in executable.parents
        ):
            raise DeploymentError("published tooling is incomplete")
    try:
        collections_stat = tooling.collections.lstat()
    except OSError as error:
        raise DeploymentError("published tooling is incomplete") from error
    if (
        not stat.S_ISDIR(collections_stat.st_mode)
        or _mode(collections_stat) != 0o500
        or root not in tooling.collections.parents
    ):
        raise DeploymentError("published tooling is incomplete")
    try:
        installed_payload = json.loads(installed_manifest_bytes.decode("ascii"))
        expected_collections = installed_payload["collections"]
    except (KeyError, TypeError, UnicodeError, ValueError, RecursionError) as error:
        raise DeploymentError("published tooling manifest is invalid") from error
    if (
        not isinstance(expected_collections, dict)
        or any(
            type(name) is not str or type(version) is not str
            for name, version in expected_collections.items()
        )
        or _capture_installed_tooling_manifest(
            tooling,
            home,
            expected_collections,
        )
        != installed_manifest_bytes
    ):
        raise DeploymentError("published tooling manifest is invalid")
    return tooling


def _write_seal_file(staging: Path, name: str, payload: bytes) -> None:
    path = staging / name
    descriptor = os.open(
        path,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0),
        0o600,
    )
    try:
        _write_all(descriptor, payload)
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    path.chmod(0o400)


def _write_all(descriptor: int, payload: bytes) -> None:
    remaining = memoryview(payload)
    while remaining:
        written = os.write(descriptor, remaining)
        if written <= 0:
            raise OSError("short write")
        remaining = remaining[written:]


def _seal_tooling(staging: Path, identity: str) -> None:
    paths = sorted(
        staging.rglob("*"),
        key=lambda path: len(path.relative_to(staging).parts),
        reverse=True,
    )
    for path in paths:
        path_stat = path.lstat()
        if stat.S_ISLNK(path_stat.st_mode):
            continue
        if stat.S_ISDIR(path_stat.st_mode):
            path.chmod(0o500)
        elif stat.S_ISREG(path_stat.st_mode):
            path.chmod(0o500 if path_stat.st_mode & 0o111 else 0o400)
        else:
            raise DeploymentError("staged tooling contains an unsafe file")
    _write_seal_file(staging, ".manifest", _tooling_manifest(staging))
    _write_seal_file(staging, ".complete", (identity + "\n").encode("ascii"))
    staging.chmod(0o500)


def _remove_private_staging(staging: Path) -> None:
    try:
        paths = sorted(
            staging.rglob("*"),
            key=lambda path: len(path.relative_to(staging).parts),
        )
        staging.chmod(0o700)
        for path in paths:
            if path.is_dir() and not path.is_symlink():
                path.chmod(0o700)
        shutil.rmtree(staging)
    except OSError:
        pass


def _install_relocatable_ansible_wrapper(path: Path) -> None:
    path.write_bytes(
        b"#!/bin/sh\n"
        b'script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P) || exit 1\n'
        b'exec "$script_dir/python" -B -m ansible.cli.playbook "$@"\n'
    )
    path.chmod(0o700)


def _remove_standard_venv_symlink(venv: Path) -> None:
    lib64 = venv / "lib64"
    if not lib64.exists() and not lib64.is_symlink():
        return
    lib = venv / "lib"
    try:
        lib_stat = lib.lstat()
        lib64_stat = lib64.lstat()
        link_target = os.readlink(lib64)
    except OSError as error:
        raise DeploymentError("virtual environment contains an unsafe link") from error
    if (
        not stat.S_ISDIR(lib_stat.st_mode)
        or not stat.S_ISLNK(lib64_stat.st_mode)
        or link_target != "lib"
    ):
        raise DeploymentError("virtual environment contains an unsafe link")
    lib64.unlink()


def _materialize_internal_symlinks(staging: Path) -> None:
    for path in sorted(
        staging.rglob("*"),
        key=lambda candidate: candidate.relative_to(staging).as_posix(),
    ):
        try:
            path_stat = path.lstat()
        except OSError as error:
            raise DeploymentError("staged tooling contains an unsafe link") from error
        if not stat.S_ISLNK(path_stat.st_mode):
            continue
        resolved = Path(os.path.realpath(str(path)))
        if staging not in resolved.parents:
            raise DeploymentError("staged tooling contains an unsafe link")
        try:
            target_descriptor = os.open(
                resolved,
                os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0),
            )
            target_stat = os.fstat(target_descriptor)
        except OSError as error:
            raise DeploymentError("staged tooling contains an unsafe link") from error
        if not stat.S_ISREG(target_stat.st_mode):
            os.close(target_descriptor)
            raise DeploymentError("staged tooling contains an unsafe link")
        output_mode = 0o700 if target_stat.st_mode & 0o111 else 0o600
        output_descriptor = None
        try:
            path.unlink()
            output_descriptor = os.open(
                path,
                os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0),
                output_mode,
            )
            while True:
                chunk = os.read(target_descriptor, HTTP_READ_SIZE)
                if not chunk:
                    break
                _write_all(output_descriptor, chunk)
            os.fsync(output_descriptor)
        except OSError as error:
            raise DeploymentError("staged tooling contains an unsafe link") from error
        finally:
            os.close(target_descriptor)
            if output_descriptor is not None:
                os.close(output_descriptor)


def _tooling_environment(
    home: Path,
    collections: Path | None = None,
    ansible_config: Path | None = None,
) -> dict[str, str]:
    environment = _minimal_environment(home)
    environment.update(
        {
            "PIP_CONFIG_FILE": os.devnull,
            "PIP_DISABLE_PIP_VERSION_CHECK": "1",
            "PYTHONNOUSERSITE": "1",
            "PYTHONDONTWRITEBYTECODE": "1",
            "PYTHONSAFEPATH": "1",
            "ANSIBLE_CONFIG": str(ansible_config or home / ".ansible-build.cfg"),
        }
    )
    if collections is not None:
        environment["ANSIBLE_COLLECTIONS_PATH"] = str(collections)
    return environment


def _capture_installed_tooling_manifest(
    tooling: Tooling,
    home: Path,
    expected_collections: dict[str, str],
) -> bytes:
    root = tooling.python.parent.parent.parent
    environment = _tooling_environment(
        home,
        tooling.collections,
        root / ".ansible-build.cfg",
    )
    environment["PATH"] = f"{tooling.python.parent}{os.pathsep}{SAFE_SYSTEM_PATH}"

    def output(arguments: Sequence[str | os.PathLike[str]]) -> bytes:
        return _checked_output(
            _run_command(
                arguments,
                cwd=root,
                env=environment,
                timeout=GIT_TIMEOUT_SECONDS,
            )
        )

    python_version = _decode_single_line(
        output(
            [
                tooling.python,
                "-c",
                "import sys; print(f'{sys.version_info[0]}.{sys.version_info[1]}')",
            ]
        )
    )
    try:
        python_parts = tuple(int(part) for part in python_version.split("."))
    except ValueError as error:
        raise DeploymentError("published Python version is invalid") from error
    if len(python_parts) != 2 or python_parts < (3, 12):
        raise DeploymentError("published Python version is invalid")

    freeze_output = output(
        [
            tooling.python,
            "-m",
            "pip",
            "--isolated",
            "--disable-pip-version-check",
            "freeze",
            "--all",
        ]
    )
    try:
        freeze_lines = sorted(
            line for line in freeze_output.decode("utf-8").splitlines() if line
        )
    except UnicodeDecodeError as error:
        raise DeploymentError("published package manifest is invalid") from error
    normalized_packages = {line.casefold() for line in freeze_lines}
    if not {
        "ansible-core==2.21.2",
        "ansible-lint==26.6.0",
    }.issubset(normalized_packages):
        raise DeploymentError("published package versions are invalid")

    ansible_version = output([tooling.ansible_playbook, "--version"]).splitlines()[:1]
    if ansible_version != [b"ansible-playbook [core 2.21.2]"]:
        raise DeploymentError("published Ansible version is invalid")
    ansible_lint_line = output(
        [tooling.python, "-m", "ansiblelint", "--version"]
    ).splitlines()[:1]
    if not ansible_lint_line or ansible_lint_line[0].split()[:2] != [
        b"ansible-lint",
        b"26.6.0",
    ]:
        raise DeploymentError("published ansible-lint version is invalid")

    galaxy_output = output(
        [
            tooling.python,
            "-m",
            "ansible.cli.galaxy",
            "collection",
            "list",
            "--collections-path",
            tooling.collections,
            "--format",
            "json",
        ]
    )
    try:
        galaxy_payload = json.loads(galaxy_output.decode("utf-8"))
    except (UnicodeError, ValueError, RecursionError) as error:
        raise DeploymentError("published collection manifest is invalid") from error
    installed_collections = {}
    if not isinstance(galaxy_payload, dict):
        raise DeploymentError("published collection manifest is invalid")
    for collection_root in galaxy_payload.values():
        if not isinstance(collection_root, dict):
            raise DeploymentError("published collection manifest is invalid")
        for name, details in collection_root.items():
            if (
                type(name) is not str
                or not isinstance(details, dict)
                or type(details.get("version")) is not str
                or name in installed_collections
            ):
                raise DeploymentError("published collection manifest is invalid")
            installed_collections[name] = details["version"]
    if any(
        installed_collections.get(name) != version
        for name, version in expected_collections.items()
    ):
        raise DeploymentError("published collection versions are invalid")

    return (
        json.dumps(
            {
                "ansible_core": "2.21.2",
                "ansible_lint": "26.6.0",
                "collections": installed_collections,
                "pip_freeze": freeze_lines,
                "python": python_version,
            },
            sort_keys=True,
            separators=(",", ":"),
        ).encode("ascii")
        + b"\n"
    )


def _parse_collection_requirements(payload: bytes) -> dict[str, str]:
    try:
        lines = payload.decode("utf-8").splitlines()
    except UnicodeDecodeError as error:
        raise DeploymentError("collection requirements are invalid") from error
    collections = {}
    current_name = None
    for raw_line in lines:
        line = raw_line.strip()
        if not line or line.startswith("#") or line in ("---", "collections:"):
            continue
        if line.startswith("- name: ") and current_name is None:
            current_name = line[len("- name: ") :]
            if re.fullmatch(r"[a-z0-9_]+\.[a-z0-9_]+", current_name) is None:
                raise DeploymentError("collection requirements are invalid")
            continue
        if line.startswith("version: ") and current_name is not None:
            version = line[len("version: ") :]
            if (
                re.fullmatch(r"[0-9]+(?:\.[0-9]+)*", version) is None
                or current_name in collections
            ):
                raise DeploymentError("collection requirements are invalid")
            collections[current_name] = version
            current_name = None
            continue
        raise DeploymentError("collection requirements are invalid")
    if current_name is not None or not collections:
        raise DeploymentError("collection requirements are invalid")
    return collections


def prepare_tooling(
    config: Config,
    checkout: Path,
    expected_sha: str | None = None,
) -> Tooling:
    """Build and atomically publish immutable tooling for this candidate."""

    _validate_protected_config(config)
    requirement_names = ("controller-requirements.txt", "requirements.yml")
    if expected_sha is None:
        requirement_payloads = [
            _read_tooling_requirement(checkout, relative_path)
            for relative_path in requirement_names
        ]
    else:
        requirement_payloads = [
            _read_reviewed_requirement(config, expected_sha, relative_path)
            for relative_path in requirement_names
        ]
    identity = _tooling_identity_payloads(requirement_payloads)
    expected_collections = _parse_collection_requirements(requirement_payloads[1])
    published = config.tooling_root / identity
    if published.exists() or published.is_symlink():
        return _validate_tooling(published, identity, _owned_root(config))

    staging = Path(
        tempfile.mkdtemp(prefix=f".{identity}.", dir=str(config.tooling_root))
    ).absolute()
    staging.chmod(0o700)
    try:
        staged_inputs = staging / ".inputs"
        staged_inputs.mkdir(mode=0o700)
        ansible_build_config = staging / ".ansible-build.cfg"
        ansible_build_config.write_bytes(b"[defaults]\n")
        ansible_build_config.chmod(0o600)
        for relative_path, payload in zip(
            requirement_names,
            requirement_payloads,
        ):
            staged_input = staged_inputs / relative_path
            staged_input.write_bytes(payload)
            staged_input.chmod(0o600)
        venv = staging / "venv"
        result = _run_command(
            [
                str(_validate_controller_python(config)),
                "-m",
                "venv",
                "--copies",
                str(venv),
            ],
            cwd=staging,
            env=_tooling_environment(
                _owned_root(config),
                ansible_config=ansible_build_config,
            ),
            timeout=TOOLING_TIMEOUT_SECONDS,
        )
        _checked_output(result)
        _remove_standard_venv_symlink(venv)
        staging_tooling = _tooling_paths(staging)
        result = _run_command(
            [
                str(staging_tooling.python),
                "-m",
                "pip",
                "--isolated",
                "install",
                "--disable-pip-version-check",
                "--no-input",
                "--requirement",
                str(staged_inputs / "controller-requirements.txt"),
            ],
            cwd=staging,
            env=_tooling_environment(
                _owned_root(config),
                staging_tooling.collections,
                ansible_build_config,
            ),
            timeout=TOOLING_TIMEOUT_SECONDS,
        )
        _checked_output(result)
        galaxy = staging / "venv" / "bin" / "ansible-galaxy"
        result = _run_command(
            [
                str(galaxy),
                "collection",
                "install",
                "--requirements-file",
                str(staged_inputs / "requirements.yml"),
                "--collections-path",
                str(staging_tooling.collections),
            ],
            cwd=staging,
            env=_tooling_environment(
                _owned_root(config),
                staging_tooling.collections,
                ansible_build_config,
            ),
            timeout=TOOLING_TIMEOUT_SECONDS,
        )
        _checked_output(result)
        _materialize_internal_symlinks(staging)
        _install_relocatable_ansible_wrapper(staging_tooling.ansible_playbook)
        _write_seal_file(
            staging,
            ".installed",
            _capture_installed_tooling_manifest(
                staging_tooling,
                _owned_root(config),
                expected_collections,
            ),
        )
        _seal_tooling(staging, identity)
        _validate_tooling(staging, identity, _owned_root(config))
        try:
            os.rename(staging, published)
            staging = None
            root_descriptor = os.open(
                config.tooling_root,
                os.O_RDONLY | getattr(os, "O_DIRECTORY", 0),
            )
            try:
                os.fsync(root_descriptor)
            finally:
                os.close(root_descriptor)
        except OSError as error:
            if error.errno not in (errno.EEXIST, errno.ENOTEMPTY):
                raise
        return _validate_tooling(published, identity, _owned_root(config))
    except (OSError, subprocess.SubprocessError) as error:
        raise DeploymentError("tooling could not be published") from error
    finally:
        if staging is not None:
            _remove_private_staging(staging)


def resolve_main_sha(config: Config) -> str:
    """Resolve the exact production branch SHA through anonymous HTTPS Git."""

    _validate_repository_url(config.repository_url)
    try:
        result = _run_command(
            [
                str(_trusted_git_path()),
                "--no-replace-objects",
                "ls-remote",
                "--exit-code",
                config.repository_url,
                f"refs/heads/{config.branch}",
            ],
            cwd=config.controller_root,
            env=_minimal_environment(_owned_root(config)),
            timeout=GIT_TIMEOUT_SECONDS,
        )
    except (DeploymentError, OSError, subprocess.SubprocessError) as error:
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


def _deployment_environment(
    config: Config,
    checkout: Path,
    tooling: Tooling,
) -> dict[str, str]:
    environment = _minimal_environment(_owned_root(config))
    environment.update(
        {
            "PATH": (
                f"{tooling.ansible_playbook.parent}{os.pathsep}{SAFE_SYSTEM_PATH}"
            ),
            "PLATFORM_NAS_ADDRESS": config.platform_nas_address,
            "PLATFORM_PUBLIC_HOST": config.platform_public_host,
            "PLATFORM_CALLBACK_HOST": config.platform_callback_host,
            "PLATFORM_VAULT_FILE": str(config.vault_file),
            "ANSIBLE_CONFIG": str(checkout / "ansible.cfg"),
            "ANSIBLE_COLLECTIONS_PATH": str(tooling.collections),
        }
    )
    return environment


def _validate_tooling_for_execution(config: Config, tooling: Tooling) -> Tooling:
    root = tooling.python.parent.parent.parent
    try:
        identity = _decode_single_line((root / ".complete").read_bytes())
    except OSError as error:
        raise DeploymentError("published tooling is incomplete") from error
    if SHA_PATTERN.fullmatch(identity) is None:
        raise DeploymentError("published tooling is incomplete")
    validated = _validate_tooling(root, identity, _owned_root(config))
    if validated != tooling:
        raise DeploymentError("published tooling identity changed")
    return validated


def _playbook_arguments(
    config: Config,
    tooling: Tooling,
    playbook: str,
    *,
    inventory: bool,
) -> list[str]:
    arguments = [str(tooling.ansible_playbook)]
    if inventory:
        arguments.extend(["-i", "inventory/local.yml"])
    arguments.extend(
        [
            playbook,
            "--vault-password-file",
            str(config.vault_password_file),
            "-e",
            f"@{config.vault_file}",
            "-e",
            f"platform_vault_file={config.vault_file}",
        ]
    )
    return arguments


def deploy_candidate(config: Config, sha: str, log) -> bool:
    """Deploy, verify, and activate one exact eligible candidate."""

    try:
        checkout = prepare_checkout(config, sha)
        _validate_materialized_checkout(config, sha)
        tooling = prepare_tooling(config, checkout, expected_sha=sha)
        environment = _deployment_environment(config, checkout, tooling)
        plays = (
            ("validate-vault.yml", False),
            ("site.yml", True),
            ("verify.yml", True),
            ("install-production-auto-deploy.yml", True),
        )
        for playbook, inventory in plays:
            _validate_materialized_checkout(config, sha)
            _validate_tooling_for_execution(config, tooling)
            result = _run_command(
                _playbook_arguments(
                    config,
                    tooling,
                    playbook,
                    inventory=inventory,
                ),
                cwd=checkout,
                env=environment,
                timeout=COMMAND_TIMEOUT_SECONDS,
                log=log,
            )
            if result.returncode != 0:
                return False
        return True
    except (DeploymentError, OSError, subprocess.SubprocessError):
        return False


def attempt_candidate(config: Config, sha: str) -> bool:
    """Deploy through a protected temporary sink until durable logs are added."""

    with tempfile.TemporaryFile(mode="w+b", dir=str(config.log_root)) as attempt_log:
        os.fchmod(attempt_log.fileno(), 0o600)
        return deploy_candidate(config, sha, attempt_log)


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
    _validate_protected_config(config)
    _validate_controller_python(config)
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
    except DeploymentError:
        print("production auto-deploy: unsafe controller runtime", file=sys.stderr)
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
