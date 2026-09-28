#!/usr/bin/env python3
"""Deploy the newest main revision on the NAS that CI has released."""

from __future__ import annotations

import contextlib
from contextlib import contextmanager
from dataclasses import dataclass, fields, replace
from datetime import datetime, timedelta, timezone
import fcntl
import html
from http.client import HTTPException
import json
import os
from pathlib import Path
import re
import selectors
import signal
import subprocess
import sys
import tempfile
import time
from typing import Iterator
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode, urlsplit, urlunsplit
from urllib.request import Request, urlopen

SHA_PATTERN = re.compile(r"[0-9a-f]{40}")
# Named LOG_PATTERN so rotate_logs stays byte-identical to image_prune.py's (#658).
LOG_PATTERN = re.compile(r"(\d{8}T\d{6}Z)-[0-9a-f]{40}")
TIMESTAMP_PATTERN = re.compile(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z")
ATTEMPTED_RETENTION_COUNT = 50
ATTEMPTED_RETENTION_DAYS = 90
MAX_RESPONSE_BYTES = 1024 * 1024
# One page of recent runs; it bounds how far back a poll can see. Unfiltered by
# status since #916, so in-flight runs take slots too.
CI_RUN_PAGE_SIZE = 30
READ_SIZE = 64 * 1024
NETWORK_TIMEOUT_SECONDS = 10
GIT_TIMEOUT_SECONDS = 10
# Not the hour-long COMMAND_TIMEOUT_SECONDS: the fetch runs under the deployment
# lock, and a blackholed connection parked that lock for an hour (#351).
GIT_FETCH_TIMEOUT_SECONDS = 3 * 60
# No network, but a stuck filesystem still holds the lock, so bounded too.
GIT_LOCAL_TIMEOUT_SECONDS = 60
NOTIFICATION_TIMEOUT_SECONDS = 10
# Tests raise the notification budget on loaded machines (#319); capped at five minutes.
NOTIFICATION_TIMEOUT_ENVIRONMENT = "PLATFORM_AUTO_DEPLOY_NOTIFICATION_TIMEOUT_SECONDS"
NOTIFICATION_TIMEOUT_CEILING_SECONDS = 5 * 60
# curl's total budget for one healthchecks.io ping (#606); runs after the lock is released.
HEALTHCHECKS_TIMEOUT_SECONDS = 10
# Byte for byte the vault contract's HTTPS_URL in filter_plugins/vault_credential_schema.py
# (held by tests/policy_vault_test.rb): no whitespace, quote or backslash a curl config would misread.
HEALTHCHECKS_URL_PATTERN = re.compile(r'^https://[^\s"\\]+\Z')
# Consecutive polls failing before eligibility is decided: a quarter hour at the cron cadence.
BLIND_POLL_THRESHOLD = 3
# Pushover's caps, held identical across the copy sites by tests/policy_test.rb.
# Over any of them is a lost message. The escaped-field bound applies after escaping.
MAX_ESCAPED_FIELD_CHARACTERS = 384
MAX_MESSAGE_CHARACTERS = 1024
MAX_TITLE_CHARACTERS = 250
MAX_URL_CHARACTERS = 512
MAX_URL_TITLE_CHARACTERS = 100
COMMAND_TIMEOUT_SECONDS = 60 * 60
# Half the hourly cadence, so a stuck verify fails before the next is due (#351).
VERIFY_TIMEOUT_SECONDS = 30 * 60
# Per hourly-only tag, after the services in the same lock hold.
HOURLY_ONLY_VERIFY_TIMEOUT_SECONDS = 10 * 60
# How long --verify waits for a deployment to release the lock before skipping the
# hour. A skip pings nothing, and two skips alert, so a collision waits instead.
VERIFY_LOCK_WAIT_SECONDS = 15 * 60
LOCK_WAIT_POLL_SECONDS = 10
# One palette, held identical across the copy sites by tests/policy_test.rb.
COLOR_GREEN = "#2e7d32"
COLOR_RED = "#c62828"
COLOR_AMBER = "#f9a825"
COLOR_GREY = "#9e9e9e"
# "degraded" only when the log carries verify_mdraid.yml's fail_msg literal; any other
# failure, a timeout included, is "unchecked": the check could not run.
MDRAID_MISMATCH_MARKER = "MDRAID-BASELINE-MISMATCH"
# The same for roles/immich/tasks/verify_originals.yml (#907).
IMMICH_ORIGINALS_MISSING_MARKER = "IMMICH-ORIGINALS-MISSING"
HOURLY_ONLY_VERIFY_CHECKS = {
    "platform_verify_mdraid": {
        "marker": MDRAID_MISMATCH_MARKER,
        "fail": (
            "\U0001f7e0 RAID degraded",
            f'<b>RAID arrays</b> are <font color="{COLOR_AMBER}">degraded</font>',
            "<i>Read /proc/mdstat on the host; the log names the arrays that differ.</i>",
        ),
        "unchecked": (
            "❔ RAID check could not run",
            f'<b>RAID check</b> <font color="{COLOR_AMBER}">could not run</font>',
            "<i>This says nothing about the disks; the log names what stopped the check.</i>",
        ),
        "recovered": (
            "\U0001f7e2 RAID healthy",
            f'<b>RAID arrays</b> are <font color="{COLOR_GREEN}">healthy</font> again',
            "",
        ),
        "restored": (
            "\U0001f7e2 RAID check running again",
            f'<b>RAID check</b> <font color="{COLOR_GREEN}">runs</font> again',
            "",
        ),
    },
    "platform_verify_immich_originals": {
        "marker": IMMICH_ORIGINALS_MISSING_MARKER,
        "fail": (
            "\U0001f7e0 Immich originals missing",
            f'<b>Immich originals</b> are <font color="{COLOR_AMBER}">missing</font> for sampled assets',
            "<i>Files moved or deleted outside Immich; the log gives the sampled count.</i>",
        ),
        "unchecked": (
            "❔ Immich originals check could not run",
            f'<b>Immich originals check</b> <font color="{COLOR_AMBER}">could not run</font>',
            "<i>This says nothing about the files; the log names what stopped the check.</i>",
        ),
        "recovered": (
            "\U0001f7e2 Immich originals present",
            f'<b>Immich originals</b> are <font color="{COLOR_GREEN}">present</font> again',
            "",
        ),
        "restored": (
            "\U0001f7e2 Immich originals check running again",
            f'<b>Immich originals check</b> <font color="{COLOR_GREEN}">runs</font> again',
            "",
        ),
    },
}
TOOLING_TIMEOUT_SECONDS = 15 * 60
# Retry ladder for the three commands that reach a third party. Spent under the
# deployment lock, hence seconds.
NETWORK_RETRY_ATTEMPTS = 3
NETWORK_RETRY_BACKOFF_SECONDS = (2, 5)
# Transient failures forgiven per revision before it is quarantined anyway.
TRANSIENT_FORGIVENESS_LIMIT = 3
# Tells the plays the lock holder is this run's ancestor, so deployment_bundle's
# lock probe does not refuse our own converge. Advisory, not a credential.
LOCK_OWNER_ENVIRONMENT = "PLATFORM_DEPLOYMENT_LOCK_OWNER"
# Where site.yml writes what a release shipped (#558); only deploy() exports it.
SUMMARY_PATH_ENVIRONMENT = "PLATFORM_DEPLOYMENT_SUMMARY_PATH"
# Anonymous GitHub API: 60 requests/hour, 12 spent by polls.
MAX_PULL_REQUEST_LOOKUPS = 8
PULL_REQUEST_LOOKUP_BUDGET_SECONDS = 30


class ConfigurationError(ValueError):
    """The on-disk configuration cannot be trusted to drive a deployment."""


class EligibilityError(RuntimeError):
    """No candidate revision could be established for this poll."""


class DeploymentError(RuntimeError):
    """The candidate revision could not be deployed."""


class TransientDeploymentError(DeploymentError):
    """Failed before the first play, for a reason that says nothing about the revision."""


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
    vault_password_file: Path
    platform_nas_address: str
    platform_public_host: str
    platform_callback_host: str
    github_api_base: str
    log_retention_days: int
    verify_tags: str
    # Checks only the hourly --verify runs; comma-separated, optional (see load_config).
    hourly_only_verify_tags: str
    # Discovered by the installer; NAS firmwares scatter binaries.
    git_path: Path
    curl_path: Path
    tool_path: str
    # Ansible needs a UTF-8 locale and cron supplies none; the installer finds one.
    ansible_locale: str
    # Replayed so the reinstall play accepts its own invocation.
    external_scheduler: bool
    # Secret healthchecks.io ping URLs (#606, #610). Empty means no ping.
    healthchecks_poller_ping_url: str = ""
    healthchecks_verify_ping_url: str = ""
    # Protected curl configs holding each Pushover app's token (#558). None: cannot publish.
    pushover_alerts_curl_config: Path | None = None
    pushover_deployments_curl_config: Path | None = None


_PATH_FIELDS = frozenset(
    {
        "checkout",
        "state_root",
        "log_root",
        "vault_password_file",
        "git_path",
        "curl_path",
    }
)
_PING_URL_FIELDS = frozenset(
    {"healthchecks_poller_ping_url", "healthchecks_verify_ping_url"}
)
_PUSHOVER_FIELDS = frozenset(
    {"pushover_alerts_curl_config", "pushover_containers_curl_config", "pushover_deployments_curl_config"}
)


def _read_config_payload(path: str | os.PathLike[str]) -> dict:
    """The configuration file's JSON object, or a refusal naming why not."""

    try:
        payload = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, UnicodeError, ValueError) as error:
        raise ConfigurationError("configuration is unreadable") from error
    if not isinstance(payload, dict):
        raise ConfigurationError("configuration is not an object")
    return payload


def _pushover_config_path(raw) -> Path | None:
    """One Pushover curl config path, or None when it cannot be published to."""

    # Never a refusal (#327): an older template's file must still deploy.
    usable = type(raw) is str and Path(raw).is_absolute()
    return Path(raw) if usable else None


def _ping_url(raw) -> str:
    """One healthchecks.io ping URL, or "" when there is none to ping."""

    # Never a refusal (#327): absent or unusable reads as "no ping".
    usable = type(raw) is str and HEALTHCHECKS_URL_PATTERN.match(raw)
    return raw if usable else ""


def _required_config_value(name: str, raw):
    """One present, required field's value, typed, or a refusal."""

    if name == "external_scheduler":
        if type(raw) is not bool:
            raise ConfigurationError("external_scheduler must be a boolean")
        return raw
    if name == "log_retention_days":
        if type(raw) is not int or raw < 1:
            raise ConfigurationError(
                "log_retention_days must be a positive integer"
            )
        return raw
    if type(raw) is not str or not raw:
        raise ConfigurationError(f"{name} must be a non-empty string")
    if name in _PATH_FIELDS:
        candidate = Path(raw)
        if not candidate.is_absolute():
            raise ConfigurationError(f"{name} must be absolute")
        return candidate
    return raw


def _config_values(payload: dict, unpublishable: list) -> dict[str, object]:
    """Every Config field's value, naming each unusable Pushover field."""

    values: dict[str, object] = {}
    for field in fields(Config):
        if field.name in _PUSHOVER_FIELDS:
            values[field.name] = _pushover_config_path(payload.get(field.name))
            if values[field.name] is None:
                unpublishable.append(field.name)
            continue
        if field.name in _PING_URL_FIELDS:
            values[field.name] = _ping_url(payload.get(field.name, ""))
            continue
        if field.name not in payload:
            # Absent in an older template's file (#327): no hourly-only checks.
            if field.name == "hourly_only_verify_tags":
                values[field.name] = ""
                continue
            raise ConfigurationError(f"configuration is missing {field.name}")
        values[field.name] = _required_config_value(field.name, payload[field.name])
    return values


def load_config(path: str | os.PathLike[str]) -> Config:
    """Read the non-secret poller configuration written by the installer role."""

    payload = _read_config_payload(path)
    unpublishable = []
    values = _config_values(payload, unpublishable)
    # Two URLs for one check: ping neither, so both checks alert.
    if values["healthchecks_poller_ping_url"] and healthchecks_check_identity(
        values["healthchecks_poller_ping_url"]
    ) == healthchecks_check_identity(values["healthchecks_verify_ping_url"]):
        values["healthchecks_poller_ping_url"] = ""
        values["healthchecks_verify_ping_url"] = ""
    for url_field in ("repository_url", "github_api_base"):
        if urlsplit(str(values[url_field])).scheme != "https":
            raise ConfigurationError(f"{url_field} must be https")
    if unpublishable:
        print(
            "production auto-deploy: nothing can be published to Pushover through "
            f"{', '.join(unpublishable)}, which the configuration does not name",
            file=sys.stderr,
        )
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

    The deadline covers the read loop: a grandchild can hold the stdout pipe open.
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


def _run_network_command(
    arguments, *, failure: str, budget: float, **options
) -> subprocess.CompletedProcess:
    """Run one command that reaches a third party, under a total deadline (#351).

    Every attempt draws from one budget; only fast non-zero exits are retried,
    never a timeout. An exhausted ladder raises TransientDeploymentError.
    """

    deadline = time.monotonic() + budget
    for attempt in range(NETWORK_RETRY_ATTEMPTS):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            break
        try:
            result = _run(arguments, timeout=remaining, **options)
        except subprocess.TimeoutExpired as error:
            raise TransientDeploymentError(f"{failure} (timed out)") from error
        if result.returncode == 0:
            return result
        if attempt + 1 < NETWORK_RETRY_ATTEMPTS:
            time.sleep(NETWORK_RETRY_BACKOFF_SECONDS[attempt])
    raise TransientDeploymentError(failure)


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


def fetch_ci_runs(config: Config) -> tuple[dict, ...]:
    """Fetch one bounded page of push runs for the production branch.

    No `status` filter: status=completed returned weeks-stale runs (#916).
    """

    query = urlencode(
        {
            "branch": config.branch,
            "event": "push",
            "per_page": str(CI_RUN_PAGE_SIZE),
        }
    )
    payload = _github_get(config, f"actions/workflows/{config.workflow}/runs?{query}")
    try:
        runs = payload["workflow_runs"]
    except (KeyError, TypeError) as error:
        raise EligibilityError("GitHub response is invalid") from error
    if not isinstance(runs, list):
        raise EligibilityError("GitHub response is invalid")
    return tuple(run for run in runs if isinstance(run, dict))


def _github_get(config: Config, path: str, timeout: float = NETWORK_TIMEOUT_SECONDS):
    """One bounded, anonymous GitHub API read as JSON; EligibilityError otherwise."""

    request = Request(
        f"{config.github_api_base.rstrip('/')}/repos/{config.repository}/{path}",
        method="GET",
        headers={
            "Accept": "application/vnd.github+json",
            "User-Agent": "nas-platform-production-auto-deploy",
            "X-GitHub-Api-Version": "2022-11-28",
        },
    )
    try:
        with urlopen(request, timeout=timeout) as response:
            body = response.read(MAX_RESPONSE_BYTES + 1)
    except (HTTPError, URLError, HTTPException, OSError, TimeoutError) as error:
        raise EligibilityError("GitHub request failed") from error
    if len(body) > MAX_RESPONSE_BYTES:
        raise EligibilityError("GitHub response is too large")
    try:
        return json.loads(body.decode("utf-8"))
    except (UnicodeError, ValueError, RecursionError) as error:
        raise EligibilityError("GitHub response is invalid") from error


def pull_request_url(config: Config, sha: str, timeout: float = NETWORK_TIMEOUT_SECONDS) -> str | None:
    """The pull request that brought a commit to main, or None if it came without one.

    Renovate rebases, so GitHub's commit-to-PR index is the only record.
    """

    payload = _github_get(config, f"commits/{sha}/pulls", timeout)
    if not isinstance(payload, list):
        raise EligibilityError("GitHub response is invalid")
    for pull in payload:
        url = pull.get("html_url") if isinstance(pull, dict) else None
        if isinstance(url, str) and _usable_url(url):
            return url
    return None


def release_pull_requests(config: Config, shas) -> dict[str, str]:
    """Pull request links for a release's image commits, within the anonymous budget.

    The first failure ends the lookups; the cost is links, never the message.
    """

    links: dict[str, str] = {}
    deadline = time.monotonic() + PULL_REQUEST_LOOKUP_BUDGET_SECONDS
    for sha in list(dict.fromkeys(shas))[:MAX_PULL_REQUEST_LOOKUPS]:
        remaining = deadline - time.monotonic()
        try:
            if remaining <= 0:
                raise EligibilityError("GitHub lookups ran out of time")
            url = pull_request_url(config, sha, min(NETWORK_TIMEOUT_SECONDS, remaining))
        except EligibilityError as error:
            print(f"production auto-deploy: release notes links omitted: {error}", file=sys.stderr)
            break
        if url is not None:
            links[sha] = url
    return links


def gating_ci_runs(config: Config, sha: str, runs) -> list[dict]:
    """Completed push runs of the gating workflow for this SHA, newest first."""

    return [
        run
        for run in runs
        if run.get("head_sha") == sha
        and run.get("status") == "completed"
        and run.get("event") == "push"
        and run.get("head_branch") == config.branch
        and run.get("name") == config.workflow_name
    ]


def candidate_revisions(config: Config, head: str, runs) -> list[str]:
    """The revisions one poll may consider, newest first: the head, then those CI judged.

    Every SHA past the head comes from the network and is validated before git sees it.
    """

    ordered = [head]
    for run in runs:
        sha = run.get("head_sha")
        if (
            isinstance(sha, str)
            and SHA_PATTERN.fullmatch(sha) is not None
            and sha not in ordered
            and run.get("status") == "completed"
            and run.get("event") == "push"
            and run.get("head_branch") == config.branch
            and run.get("name") == config.workflow_name
        ):
            ordered.append(sha)
    return ordered


# Only GREEN deploys. PENDING and SUPERSEDED are not judgements; the last two
# stop every deployment until a human intervenes.
CI_GREEN = "green"
CI_PENDING = "pending"
CI_SUPERSEDED = "superseded"
CI_FAILED = "failed"
CI_AMBIGUOUS = "ambiguous"

# Conclusions that end a run without judging the revision. Anything else,
# including an unknown conclusion, counts as a refusal.
UNJUDGED_CONCLUSIONS = frozenset(
    {"cancelled", "skipped", "stale", "neutral", "action_required"}
)


def _conclusion_of(run: dict) -> str:
    """The run's conclusion, or "unknown" when GitHub supplied nothing usable."""

    conclusion = run.get("conclusion")
    return conclusion if isinstance(conclusion, str) and conclusion else "unknown"


def _run_url(run: dict) -> str:
    """The run's web address, when GitHub supplied a usable one."""

    url = run.get("html_url")
    if not isinstance(url, str):
        return ""
    parts = urlsplit(url)
    if parts.scheme != "https" or not parts.netloc:
        return ""
    return url


def ci_verdict(config: Config, sha: str, runs) -> tuple[str, str, str]:
    """Classify CI for one revision as (verdict, detail, run URL).

    Exactly one successful run releases a revision. The newest run that reached a
    verdict decides; only unjudged runs means superseded, not refused.
    """

    gating = gating_ci_runs(config, sha, runs)
    successful = [run for run in gating if run.get("conclusion") == "success"]
    if len(successful) == 1:
        return CI_GREEN, "success", _run_url(successful[0])
    if len(successful) > 1:
        return (
            CI_AMBIGUOUS,
            f"{len(successful)} successful push runs exist, "
            "and exactly one is required",
            _run_url(successful[0]),
        )
    judged = [run for run in gating if _conclusion_of(run) not in UNJUDGED_CONCLUSIONS]
    if judged:
        return CI_FAILED, _conclusion_of(judged[0]), _run_url(judged[0])
    if gating:
        return CI_SUPERSEDED, _conclusion_of(gating[0]), _run_url(gating[0])
    return CI_PENDING, "no completed run yet", ""


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


def _attempted_path(config: Config) -> Path:
    return config.state_root / "attempted"


def _read_attempts(config: Config) -> list[tuple[str, str | None]]:
    """Every recorded attempt, oldest first; a bare SHA from an older poller is accepted."""

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
    """Bound the record by count and age; the just-appended attempt is always kept."""

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


def prune_attempts(config: Config, now: datetime) -> None:
    """Trim the attempted record to its retention bounds, every tick.

    Written back only when something was removed, to spare the NAS's flash.
    """

    attempts = _read_attempts(config)
    kept = _prune_attempts(attempts, now)
    if kept != attempts:
        _store_attempts(config, kept)


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


def _transient_path(config: Config) -> Path:
    return config.state_root / "transient-failures"


def read_transient_failures(config: Config) -> tuple[str | None, int]:
    """The revision being forgiven and its tick count; unreadable state reads as none."""

    try:
        parts = _transient_path(config).read_text(encoding="ascii").split()
    except (OSError, UnicodeError):
        return (None, 0)
    if len(parts) != 2 or SHA_PATTERN.fullmatch(parts[0]) is None:
        return (None, 0)
    try:
        count = int(parts[1])
    except ValueError:
        return (None, 0)
    return (parts[0], count if count > 0 else 0)


def clear_transient_failures(config: Config) -> None:
    with contextlib.suppress(OSError):
        _transient_path(config).unlink()


def may_retry_after_transient_failure(config: Config, sha: str) -> bool:
    """Whether the next tick may attempt this revision again, and count that it did.

    Per revision, bounded by TRANSIENT_FORGIVENESS_LIMIT. Fails closed: an
    unwritable counter cannot bound the forgiveness it grants.
    """

    recorded, count = read_transient_failures(config)
    count = count + 1 if recorded == sha else 1
    if count > TRANSIENT_FORGIVENESS_LIMIT:
        clear_transient_failures(config)
        return False
    try:
        _write_private(_transient_path(config), f"{sha} {count}\n".encode("ascii"))
    except OSError:
        return False
    return True


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


def lock_path(config: Config) -> Path:
    """The one file every deployment serialises on; roles/deployment_bundle derives the same path."""

    return config.state_root / "deployment.lock"


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


def read_lock_holder(config: Config) -> dict | None:
    """The holder record, or None. Advisory only: may be absent or stale."""

    try:
        payload = json.loads(lock_path(config).read_text(encoding="ascii"))
    except (OSError, UnicodeError, ValueError):
        return None
    return payload if isinstance(payload, dict) else None


def _acquire_lock(descriptor: int, wait_seconds: float) -> bool:
    """Take the flock, re-attempting for wait_seconds. False: somebody still holds it.

    Polled because flock has no timeout and SIGALRM is process-global.
    """

    deadline = time.monotonic() + wait_seconds
    while True:
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return True
        except OSError:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return False
            time.sleep(min(LOCK_WAIT_POLL_SECONDS, remaining))


@contextmanager
def deployment_lock(config: Config, holder: str = "poll",
                    wait_seconds: float = 0.0) -> Iterator[bool]:
    """Serialise deployments; yield False when another holder already runs one."""

    descriptor = os.open(lock_path(config), os.O_WRONLY | os.O_CREAT, 0o600)
    try:
        if not _acquire_lock(descriptor, wait_seconds):
            yield False
            return
        _record_lock_holder(descriptor, holder)
        try:
            yield True
        finally:
            # Cleared while still held, so a reader never sees the last deployment's pid.
            with contextlib.suppress(OSError):
                os.ftruncate(descriptor, 0)
    finally:
        os.close(descriptor)


def deployment_lock_held(config: Config) -> bool:
    """Whether somebody holds the deployment lock, asked without becoming its holder.

    Read-only for --status; the same probe as
    roles/deployment_bundle/files/probe_deployment_lock.py.
    """

    try:
        descriptor = os.open(lock_path(config), os.O_RDONLY)
    except FileNotFoundError:
        return False
    try:
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            return True
        fcntl.flock(descriptor, fcntl.LOCK_UN)
        return False
    finally:
        os.close(descriptor)


def _tooling_bin(config: Config) -> Path:
    """The controller virtualenv the operator guide creates in the checkout."""

    return config.checkout / ".venv" / "bin"


def _collections_path(config: Config) -> Path:
    """Collections live beside the virtualenv, not under the operator's ~/.ansible."""

    return _tooling_bin(config).parent / "collections"


def _ansible_environment(config: Config) -> dict[str, str]:
    return {
        # ansible-core lives in the checkout's virtualenv.
        "PATH": f"{_tooling_bin(config)}{os.pathsep}{config.tool_path}",
        "HOME": str(config.checkout.parent),
        # Only LANG: LC_ALL and LANG together is rejected on some platforms.
        "LANG": config.ansible_locale,
        "GIT_TERMINAL_PROMPT": "0",
        "PLATFORM_NAS_ADDRESS": config.platform_nas_address,
        "PLATFORM_PUBLIC_HOST": config.platform_public_host,
        "PLATFORM_CALLBACK_HOST": config.platform_callback_host,
        "ANSIBLE_CONFIG": str(config.checkout / "ansible.cfg"),
        "ANSIBLE_COLLECTIONS_PATH": str(_collections_path(config)),
        # The holder the plays find is this pid; stops our own guard refusing us.
        LOCK_OWNER_ENVIRONMENT: str(os.getpid()),
    }


def _vault_arguments(config: Config) -> list[str]:
    """Only the password provider. Credentials belong to the revision.

    An outside vault copy as extra vars would silently shadow the committed one.
    """

    return [
        "-i",
        "inventory/local.yml",
        "--vault-password-file",
        str(config.vault_password_file),
    ]


def update_checkout(config: Config, sha: str, log=None) -> None:
    """Materialise the candidate revision in the controller checkout.

    The candidate must be an ancestor of the FETCH_HEAD just fetched. A failed fetch
    or any timeout is transient; a non-ancestor or failed checkout quarantines it.
    """

    environment = {
        "PATH": config.tool_path,
        "LC_ALL": "C",
        "GIT_TERMINAL_PROMPT": "0",
    }
    _run_network_command(
        [config.git_path, "fetch", "--prune", "origin", config.branch],
        failure=f"git fetch failed for {sha}",
        budget=GIT_FETCH_TIMEOUT_SECONDS,
        cwd=config.checkout,
        env=environment,
        log=log,
    )
    steps = (
        (
            [config.git_path, "merge-base", "--is-ancestor", sha, "FETCH_HEAD"],
            f"{sha} is not on {config.branch}",
        ),
        (
            [config.git_path, "checkout", "--detach", sha],
            f"git checkout failed for {sha}",
        ),
    )
    for arguments, failure in steps:
        try:
            result = _run(
                arguments,
                timeout=GIT_LOCAL_TIMEOUT_SECONDS,
                cwd=config.checkout,
                env=environment,
                log=log,
            )
        except subprocess.TimeoutExpired as error:
            raise TransientDeploymentError(f"{failure} (timed out)") from error
        if result.returncode != 0:
            raise DeploymentError(failure)


def sync_tooling(config: Config, log=None) -> None:
    """Match the controller virtualenv to the candidate's own pins, before any ansible runs."""

    # Reaches pypi.org, so it takes the ladder (#415). A hashed lock (#827): no
    # --upgrade, and --require-hashes refuses an unhashed entry.
    requirements = config.checkout / "controller-requirements.txt"
    _run_network_command(
        [
            _tooling_bin(config) / "pip",
            "install",
            "--quiet",
            "--require-hashes",
            "--requirement",
            str(requirements),
        ],
        failure="controller tooling could not be synchronised",
        budget=TOOLING_TIMEOUT_SECONDS,
        cwd=config.checkout,
        env={"PATH": config.tool_path, "LC_ALL": "C"},
        log=log,
    )

    # --no-cache: an interrupted run leaves a poisoned Galaxy cache entry in HOME
    # that fails every candidate for a day, with no merge able to heal it.
    _run_network_command(
        [
            _tooling_bin(config) / "ansible-galaxy",
            "collection",
            "install",
            "--force",
            "--no-cache",
            "--requirements-file",
            str(config.checkout / "requirements.yml"),
            "--collections-path",
            str(_collections_path(config)),
        ],
        failure="controller collections could not be synchronised",
        budget=TOOLING_TIMEOUT_SECONDS,
        cwd=config.checkout,
        env={
            "PATH": config.tool_path,
            "LANG": config.ansible_locale,
            "HOME": str(config.checkout.parent),
        },
        log=log,
    )


def _verify_invocation(config: Config, tags: str) -> list[str]:
    """verify.yml with a tag list: verify_tags, or one hourly-only tag at a time."""

    return [
        "ansible-playbook",
        *_vault_arguments(config),
        "verify.yml",
        "--tags",
        tags,
    ]


def _deploy_invocations(config: Config):
    """Every play's ansible-playbook invocation; only verify.yml gets the tag list."""

    vault = _vault_arguments(config)
    return (
        ["ansible-playbook", *vault, "validate-vault.yml"],
        ["ansible-playbook", *vault, "site.yml"],
        _verify_invocation(config, config.verify_tags),
        # The installer's own choices must be replayed.
        [
            "ansible-playbook",
            *vault,
            "install-production-auto-deploy.yml",
            "-e",
            f"production_auto_deploy_public_host={config.platform_public_host}",
            "-e",
            "production_auto_deploy_external_scheduler="
            f"{str(config.external_scheduler).lower()}",
        ],
    )


def deploy(config: Config, sha: str, log) -> bool:
    """Deploy one candidate revision, stopping at the first failing play.

    False: this revision failed. TransientDeploymentError: it never reached the target.
    """

    # Only here: an operator's converge must never make site.yml write a summary.
    environment = _ansible_environment(config) | {
        SUMMARY_PATH_ENVIRONMENT: str(_summary_path(config))
    }
    try:
        update_checkout(config, sha, log=log)
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
    except TransientDeploymentError:
        raise
    except (DeploymentError, OSError, subprocess.SubprocessError):
        return False
    return True


def _timestamp(now: datetime | None = None) -> str:
    """Render a moment as the second-resolution UTC stamp both scripts write.

    Identical to the copy in the other script by construction, and
    tests/policy_test.rb compares the two definitions as text so it stays that
    way (#423). Prose true of only one script goes in a comment above the def,
    which that comparison does not read.
    """

    moment = datetime.now(timezone.utc) if now is None else now
    return moment.strftime("%Y-%m-%dT%H:%M:%SZ")


@contextmanager
def run_log(config: Config, suffix: str):
    """Open one private run log and point 'latest' at it.

    Identical to the copy in the other script by construction, and
    tests/policy_test.rb compares the two definitions as text so it stays that
    way (#423). Prose true of only one script goes in a comment above the def,
    which that comparison does not read.
    """

    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    path = config.log_root / f"{stamp}-{suffix}"
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
    """Delete run logs older than the configured retention window.

    Identical to the copy in the other script by construction, and
    tests/policy_test.rb compares the two definitions as text so it stays that
    way (#423). Prose true of only one script goes in a comment above the def,
    which that comparison does not read.
    """

    cutoff = now - timedelta(days=config.log_retention_days)
    try:
        entries = list(config.log_root.iterdir())
    except OSError:
        return
    for entry in entries:
        match = LOG_PATTERN.fullmatch(entry.name)
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


def format_duration(seconds: int) -> str:
    """Render an elapsed span as hours, minutes and seconds.

    Identical to the copy in the other script by construction, and
    tests/policy_test.rb compares the two definitions as text so it stays that
    way (#423). Prose true of only one script goes in a comment above the def,
    which that comparison does not read.
    """

    if seconds < 0:
        return "unknown"
    minutes, seconds = divmod(seconds, 60)
    hours, minutes = divmod(minutes, 60)
    if hours:
        return f"{hours}h {minutes}m {seconds}s"
    if minutes:
        return f"{minutes}m {seconds}s"
    return f"{seconds}s"


# Parses the recorded timestamps; format_duration decides the rest (#658).
def duration_between(started: str, finished: str) -> str:
    """Render the elapsed deployment time, or admit that it is not derivable."""

    try:
        span = datetime.strptime(finished, "%Y-%m-%dT%H:%M:%SZ") - datetime.strptime(
            started, "%Y-%m-%dT%H:%M:%SZ"
        )
    except ValueError:
        return "unknown"
    return format_duration(int(span.total_seconds()))


def commit_link(config: Config, sha: str) -> str:
    """The revision as an escaped <a href> to its commit page, for an html=1 message."""

    repository = html_escape(config.repository)
    return f'<a href="https://github.com/{repository}/commit/{sha}">{sha[:12]}</a>'


def run_link(url: str) -> str:
    """A CI run as an <a href> for a detail line, or "" when it is not a usable link."""

    if not _usable_url(url):
        return ""
    # _usable_url held it to 512 characters, so this escape never cuts it.
    href = html_escape(url, MAX_URL_CHARACTERS, 6 * MAX_URL_CHARACTERS)
    return f'\U0001f9ea <b>CI</b> <a href="{href}">the run that released it</a>'


def log_line(log_path: Path) -> str:
    return f'\U0001f4c4 <b>Log</b> <font color="{COLOR_GREY}">{html_escape(str(log_path))}</font>'


def readable_time(stamp: str) -> str:
    """A _timestamp() value as `14 Sep 02:03 UTC`, or the value itself when it is not one."""

    try:
        moment = datetime.strptime(stamp, "%Y-%m-%dT%H:%M:%SZ")
    except ValueError:
        return html_escape(stamp)
    return f"{moment.day} {moment:%b %H:%M} UTC"


def render_notification(
    config: Config,
    sha: str,
    started: str,
    finished: str,
    log_path: Path,
    run_url: str = "",
    failure: str = "failed",
) -> dict:
    """Build the Pushover fields for a failed deployment.

    failure is "failed", "retrying" or "quarantined", as poll() left the revision.
    """

    details = [f"\U0001f516 <b>Revision</b> {commit_link(config, sha)}"]
    if run_link(run_url):
        details.append(run_link(run_url))
    details += [
        f"\U0001f552 <b>When</b> {readable_time(finished)}",
        f"⏱️ <b>Took</b> {duration_between(started, finished)}",
        log_line(log_path),
    ]
    closing = {
        "retrying": "<i>The poller retries this revision on a later poll, unless a newer green "
        "revision deploys first.</i>",
        "quarantined": "<i>The poller will not retry this revision; run nas-platform-deploy "
        f"--retry-failed {sha} once the cause is fixed.</i>",
    }.get(failure, "<i>The poller will not retry this revision; merge a fix to main.</i>")
    fields = {
        "title": f"\U0001f534 Deploy failed · {sha[:7]}",
        "message": compose_message(
            f'<b>Deployment</b> <font color="{COLOR_RED}">failed</font>', details, closing
        ),
        "priority": 1,
    }
    if run_url:
        fields |= {"url": run_url, "url_title": "Open CI run"}
    return fields


def notify(
    config: Config,
    sha: str,
    started: str,
    finished: str,
    log_path: Path,
    run_url: str = "",
    failure: str = "failed",
) -> bool:
    """Publish a failed deployment to the Alerts application."""

    return publish(
        config,
        "alerts",
        render_notification(config, sha, started, finished, log_path, run_url, failure),
    )


def _summary_path(config: Config) -> Path:
    return config.state_root / "deployment-summary.json"


_IMAGE_KINDS = frozenset({"updated", "added", "removed", "repinned"})


def read_release_summary(path: Path, candidate: str) -> dict:
    """The summary site.yml wrote for this very candidate; ValueError when there is none to trust."""

    try:
        with path.open("rb") as handle:
            raw = handle.read(MAX_RESPONSE_BYTES + 1)
    except FileNotFoundError as error:
        raise ValueError("site.yml wrote no release summary") from error
    except OSError as error:
        raise ValueError("the release summary is unreadable") from error
    if len(raw) > MAX_RESPONSE_BYTES:
        raise ValueError("the release summary is too large")
    summary = json.loads(raw.decode("utf-8"))
    if not isinstance(summary, dict) or type(summary.get("version")) is not int or summary["version"] != 1:
        raise ValueError("the release summary is not version 1")
    if summary.get("release") != candidate:
        raise ValueError("the release summary describes another release")

    def sha(value) -> bool:
        return isinstance(value, str) and SHA_PATTERN.fullmatch(value) is not None

    def optional_text(value) -> bool:
        return value is None or isinstance(value, str)

    images, commits = summary.get("images"), summary.get("commits")
    if (
        not (summary.get("previous") == "" or sha(summary.get("previous")))
        or not isinstance(images, list)
        or not isinstance(commits, list)
        or not all(
            isinstance(image, dict)
            and isinstance(image.get("name"), str)
            and image.get("kind") in _IMAGE_KINDS
            and optional_text(image.get("from"))
            and optional_text(image.get("to"))
            and (image.get("commit") is None or sha(image.get("commit")))
            for image in images
        )
        or not all(
            isinstance(commit, dict) and sha(commit.get("sha")) and isinstance(commit.get("subject"), str)
            for commit in commits
        )
    ):
        raise ValueError("the release summary is malformed")
    return summary


def _release_title(summary: dict) -> str:
    """Plain text that carries the whole meaning, because the lock screen shows no HTML."""

    images = summary["images"]
    names = list(dict.fromkeys(image["name"].split("/", 1)[0] for image in images))
    if len(images) == 1:
        what = f"{images[0]['name']} {images[0].get('to') or 'removed'}"
    elif names:
        what = ", ".join(names[:2]) + (f" +{len(names) - 2}" if len(names) > 2 else "")
    elif summary["commits"]:
        count = len(summary["commits"])
        what = f"{count} commit" if count == 1 else f"{count} commits"
    else:
        what = summary["release"][:7]
    return f"\U0001f680 Deployed · {what}"


def _release_image_line(image: dict, links: dict[str, str]) -> str:
    name = f"<b>{html_escape(image['name'])}</b>"
    before, after = html_escape(image.get("from") or ""), html_escape(image.get("to") or "")
    kind = image["kind"]
    if kind == "removed":
        return f'\U0001f5d1️ {name} <font color="{COLOR_GREY}">removed</font>'
    if kind == "updated":
        line = f'{name} {before} → <font color="{COLOR_GREEN}">{after}</font>'
    elif kind == "added":
        line = f'\U0001f195 {name} <font color="{COLOR_GREEN}">{after}</font>'
    else:
        line = f'{name} {after} <font color="{COLOR_GREY}">repinned</font>'
    link = links.get(image.get("commit") or "")
    if link:
        # _usable_url held it to 512 characters, so this escape never cuts it.
        href = html_escape(link, MAX_URL_CHARACTERS, 6 * MAX_URL_CHARACTERS)
        line += f' · <a href="{href}">release notes</a>'
    return line


def _release_message(image_lines: list[str], commit_lines: list[str], footer: str) -> str:
    """Sections of whole lines, cut to Pushover's cap without losing the footer.

    Commits give way before images; fit_message is only the backstop.
    """

    def compose(shown_images: int, shown_commits: int) -> list[str]:
        lines: list[str] = []
        for header, entries, shown, noun in (
            ("\U0001f4e6 <b>Images</b>", image_lines, shown_images, "image"),
            ("\U0001f4dd <b>Changes</b>", commit_lines, shown_commits, "change"),
        ):
            if not entries:
                continue
            lines += [header, *entries[:shown]]
            hidden = len(entries) - shown
            if hidden:
                lines.append(f"… and {hidden} more {noun}{'' if hidden == 1 else 's'}")
            lines.append("")
        return [*lines, footer]

    sizes = [(len(image_lines), shown) for shown in range(len(commit_lines), -1, -1)]
    sizes += [(shown, 0) for shown in range(len(image_lines) - 1, -1, -1)]
    for shown_images, shown_commits in sizes:
        lines = compose(shown_images, shown_commits)
        if len("\n".join(lines)) <= MAX_MESSAGE_CHARACTERS:
            break
    return fit_message(lines)


def render_release(
    config: Config, summary: dict, links: dict[str, str], started: str, finished: str
) -> dict:
    """Build the Deployments message for a release that deployed and verified."""

    release, previous = summary["release"], summary["previous"]
    repository = html_escape(config.repository)
    # Twelve-character SHAs keep the body under Pushover's 1024; the button keeps them whole.
    commit_lines = [
        f'• <a href="https://github.com/{repository}/commit/{commit["sha"][:12]}">'
        f"{html_escape(commit['subject'])}</a>"
        for commit in summary["commits"]
    ]
    duration = duration_between(started, finished)
    if previous:
        url = f"https://github.com/{config.repository}/compare/{previous}...{release}"
        revisions = (
            f'<a href="https://github.com/{repository}/compare/{previous[:12]}...{release[:12]}">'
            f"{previous[:7]} → {release[:7]}</a>"
        )
    else:
        url = f"https://github.com/{config.repository}/commit/{release}"
        revisions = release[:7]
    footer = f'⏱️ {duration} · <font color="{COLOR_GREY}">{revisions}</font>'
    return {
        "title": _release_title(summary),
        "message": _release_message(
            [_release_image_line(image, links) for image in summary["images"]], commit_lines, footer
        ),
        "priority": 0,
        "url": url,
        "url_title": "View changes on GitHub",
    }


def announce_release(config: Config, candidate: str, started: str, finished: str) -> None:
    """Send the one Deployments message for a release that deployed and verified.

    Never raises or retries; each failure costs the message or its links and one stderr line.
    """

    try:
        summary = read_release_summary(_summary_path(config), candidate)
    except Exception as error:  # Deliberately broad; see the docstring.
        print(f"production auto-deploy: no release message for {candidate[:9]}: {error}",
              file=sys.stderr)
        return
    try:
        links = release_pull_requests(
            config, [image["commit"] for image in summary["images"] if image.get("commit")]
        )
        delivered = publish(config, "deployments", render_release(config, summary, links, started, finished))
    except Exception:  # Deliberately broad; see the docstring.
        delivered = False
    if not delivered:
        print("production auto-deploy: release notification failed", file=sys.stderr)


def _notification_timeout() -> int:
    raw = os.environ.get(NOTIFICATION_TIMEOUT_ENVIRONMENT, "")
    # isdecimal rather than isdigit: "²" is a digit that int() refuses.
    if not raw.isascii() or not raw.isdecimal() or int(raw) < 1:
        return NOTIFICATION_TIMEOUT_SECONDS
    return min(int(raw), NOTIFICATION_TIMEOUT_CEILING_SECONDS)


def _usable_url(url: str) -> bool:
    parts = urlsplit(url)
    return parts.scheme == "https" and bool(parts.netloc) and len(url) <= MAX_URL_CHARACTERS


def publish(config: Config, app: str, fields: dict) -> bool:
    """Send one message to a Pushover application; True only if Pushover accepted it.

    Credentials stay in the app's curl config, never argv; fields go as --form-string.
    Never raises: a lost notification must not also stop a deployment.
    """

    curl_config = getattr(config, f"pushover_{app}_curl_config", None)
    if curl_config is None:
        return False
    form = dict(fields, html="1")
    form["title"] = str(form["title"])[:MAX_TITLE_CHARACTERS]
    if not _usable_url(str(form.get("url", ""))):
        form.pop("url", None)
        form.pop("url_title", None)
    elif "url_title" in form:
        form["url_title"] = str(form["url_title"])[:MAX_URL_TITLE_CHARACTERS]
    arguments = [
        config.curl_path,
        "--disable",
        "--silent",
        "--show-error",
        "--max-time",
        str(_notification_timeout()),
        "--config",
        str(curl_config),
    ]
    for key, value in form.items():
        arguments += ["--form-string", f"{key}={value}"]
    arguments += ["--write-out", "\n%{http_code}"]
    try:
        result = _run(
            arguments,
            timeout=_notification_timeout(),
            env={"PATH": config.tool_path, "LC_ALL": "C"},
        )
    except (OSError, ValueError, subprocess.SubprocessError):
        # ValueError is a NUL byte in a field: nothing was sent.
        return False
    verdict = pushover_verdict(result.returncode, result.stdout)
    if verdict == "refused":
        print(
            f"production auto-deploy: Pushover refused a message to the {app} "
            f"application; check vault_pushover_{app}_token and "
            "vault_pushover_user_key. Values are not shown.",
            file=sys.stderr,
        )
    elif result.returncode == 0 and result.stdout.rpartition(b"\n")[2].strip() == b"429":
        print(
            f"production auto-deploy: Pushover rate-limited a message to the {app} "
            "application (HTTP 429: its quota is spent); it is retried on a later run.",
            file=sys.stderr,
        )
    return verdict == "accepted"


def healthchecks_check_identity(url):
    """The check a healthchecks.io ping URL addresses, for telling two apart.

    Scheme and host compare case-insensitively, trailing slashes and the
    fragment address nothing, and the query is kept. Written byte for byte in
    filter_plugins/vault_credential_schema.py and scripts/production_auto_deploy.py,
    and tests/policy_vault_test.rb holds the two copies identical, so the vault
    contract and the poller always agree on when two URLs are one check (#606).
    """

    try:
        parts = urlsplit(url)
    except ValueError:
        return url
    return (parts.scheme.lower(), parts.netloc.lower(), parts.path.rstrip("/"),
            parts.query)


def _healthchecks_fail_url(url: str) -> str:
    """A ping URL's /fail sibling, on the path before any query (#606)."""

    parts = urlsplit(url)
    return urlunsplit(parts._replace(path=f"{parts.path.rstrip('/')}/fail", fragment=""))


def ping_healthchecks(config: Config, url: str, failed: bool) -> None:
    """Report one run to an external dead-man's switch. Never raises (#606).

    The URL goes to curl on stdin and its output is dropped, so it never reaches
    argv or a log.
    """

    if not url:
        return
    target = _healthchecks_fail_url(url) if failed else url
    try:
        delivered = subprocess.run(
            [
                str(config.curl_path),
                "--disable",
                "--fail",
                "--silent",
                "--max-time",
                str(HEALTHCHECKS_TIMEOUT_SECONDS),
                "--config",
                "-",
            ],
            input=f'url = "{target}"\n'.encode("utf-8"),
            capture_output=True,
            timeout=2 * HEALTHCHECKS_TIMEOUT_SECONDS,
            env={"PATH": config.tool_path, "LC_ALL": "C"},
            check=False,
        ).returncode == 0
    except Exception:  # Deliberately broad; see the docstring: nothing may escape.
        delivered = False
    if not delivered:
        print("production auto-deploy: healthchecks ping failed", file=sys.stderr)


def _blind_path(config: Config) -> Path:
    return config.state_root / "blind-polls"


def read_blind_polls(config: Config) -> int:
    """Consecutive polls that could not establish a candidate revision."""

    try:
        raw = _blind_path(config).read_text(encoding="ascii").strip()
    except (OSError, UnicodeError):
        return 0
    try:
        count = int(raw)
    except ValueError:
        # Unreadable state must not stop the poller; treat it as a fresh start.
        return 0
    return count if count >= 0 else 0


def _write_blind_polls(config: Config, count: int) -> None:
    _write_private(_blind_path(config), f"{count}\n".encode("ascii"))


def _blind_alarm_path(config: Config) -> Path:
    return config.state_root / "blind-alarm"


def read_blind_alarm(config: Config) -> bool:
    """Whether this stretch of blindness has actually been announced; delivery decides."""

    try:
        raw = _blind_alarm_path(config).read_text(encoding="ascii").strip()
    except (OSError, UnicodeError):
        return False
    return raw == "announced"


def note_blind_poll(config: Config, reason: str) -> None:
    """Count one blind poll and announce the transition into blindness, retrying until delivered."""

    count = read_blind_polls(config) + 1
    _write_blind_polls(config, count)
    if count < BLIND_POLL_THRESHOLD or read_blind_alarm(config):
        return
    published = publish(
        config,
        "alerts",
        {
            "title": f"\U0001f648 Deploy poller blind · {count} polls",
            "message": compose_message(
                f'<b>Deploy poller</b> is <font color="{COLOR_RED}">blind</font>',
                (
                    f'❓ <b>Reason</b> <font color="{COLOR_RED}">{html_escape(reason)}</font>',
                    f"\U0001f9ee <b>Polls</b> {count} in a row could not read main",
                ),
                "<i>No revision can deploy until the poller reaches main.</i>",
            ),
            "priority": 1,
        },
    )
    if not published:
        # Must not raise: a stopped deployment is worse than a missed notice.
        print("production auto-deploy: blindness notification failed", file=sys.stderr)
        return
    _write_private(_blind_alarm_path(config), b"announced\n")


def note_seeing_poll(config: Config) -> None:
    """Clear the blind count, announcing recovery only if blindness was reported."""

    count = read_blind_polls(config)
    if count == 0:
        return
    if count >= BLIND_POLL_THRESHOLD:
        # Gated on the count, so an all-clear follows an alarm an older poller sent.
        published = publish(
            config,
            "alerts",
            {
                "title": "\U0001f7e2 Deploy poller recovered",
                "message": compose_message(
                    f'<b>Deploy poller</b> can <font color="{COLOR_GREEN}">reach main</font> again',
                    (f"\U0001f9ee <b>Polls</b> {count} in a row could not read main before this one",),
                ),
                "priority": -1,
            },
        )
        if not published:
            print(
                "production auto-deploy: recovery notification failed", file=sys.stderr
            )
            return
    if read_blind_alarm(config):
        _write_private(_blind_alarm_path(config), b"\n")
    _write_blind_polls(config, 0)


def _ci_refusal_path(config: Config) -> Path:
    return config.state_root / "ci-refusal"


def read_ci_refusal(config: Config) -> str:
    """The revision-and-verdict already announced as blocking deployment."""

    try:
        return _ci_refusal_path(config).read_text(encoding="ascii").strip()
    except (OSError, UnicodeError):
        return ""


def note_ci_refusal(
    config: Config, sha: str, verdict: str, detail: str, url: str
) -> None:
    """Announce once per revision and verdict that CI refuses it, and forget it when that clears."""

    announced = read_ci_refusal(config)
    if verdict in (CI_GREEN, CI_PENDING, CI_SUPERSEDED):
        # Clearing on a non-judgement lets a second failed re-run be reported again.
        if announced:
            _write_private(_ci_refusal_path(config), b"\n")
        return
    marker = f"{sha} {verdict} {detail}"
    if announced == marker:
        return
    verdict_line = f'\U0001f9ea <b>CI</b> <font color="{COLOR_RED}">{html_escape(detail)}</font>'
    if _usable_url(url):
        # _usable_url held it to 512 characters, so this escape never cuts it.
        verdict_line += f' · <a href="{html_escape(url, MAX_URL_CHARACTERS, 6 * MAX_URL_CHARACTERS)}">open the run</a>'
    fields = {
        "title": f"⛔ CI blocks deploy · {sha[:7]}",
        "message": compose_message(
            f'<b>CI</b> <font color="{COLOR_RED}">blocks</font> this revision',
            (f"\U0001f516 <b>Revision</b> {commit_link(config, sha)}", verdict_line),
            "<i>Nothing deploys until this revision passes CI.</i>",
        ),
        "priority": 1,
    }
    if url:
        fields |= {"url": url, "url_title": "Open CI run"}
    published = publish(config, "alerts", fields)
    if not published:
        # Recorded only once delivered, so an unreachable publisher retries next poll.
        print("production auto-deploy: CI refusal notification failed", file=sys.stderr)
        return
    _write_private(_ci_refusal_path(config), marker.encode("ascii", "replace") + b"\n")


@dataclass(frozen=True)
class Selection:
    """What one poll decided, and enough of why to be able to say so.

    `verdict` None means CI was never consulted, which must leave an announced refusal alone.
    `attempted` separates "nothing to do" from "nothing may deploy".
    """

    candidate: str | None = None
    judged: str | None = None
    verdict: tuple[str, str, str] | None = None
    attempted: str | None = None


def select_revision(
    config: Config, head: str, runs, retry_sha: str | None = None
) -> Selection:
    """Choose the newest revision CI has released, walking main backwards.

    Unjudged revisions are stepped over; a judgement or an attempted revision ends
    the walk, as does one git says is not strictly newer than the last success (#916).
    """

    attempted = attempted_shas(config)
    successful = read_state(config)["last_successful"]
    unjudged: Selection | None = None
    for sha in candidate_revisions(config, head, runs):
        if sha in attempted and sha != retry_sha:
            return Selection(attempted=sha)
        if successful is not None and not _newer_than_deployed(
            config, sha, head, successful["sha"]
        ):
            break
        verdict = ci_verdict(config, sha, runs)
        if verdict[0] == CI_GREEN:
            return Selection(candidate=sha, judged=sha, verdict=verdict)
        if verdict[0] not in (CI_PENDING, CI_SUPERSEDED):
            return Selection(judged=sha, verdict=verdict)
        if unjudged is None:
            unjudged = Selection(judged=sha, verdict=verdict)
    return unjudged if unjudged is not None else Selection()


def _is_ancestor(config: Config, ancestor: str, descendant: str) -> bool:
    """Whether git knows `ancestor` precedes `descendant`; any non-zero exit is no."""

    try:
        result = _run(
            [config.git_path, "merge-base", "--is-ancestor", ancestor, descendant],
            timeout=GIT_LOCAL_TIMEOUT_SECONDS,
            cwd=config.checkout,
            env={"PATH": config.tool_path, "LC_ALL": "C", "GIT_TERMINAL_PROMPT": "0"},
        )
    except (OSError, subprocess.SubprocessError) as error:
        raise EligibilityError("git ancestry check failed") from error
    return result.returncode == 0


def _newer_than_deployed(config: Config, sha: str, head: str, deployed: str) -> bool:
    """Strictly newer than the deployed revision, and on the head (#916)."""

    return (
        sha != deployed
        and _is_ancestor(config, deployed, sha)
        and (sha == head or _is_ancestor(config, sha, head))
    )


def _fetch_unseen_head(config: Config, head: str) -> None:
    """Fetch the branch when the checkout does not have the head yet, so selection can compare it."""

    environment = {"PATH": config.tool_path, "LC_ALL": "C", "GIT_TERMINAL_PROMPT": "0"}
    try:
        known = _run(
            [config.git_path, "cat-file", "-e", f"{head}^{{commit}}"],
            timeout=GIT_LOCAL_TIMEOUT_SECONDS,
            cwd=config.checkout,
            env=environment,
        )
        if known.returncode == 0:
            return
        _run_network_command(
            [config.git_path, "fetch", "--prune", "origin", config.branch],
            failure="git fetch failed",
            budget=GIT_FETCH_TIMEOUT_SECONDS,
            cwd=config.checkout,
            env=environment,
        )
    except (OSError, subprocess.SubprocessError, TransientDeploymentError) as error:
        raise EligibilityError("git fetch failed") from error


def _eligible_revision(
    config: Config, head: str, retry_sha: str | None
) -> Selection:
    """Decide what this poll may deploy, and how CI judged what it examined.

    A retry overrides the attempted record, never the ordering.
    """

    selection = select_revision(config, head, fetch_ci_runs(config), retry_sha)
    if retry_sha is None:
        return selection
    successful = read_state(config)["last_successful"]
    if (
        selection.candidate != retry_sha
        or retry_sha not in attempted_shas(config)
        or (successful is not None and successful["sha"] == retry_sha)
    ):
        return replace(selection, candidate=None)
    return selection


def _poll_selection(config: Config, retry_sha: str | None) -> Selection:
    """Decide what this poll may deploy, recording whether it could see."""

    # Eligibility reaches the network; failing it is tracked, not just printed.
    try:
        head = resolve_main_sha(config)
        if read_state(config)["last_successful"] is not None:
            _fetch_unseen_head(config, head)
        selection = _eligible_revision(config, head, retry_sha)
    except EligibilityError as error:
        note_blind_poll(config, str(error))
        raise
    note_seeing_poll(config)
    if selection.verdict is not None:
        note_ci_refusal(config, selection.judged, *selection.verdict)
    return selection


def _deploy_once(config: Config, candidate: str, log) -> tuple[bool, str]:
    """Deploy one candidate: whether it succeeded, and how a failure is named."""

    failure = "failed"
    try:
        succeeded = deploy(config, candidate, log)
    except TransientDeploymentError as error:
        # Nothing reached the target, so undo the attempted record and retry (#351).
        succeeded = False
        note = f"production auto-deploy: transient failure: {error}"
        log.write(note.encode("ascii", "replace") + b"\n")
        if may_retry_after_transient_failure(config, candidate):
            forget_attempt(config, candidate)
            failure = "retrying"
        else:
            failure = "quarantined"
    return succeeded, failure


def _attempt(config: Config, selection: Selection) -> bool:
    """Attempt the selected candidate once, under the held lock, and report it."""

    candidate = selection.candidate
    # Recorded before the attempt, so a crash mid-deploy is not a retry loop.
    record_attempt(config, candidate)
    started = _timestamp()
    with run_log(config, candidate) as log:
        log_path = Path(log.name)
        succeeded, failure = _deploy_once(config, candidate, log)
        finished = _timestamp()
        if succeeded:
            record_success(config, candidate, finished)
            # The one message a release gets, sent after the record.
            announce_release(config, candidate, started, finished)
        # Best effort but never silent; the link is the run that released the revision.
        if not succeeded and not notify(
            config,
            candidate,
            started,
            finished,
            log_path,
            selection.verdict[2] if selection.verdict else "",
            failure=failure,
        ):
            warning = "production auto-deploy: outcome notification failed"
            log.write(warning.encode("ascii") + b"\n")
            print(warning, file=sys.stderr)
        return succeeded


def poll(config: Config, retry_sha: str | None = None) -> bool | None:
    """Attempt at most one eligible revision. None means nothing was attempted."""

    if retry_sha is not None and SHA_PATTERN.fullmatch(retry_sha) is None:
        raise EligibilityError("retry SHA is invalid")
    with deployment_lock(config) as acquired:
        if not acquired:
            return None
        now = datetime.now(timezone.utc)
        rotate_logs(config, now)
        prune_attempts(config, now)
        selection = _poll_selection(config, retry_sha)
        if selection.candidate is None:
            return None
        if retry_sha is not None:
            forget_attempt(config, retry_sha)
            # An explicit retry also resets the forgiveness budget.
            clear_transient_failures(config)
        return _attempt(config, selection)


def _holder_description(holder: dict | None) -> str:
    """Name the current holder as precisely as the record allows."""

    if not holder:
        return "another deployment"
    pid = holder.get("pid")
    what = holder.get("holder") or "deployment"
    started = holder.get("started")
    started_note = f", started {started}" if started else ""
    pid_note = f" (pid {pid}{started_note})" if pid else ""
    return f"{what}{pid_note}"


def _checkout_head_line(config: Config) -> str | None:
    """`<short sha> <subject>` of the checkout's HEAD, or None if git cannot say."""

    try:
        result = _run(
            [config.git_path, "log", "-1", "--format=%h %s"],
            timeout=GIT_LOCAL_TIMEOUT_SECONDS,
            cwd=config.checkout,
            env={"PATH": config.tool_path, "LC_ALL": "C", "GIT_TERMINAL_PROMPT": "0"},
        )
    except (OSError, subprocess.SubprocessError):
        return None
    line = result.stdout.decode("utf-8", "replace").strip()
    return line if result.returncode == 0 and line else None


def converge(config: Config, arguments: list[str]) -> int:
    """Run one operator ansible-playbook invocation under the deployment lock (#326).

    Uses the poller's virtualenv and checkout (#902), whose HEAD is printed first.
    Inherits the terminal and has no timeout: it is an attended operation.
    """

    with deployment_lock(config, holder="operator converge") as acquired:
        if not acquired:
            print(
                "production auto-deploy: refusing to converge, "
                f"{_holder_description(read_lock_holder(config))} already holds "
                f"{lock_path(config)}. Wait for it to finish, then re-run; "
                "--status reports what the poller last did.",
                file=sys.stderr,
            )
            return 1
        environment = dict(os.environ)
        environment[LOCK_OWNER_ENVIRONMENT] = str(os.getpid())
        # The collections the poller's plays load (#902); HOME stays the operator's.
        environment.setdefault("ANSIBLE_COLLECTIONS_PATH", str(_collections_path(config)))
        # announce_release never runs after an operator's command.
        environment.pop(SUMMARY_PATH_ENVIRONMENT, None)
        print(
            f"production auto-deploy: converging {config.checkout} at "
            f"{_checkout_head_line(config) or 'an unreadable HEAD'}",
            file=sys.stderr,
        )
        try:
            completed = subprocess.run(
                [str(_tooling_bin(config) / "ansible-playbook"), *arguments],
                cwd=config.checkout,
                env=environment,
                check=False,
            )
        except OSError as error:
            print(
                f"production auto-deploy: could not run ansible-playbook: {error}",
                file=sys.stderr,
            )
            return 1
        return completed.returncode


def _verify_verdict_path(config: Config, tag: str | None = None) -> Path:
    """verify-verdict for the services; verify-verdict-<name> per hourly-only tag."""

    suffix = "" if tag is None else "-" + tag.removeprefix("platform_verify_")
    return config.state_root / f"verify-verdict{suffix}"


def _hourly_only_tags(config: Config) -> list[str]:
    return [tag for tag in config.hourly_only_verify_tags.split(",") if tag]


def read_verify_verdict(config: Config, tag: str | None = None) -> str | None:
    """The last verdict --verify recorded: "pass", "fail", or None for no record."""

    try:
        parts = _verify_verdict_path(config, tag).read_text(encoding="ascii").split()
    except (OSError, UnicodeError):
        return None
    return parts[0] if parts and parts[0] in ("pass", "fail", "unchecked") else None


def _checkout_revision(config: Config) -> str | None:
    try:
        result = _run(
            [config.git_path, "rev-parse", "--verify", "HEAD"],
            timeout=GIT_LOCAL_TIMEOUT_SECONDS,
            cwd=config.checkout,
            env={"PATH": config.tool_path, "LC_ALL": "C", "GIT_TERMINAL_PROMPT": "0"},
        )
    except (OSError, subprocess.SubprocessError):
        return None
    sha = result.stdout.decode("ascii", "replace").strip()
    return sha if result.returncode == 0 and SHA_PATTERN.fullmatch(sha) else None


def note_verify_verdict(
    config: Config,
    passed: bool,
    sha: str,
    log_path: Path,
    tag: str | None = None,
    failure: str = "fail",
) -> None:
    """Page on a change of verdict only, and record it once the page landed.

    tag None is the services' verdict; each hourly-only tag keeps its own (#609).
    failure is "fail", or "unchecked" for a check that could not run.
    """

    verdict = "pass" if passed else failure
    previous = read_verify_verdict(config, tag)
    if verdict == previous:
        return
    if verdict != "pass" or previous is not None:
        failed = verdict != "pass"
        run_url = ""
        if failed and tag is None:
            # Best effort: a failure costs only the link.
            with contextlib.suppress(EligibilityError):
                run_url = ci_verdict(config, sha, fetch_ci_runs(config))[2] or ""
        if tag is None:
            details = []
            if failed:
                title = f"\U0001f534 Verify failed · {sha[:7]}"
                lead = f'<b>Verify</b> <font color="{COLOR_RED}">failed</font> on the deployed revision'
                closing = "<i>Verify runs hourly; a recovery follows here once it passes.</i>"
            else:
                title = f"\U0001f7e2 Verify recovered · {sha[:7]}"
                lead = f'<b>Verify</b> <font color="{COLOR_GREEN}">passes</font> again'
                closing = ""
        else:
            key = verdict if failed else "recovered" if previous == "fail" else "restored"
            title, lead, closing = HOURLY_ONLY_VERIFY_CHECKS.get(tag, {}).get(
                key, (f"{tag}: {key}", f"<b>{html_escape(tag)}</b> {html_escape(key)}", "")
            )
            details = [f"\U0001f50d <b>Check</b> {html_escape(tag)}"]
        details.append(f"\U0001f516 <b>Revision</b> {commit_link(config, sha)}")
        if run_link(run_url):
            details.append(run_link(run_url))
        details.append(log_line(log_path))
        fields = {
            "title": title,
            "message": compose_message(lead, details, closing),
            # A failure needs a human; a recovery closes it on the same app, quietly.
            "priority": 1 if failed else -1,
        }
        if run_url:
            fields |= {"url": run_url, "url_title": "Open CI run"}
        published = publish(config, "alerts", fields)
        if not published:
            print("production auto-deploy: verify notification failed", file=sys.stderr)
            return
    # Caught rather than raised: verify.yml did run.
    try:
        _write_private(
            _verify_verdict_path(config, tag),
            f"{verdict} {sha} {_timestamp()}\n".encode("ascii"),
        )
    except OSError as error:
        print(f"production auto-deploy: verify verdict not recorded: {error}",
              file=sys.stderr)


def _run_verify_play(config: Config, tags: str, log_path: Path, timeout: float) -> int | None:
    """One verify.yml invocation, logged to its own file: its exit code, None on timeout."""

    descriptor = os.open(log_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(descriptor, "wb") as log:
        os.fchmod(log.fileno(), 0o600)
        try:
            return _run(
                _verify_invocation(config, tags),
                timeout=timeout,
                cwd=config.checkout,
                env=_ansible_environment(config),
                log=log,
            ).returncode
        except subprocess.TimeoutExpired:
            return None


def verify(config: Config) -> bool | None:
    """Verify the deployed revision: the services, then each hourly-only tag. None: skipped.

    Only while the checkout holds the last successful revision. Waits up to
    VERIFY_LOCK_WAIT_SECONDS for the deployment lock (#326).
    """

    # Said before the wait so fifteen silent minutes do not read as a hang; racy and harmless.
    if VERIFY_LOCK_WAIT_SECONDS and deployment_lock_held(config):
        print(
            "production auto-deploy: verify waiting up to "
            f"{int(VERIFY_LOCK_WAIT_SECONDS // 60)} minutes for "
            f"{_holder_description(read_lock_holder(config))} to release "
            f"{lock_path(config)}"
        )
    with deployment_lock(config, holder="verify",
                         wait_seconds=VERIFY_LOCK_WAIT_SECONDS) as acquired:
        if not acquired:
            print(
                "production auto-deploy: verify skipped, "
                f"{_holder_description(read_lock_holder(config))} still holds "
                f"{lock_path(config)} after "
                f"{int(VERIFY_LOCK_WAIT_SECONDS // 60)} minutes"
            )
            return None
        deployed = read_state(config)["last_successful"]
        if deployed is None:
            print("production auto-deploy: verify skipped, nothing has deployed yet")
            return None
        head = _checkout_revision(config)
        if head != deployed["sha"]:
            print(
                "production auto-deploy: verify skipped, the checkout holds "
                f"{head or 'an unreadable revision'}, not the deployed {deployed['sha']}"
            )
            return None
        log_path = config.log_root / "verify.log"
        passed = _run_verify_play(config, config.verify_tags, log_path, VERIFY_TIMEOUT_SECONDS) == 0
        note_verify_verdict(config, passed, head, log_path)
        # One invocation and record per tag, so one failure cannot hide another (#609).
        results = [passed]
        for tag in _hourly_only_tags(config):
            tag_log = config.log_root / f"verify-{tag.removeprefix('platform_verify_')}.log"
            code = _run_verify_play(config, tag, tag_log, HOURLY_ONLY_VERIFY_TIMEOUT_SECONDS)
            tag_passed = code == 0
            failure = "fail"
            marker = HOURLY_ONLY_VERIFY_CHECKS.get(tag, {}).get("marker")
            if marker is not None and not tag_passed:
                failure = "unchecked"
                if code is not None:
                    with contextlib.suppress(OSError):
                        if marker.encode("ascii") in tag_log.read_bytes():
                            failure = "fail"
            note_verify_verdict(config, tag_passed, head, tag_log, tag, failure)
            results.append(tag_passed)
        return all(results)


def _next_poll_verdict(config: Config) -> tuple[str, str]:
    """Explain what the next poll would do, without doing any of it."""

    try:
        head = resolve_main_sha(config)
    except EligibilityError as error:
        return "unknown", f"could not resolve {config.branch}: {error}"
    short = head[:9]
    try:
        selection = select_revision(config, head, fetch_ci_runs(config))
    except EligibilityError as error:
        return head, f"could not query CI for {short}: {error}"
    if selection.candidate is not None:
        if selection.candidate == head:
            return head, f"would deploy {short}"
        return head, (
            f"would deploy {selection.candidate[:9]}, the newest revision CI "
            f"has released; {short} has not finished its run"
        )
    if selection.attempted is not None:
        stopped = selection.attempted
        # Attempted-but-not-successful also looks like a deployment in progress; the
        # flock is the liveness truth.
        held = deployment_lock_held(config)
        successful = read_state(config)["last_successful"]
        if successful is not None and successful["sha"] == stopped:
            return head, f"nothing to do: {stopped[:9]} is deployed"
        if held:
            return head, (
                f"in progress: {stopped[:9]} "
                f"(holder {_holder_description(read_lock_holder(config))})"
            )
        return head, (
            f"nothing to do: {stopped[:9]} was already attempted and failed. "
            f"Retry it explicitly with --retry-failed {stopped}"
        )
    verdict, detail, url = selection.verdict or (CI_PENDING, "no completed run yet", "")
    judged = (selection.judged or head)[:9]
    if verdict == CI_PENDING:
        return head, (
            f"waiting: no completed successful {config.workflow_name} push run "
            f"for {judged} yet"
        )
    if verdict == CI_SUPERSEDED:
        return head, (
            f"waiting: the {config.workflow_name} push run for {judged} "
            f"concluded {detail} without judging it, and nothing behind it is "
            "deployable"
        )
    if verdict == CI_FAILED:
        location = f" ({url})" if url else ""
        return head, (
            f"blocked: the {config.workflow_name} push run for {judged} "
            f"concluded {detail}{location}. Fix main; nothing deploys until it "
            "passes"
        )
    return head, (
        f"blocked: for {judged}, {detail}. "
        "Re-run only failed jobs rather than all of them"
    )


def print_status(config: Config) -> None:
    """Print the recorded state and what the next poll would do."""

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
    head, verdict = _next_poll_verdict(config)
    print(f"current {config.branch}: {head}")
    print(f"next poll: {verdict}")


def _playbook_arguments(remaining: list[str]) -> list[str]:
    """What --converge hands ansible-playbook, less one leading separator."""

    playbook_arguments = list(remaining)
    if playbook_arguments and playbook_arguments[0] == "--":
        playbook_arguments = playbook_arguments[1:]
    return playbook_arguments


def _complete_arguments(config_path, mode, retry_sha, playbook_arguments):
    """The parsed invocation, or None when it names too little to run."""

    if config_path is None or mode is None:
        return None
    if mode == "retry" and (
        retry_sha is None or SHA_PATTERN.fullmatch(retry_sha) is None
    ):
        return None
    if mode == "converge" and not playbook_arguments:
        return None
    return config_path, mode, retry_sha, playbook_arguments


def _parse_arguments(argv):
    config_path = None
    mode = None
    retry_sha = None
    playbook_arguments: list[str] = []
    remaining = list(argv)
    while remaining:
        argument = remaining.pop(0)
        if argument == "--config" and remaining and config_path is None:
            config_path = remaining.pop(0)
        elif argument == "--poll" and mode is None:
            mode = "poll"
        elif argument == "--status" and mode is None:
            mode = "status"
        elif argument == "--verify" and mode is None:
            mode = "verify"
        elif argument == "--retry-failed" and remaining and mode is None:
            mode = "retry"
            retry_sha = remaining.pop(0)
        elif argument == "--converge" and mode is None:
            # Everything after --converge belongs to ansible-playbook.
            mode = "converge"
            playbook_arguments = _playbook_arguments(remaining)
            remaining = []
        else:
            return None
    return _complete_arguments(config_path, mode, retry_sha, playbook_arguments)


def _verify_mode(config: Config) -> int:
    """Run --verify and ping its check with the verdict."""

    # The verify check's ping (#610): True pings plain, False (or any raise) /fail,
    # None (skipped) pings nothing so repeated skips alert.
    passed = False
    try:
        passed = verify(config)
    except OSError as error:
        print(f"production auto-deploy: could not verify: {error}",
              file=sys.stderr)
        return 1
    finally:
        if passed is not None:
            ping_healthchecks(config, config.healthchecks_verify_ping_url,
                              passed is False)
    if passed is False:
        print("production auto-deploy: verification failed", file=sys.stderr)
        return 1
    return 0


def _poll_mode(config: Config, mode: str, retry_sha: str | None) -> int:
    """Run --poll or --retry-failed, pinging the tick check for --poll only."""

    # The tick heartbeat (#606): None and True ping plain, False pings /fail, an
    # EligibilityError pings plain (blindness already pages on-box), --retry-failed nothing.
    outcome = False
    try:
        outcome = poll(config, retry_sha=retry_sha)
    except EligibilityError:
        outcome = None
        raise
    except OSError as error:
        # A private directory the installer owns is missing or unwritable (#658).
        print(f"production auto-deploy: {error.filename or 'a managed path'} is unusable",
              file=sys.stderr)
        return 1
    finally:
        if mode == "poll":
            ping_healthchecks(config, config.healthchecks_poller_ping_url,
                              outcome is False)
    if outcome is False:
        print("production auto-deploy: attempt failed", file=sys.stderr)
        return 1
    return 0


def main(argv=None) -> int:
    """Run one explicit production auto-deployment mode."""

    parsed = _parse_arguments(list(sys.argv[1:] if argv is None else argv))
    if parsed is None:
        print("production auto-deploy: invalid arguments", file=sys.stderr)
        return 2
    config_path, mode, retry_sha, playbook_arguments = parsed
    try:
        config = load_config(config_path)
        if mode == "status":
            print_status(config)
            return 0
        if mode == "converge":
            return converge(config, playbook_arguments)
        if mode == "verify":
            return _verify_mode(config)
        return _poll_mode(config, mode, retry_sha)
    except ConfigurationError:
        # No ping: the URL is in the untrusted file.
        print("production auto-deploy: unusable configuration", file=sys.stderr)
        return 1
    except EligibilityError:
        print("production auto-deploy: could not determine a candidate",
              file=sys.stderr)
        return 0


if __name__ == "__main__":
    raise SystemExit(main())
