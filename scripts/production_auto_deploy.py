#!/usr/bin/env python3
"""Fail-closed GitHub Actions eligibility gate for production deployments."""

from __future__ import annotations

from contextlib import contextmanager
from dataclasses import dataclass, fields
from http.client import HTTPException
import json
import os
from pathlib import Path
import re
import shutil
import signal
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


class ConfigurationError(ValueError):
    """The fixed production configuration is invalid or unsafe."""


class EligibilityError(RuntimeError):
    """The candidate's CI eligibility could not be established safely."""


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
    if (
        repository_name != config.repository
        or workflow_path != expected_workflow_path
    ):
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


def main(
    argv: Sequence[str] | None = None,
    *,
    config_path: str | os.PathLike[str] = DEFAULT_CONFIG_PATH,
) -> int:
    """Evaluate the current production candidate without mutating deployment state."""

    arguments = list(sys.argv[1:] if argv is None else argv)
    if arguments:
        print("production auto-deploy: invalid arguments", file=sys.stderr)
        return 2

    try:
        config = load_config(config_path)
        head_sha = resolve_main_sha(config)
        runs = fetch_ci_runs(config, head_sha)
        run = eligible_ci_run(config, head_sha, runs)
    except ConfigurationError:
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
