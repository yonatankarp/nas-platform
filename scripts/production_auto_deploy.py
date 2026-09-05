#!/usr/bin/env python3
"""Deploy the newest main revision on the NAS that CI has released."""

from __future__ import annotations

import contextlib
from contextlib import contextmanager
from dataclasses import dataclass, fields, replace
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
# One page of recent completed runs. It bounds how far back a poll can see, so
# it has to hold more than one revision's worth: a revision owns several runs
# over its life, and every re-run adds another.
CI_RUN_PAGE_SIZE = 20
READ_SIZE = 64 * 1024
NETWORK_TIMEOUT_SECONDS = 10
GIT_TIMEOUT_SECONDS = 10
NOTIFICATION_TIMEOUT_SECONDS = 10
# Consecutive polls that fail before eligibility is even decided. At the
# five-minute cron cadence this is a quarter hour of being unable to see
# main, which no transient network blip should reach.
BLIND_POLL_THRESHOLD = 3
# Mirrors services/dozzle/alert_relay.py so both publishers escape alike.
MARKDOWN_PATTERN = re.compile(r"([\\`*_{}\[\]()#+\-.!|>])")
COMMAND_TIMEOUT_SECONDS = 60 * 60
TOOLING_TIMEOUT_SECONDS = 15 * 60
# Announces to the plays that the process holding the deployment lock is this
# run's own ancestor. roles/deployment_bundle probes the lock at the first task
# of every service role and refuses a converge somebody else is already running;
# without this, both the poller's own plays and an operator's --converge would
# refuse themselves, because the holder they find is their own parent. The value
# is the holder's pid, which the lock record below carries too. It is advisory,
# not a credential: anyone able to export it can already run ansible-playbook by
# hand, and the containment guard in the same task file remains the real
# security control.
LOCK_OWNER_ENVIRONMENT = "PLATFORM_DEPLOYMENT_LOCK_OWNER"


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
    vault_password_file: Path
    ntfy_curl_config: Path
    # Addressed in the publish body, not the URL: ntfy only parses a JSON
    # publish document when the POST goes to the server root.
    ntfy_topic_critical: str
    ntfy_topic_deployment: str
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
    # The fourth play reinstalls this poller, so the installer's own choices
    # have to be replayed or the role rejects its own invocation.
    external_scheduler: bool


_PATH_FIELDS = frozenset(
    {
        "checkout",
        "state_root",
        "log_root",
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
        if field.name == "external_scheduler":
            if type(raw) is not bool:
                raise ConfigurationError("external_scheduler must be a boolean")
            values[field.name] = raw
        elif field.name == "log_retention_days":
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


def fetch_ci_runs(config: Config) -> tuple[dict, ...]:
    """Fetch one bounded page of completed push runs for the production branch.

    The whole branch rather than one revision, because the question a poll has
    to answer is which revision CI has released, and asking about a single SHA
    cannot see that the head is still running while its parent already passed.
    It stays one request either way, which matters: the API is called
    anonymously, and the poll runs every five minutes.
    """

    query = urlencode(
        {
            "branch": config.branch,
            "event": "push",
            "status": "completed",
            "per_page": str(CI_RUN_PAGE_SIZE),
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


def gating_ci_runs(config: Config, sha: str, runs) -> list[dict]:
    """Completed push runs of the gating workflow for this SHA, any conclusion.

    GitHub returns workflow runs newest first, so the first entry is the most
    recent attempt at this revision.
    """

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
    """The revisions one poll may consider, newest first.

    The head leads: it is the revision the platform is meant to reach, and the
    one whose run is most likely still going — which is exactly why it may be
    absent from a list of completed runs. Behind it come the revisions CI has
    finished judging, in the order GitHub returns them, which is the order they
    were pushed.

    Every SHA past the head arrives from the network and ends up as an argument
    to git, so it is checked against the same pattern as the head before it is
    allowed to name a revision. The page of runs bounds the list; the walk that
    reads it stops long before the end.
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


# Why CI does or does not release a revision. Only GREEN deploys. PENDING and
# SUPERSEDED are ordinary states worth no notification, because neither is a
# judgement: one run has not finished, the other never will. The last two stop
# every deployment until a human intervenes.
CI_GREEN = "green"
CI_PENDING = "pending"
CI_SUPERSEDED = "superseded"
CI_FAILED = "failed"
CI_AMBIGUOUS = "ambiguous"

# Conclusions that end a run without judging the revision it was running. The
# workflow used to cancel its own superseded runs on every branch, so merging
# twice inside one CI window left the first revision `cancelled`, and roughly a
# quarter of pushes to main ended that way. `cancel-in-progress` is now confined
# to pull requests — a post-merge run is the only run that will ever see the tree
# it merged, so main pushes queue instead — but a run can still be cancelled by
# hand, and `skipped`, `stale` and `neutral` say as little as `cancelled` does.
# Reading any of them as a red main would page a human for a run that never
# judged the revision at all.
#
# Anything absent from this set counts as a refusal, including a conclusion
# this poller has never heard of: an unrecognised answer from CI is exactly the
# kind of thing that should stop a deployment rather than pass unnoticed.
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

    Whether a revision may deploy is only half the answer. A poll that refuses
    one has to be able to say why as well: a red main blocks every deployment,
    and a poll that decides nothing looks exactly like a poll with nothing to
    do. Exactly one successful run releases a revision — several is ambiguity,
    not success.

    A run that ended without judging the revision is not a refusal and is not
    the answer either, so a cancelled re-run cannot bury the failure that
    prompted it: the newest run that actually reached a verdict is the verdict.
    A revision with nothing but unjudged runs was superseded, not refused.
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


def prune_attempts(config: Config, now: datetime) -> None:
    """Trim the attempted record to its retention bounds.

    Recording an attempt prunes as a side effect, which ties the housekeeping
    to deployments: the count bound holds either way, but the age bound only
    takes effect the next time something ships, so a quiet fortnight leaves
    expired revisions sitting in the file and listed by --status. The poll does
    it every tick instead, beside the log rotation, so the record is bounded by
    time rather than by how often the platform happens to change.

    Written back only when the pruning actually removed something. A poll that
    rewrites unchanged state twelve times an hour is twelve needless writes to
    the NAS's flash.
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
    """The one file every deployment on this host serialises on.

    Named here rather than in each caller because roles/deployment_bundle has to
    find the same file from Ansible, and it derives it from the account's home
    exactly as roles/production_auto_deploy derives state_root. Two spellings of
    one path would be a lock nobody shares.
    """

    return config.state_root / "deployment.lock"


def _record_lock_holder(descriptor: int, holder: str) -> None:
    """Write who holds the lock, for a refused caller to name.

    The flock alone says only that somebody is deploying, and #326 is exactly
    the story of an operator who could not tell what was happening: the race
    surfaced as a containment refusal naming an unsafe deployment target, so the
    honest first reading was a corrupted deployment tree rather than a second
    converge. A holder that says "pid 4711, operator converge, started at ..."
    turns that into a fact.

    Best effort and advisory. The flock is the liveness truth -- a crashed
    holder leaves this record behind, and a reader that finds the lock free must
    ignore whatever it says. Written with pwrite after truncating so no reader
    can observe a half-replaced record at offset zero.
    """

    payload = json.dumps(
        {"pid": os.getpid(), "holder": holder, "started": _timestamp()},
        sort_keys=True,
    )
    with contextlib.suppress(OSError):
        os.ftruncate(descriptor, 0)
        os.pwrite(descriptor, payload.encode("ascii") + b"\n", 0)


def read_lock_holder(config: Config) -> dict | None:
    """The holder record, or None when there is nothing readable to report.

    Advisory in both directions: absent when the holder could not write it, and
    stale when the holder died. Only ever used to make a message specific.
    """

    try:
        payload = json.loads(lock_path(config).read_text(encoding="ascii"))
    except (OSError, UnicodeError, ValueError):
        return None
    return payload if isinstance(payload, dict) else None


@contextmanager
def deployment_lock(config: Config, holder: str = "poll") -> Iterator[bool]:
    """Serialise deployments; yield False when another holder already runs one."""

    descriptor = os.open(lock_path(config), os.O_WRONLY | os.O_CREAT, 0o600)
    try:
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            yield False
            return
        _record_lock_holder(descriptor, holder)
        try:
            yield True
        finally:
            # Cleared while the lock is still held, so a reader that finds the
            # lock taken reads that holder's record or nothing -- never the last
            # deployment's pid. The weekly image prune takes this same lock and
            # records itself the same way, so an empty file under a held lock
            # now means only a poller too old to write one. Only a crash can
            # leave a record behind, and a reader must still ignore one it finds
            # under a free lock.
            with contextlib.suppress(OSError):
                os.ftruncate(descriptor, 0)
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
        "ANSIBLE_CONFIG": str(config.checkout / "ansible.cfg"),
        "ANSIBLE_COLLECTIONS_PATH": str(_collections_path(config)),
        # deploy() runs inside poll()'s deployment_lock, in this process, so the
        # holder these plays will find is this pid. Saying so is what keeps the
        # poller's own converge from being refused by the concurrency guard it
        # installs.
        LOCK_OWNER_ENVIRONMENT: str(os.getpid()),
    }


def _vault_arguments(config: Config) -> list[str]:
    """Only the password provider. Credentials belong to the revision.

    The encrypted vault is committed, so `git checkout` puts the candidate's
    own copy in the checkout and group_vars loads it. Passing a second copy
    from outside as extra vars would outrank that, letting a stale artifact
    silently shadow the revision being deployed while every play still
    reports success. The password provider cannot be committed, so it is the
    one input that stays outside.
    """

    return [
        "-i",
        "inventory/local.yml",
        "--vault-password-file",
        str(config.vault_password_file),
    ]


def update_checkout(config: Config, sha: str) -> None:
    """Materialise the candidate revision in the controller checkout.

    A candidate behind the head is named by GitHub's record of what it ran,
    which is a record of the past: a revision can have been rewritten off the
    branch since. Only the branch just fetched says what main is now, so the
    revision has to be an ancestor of it before anything is checked out --
    against FETCH_HEAD, which this fetch wrote, rather than a remote-tracking
    ref some other command may have left behind.
    """

    environment = {
        "PATH": config.tool_path,
        "LC_ALL": "C",
        "GIT_TERMINAL_PROMPT": "0",
    }
    steps = (
        (
            [config.git_path, "fetch", "--prune", "origin", config.branch],
            f"git fetch failed for {sha}",
        ),
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
        result = _run(
            arguments,
            timeout=COMMAND_TIMEOUT_SECONDS,
            cwd=config.checkout,
            env=environment,
        )
        if result.returncode != 0:
            raise DeploymentError(failure)


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
        # The installer's own choices must be replayed: the role requires the
        # public host, and would otherwise try to install a cron entry on a host
        # where scheduling is external.
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


OUTCOMES = {
    # topic attribute, title prefix, priority, tags. Severity picks the topic:
    # a failed deployment belongs on the critical topic, a successful one does
    # not, which is the whole point of having two.
    "success": ("ntfy_topic_deployment", "Deployed", 3, ("white_check_mark",)),
    "failed": ("ntfy_topic_critical", "Deploy failed", 5, ("warning", "skull")),
}


def markdown_escape(value: str, maximum: int = 256) -> str:
    """Escape one value for ntfy's markdown rendering, bounded like the relay.

    Only the log path needs this. The SHA is validated hex and the timestamps
    come from strftime, so escaping those would only make them unreadable.
    """

    return MARKDOWN_PATTERN.sub(lambda match: f"\\{match.group(1)}", value[:maximum])


def format_duration(started: str, finished: str) -> str:
    """Render the elapsed deployment time, or admit that it is not derivable."""

    try:
        span = datetime.strptime(finished, "%Y-%m-%dT%H:%M:%SZ") - datetime.strptime(
            started, "%Y-%m-%dT%H:%M:%SZ"
        )
    except ValueError:
        return "unknown"
    seconds = int(span.total_seconds())
    if seconds < 0:
        return "unknown"
    minutes, seconds = divmod(seconds, 60)
    hours, minutes = divmod(minutes, 60)
    if hours:
        return f"{hours}h {minutes}m {seconds}s"
    if minutes:
        return f"{minutes}m {seconds}s"
    return f"{seconds}s"


def render_notification(
    config: Config,
    outcome: str,
    sha: str,
    started: str,
    finished: str,
    log_path: Path,
) -> dict:
    """Build ntfy's structured publish document for one deployment outcome."""

    try:
        topic_attribute, title_prefix, priority, tags = OUTCOMES[outcome]
    except KeyError:
        raise ValueError(f"unknown deployment outcome: {outcome}") from None
    message = "\n".join(
        (
            f"**Commit:** `{sha}`",
            f"**Started:** `{started}`",
            f"**Finished:** `{finished}`",
            f"**Duration:** `{format_duration(started, finished)}`",
            f"**Log:** `{markdown_escape(str(log_path))}`",
        )
    )
    return {
        "topic": getattr(config, topic_attribute),
        "title": f"{title_prefix} \u00b7 {sha[:9]}",
        "message": message,
        "priority": priority,
        "tags": list(tags),
        "markdown": True,
    }


def notify(
    config: Config,
    outcome: str,
    sha: str,
    started: str,
    finished: str,
    log_path: Path,
) -> bool:
    """Publish a secret-free outcome through the operator's protected curl config.

    The curl config addresses the ntfy server root, so the topic travels in the
    body. Posting this document to /<topic> instead would deliver it as literal
    JSON text rather than a rendered notification.
    """

    return publish(
        config, render_notification(config, outcome, sha, started, finished, log_path)
    )


def publish(config: Config, notification: dict) -> bool:
    """Send one prepared ntfy document through the protected curl config."""

    body = json.dumps(notification, ensure_ascii=False, separators=(",", ":"))
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
    """Whether this stretch of blindness has actually been announced.

    Delivery, not arithmetic, is what suppresses re-announcement. The count on
    its own cannot say: a count past the threshold is what both a delivered
    alarm and an undeliverable one leave behind, and reading the first meaning
    into the second is how the poller went blind in silence.
    """

    try:
        raw = _blind_alarm_path(config).read_text(encoding="ascii").strip()
    except (OSError, UnicodeError):
        return False
    return raw == "announced"


def note_blind_poll(config: Config, reason: str) -> None:
    """Count one blind poll and announce the transition into blindness once.

    The count is recorded on every poll and the announcement is retried on
    every poll until it lands, because the alarm this raises is the only thing
    that distinguishes a poller that cannot see main from an idle one. A
    publisher that is briefly unreachable must therefore cost a delayed alarm,
    never the only alarm this outage would ever get.
    """

    count = read_blind_polls(config) + 1
    _write_blind_polls(config, count)
    if count < BLIND_POLL_THRESHOLD or read_blind_alarm(config):
        return
    published = publish(
        config,
        {
            "topic": config.ntfy_topic_critical,
            "title": f"Deploy poller blind \u00b7 {count} polls",
            "message": "\n".join(
                (
                    f"**Reason:** `{markdown_escape(reason)}`",
                    f"**Consecutive failures:** `{count}`",
                    "**Effect:** `no revision can be deployed until this clears`",
                )
            ),
            "priority": 5,
            "tags": ["warning"],
            "markdown": True,
        },
    )
    if not published:
        # Reported to cron's mail and retried on the next poll. It must not
        # raise: a notification nobody received is bad, and a deployment
        # stopped because a notification could not be sent is worse.
        print("production auto-deploy: blindness notification failed", file=sys.stderr)
        return
    _write_private(_blind_alarm_path(config), b"announced\n")


def note_seeing_poll(config: Config) -> None:
    """Clear the blind count, announcing recovery only if blindness was reported."""

    count = read_blind_polls(config)
    if count == 0:
        # The overwhelming majority of polls land here. Rewriting a zero every
        # five minutes would fsync the state directory for no change.
        return
    if count >= BLIND_POLL_THRESHOLD:
        # Gated on the count rather than on the delivered alarm, so an
        # all-clear still follows an alarm this revision of the poller did not
        # itself send -- the count it inherits is all a freshly installed
        # poller knows about the outage it woke up inside.
        published = publish(
            config,
            {
                "topic": config.ntfy_topic_deployment,
                "title": "Deploy poller recovered",
                "message": "**Status:** `the poller can reach main again`",
                "priority": 3,
                "tags": ["white_check_mark"],
                "markdown": True,
            },
        )
        if not published:
            # The count stays where it is so the next seeing poll tries again,
            # for the same reason the alarm above retries.
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
    """Announce once that CI refuses a revision, and forget it when that clears.

    A revision CI refuses is the one failure the poller used to swallow whole:
    eligibility simply said no, the poll returned quietly, and every subsequent
    deployment stopped with nothing to show for it. Announced once per revision
    and verdict rather than every poll, because the cron cadence is five
    minutes and a red main stays red until somebody fixes it.
    """

    announced = read_ci_refusal(config)
    if verdict in (CI_GREEN, CI_PENDING, CI_SUPERSEDED):
        # Neither pending nor superseded is a judgement, and clearing on them
        # is what lets a re-run that fails a second time be reported again.
        if announced:
            _write_private(_ci_refusal_path(config), b"\n")
        return
    marker = f"{sha} {verdict} {detail}"
    if announced == marker:
        return
    lines = [
        f"**Commit:** `{sha}`",
        f"**CI:** `{markdown_escape(detail)}`",
        "**Effect:** `no deployment until this revision passes CI`",
    ]
    if url:
        lines.append(f"**Run:** `{markdown_escape(url)}`")
    published = publish(
        config,
        {
            "topic": config.ntfy_topic_critical,
            "title": f"CI blocks deploy · {sha[:9]}",
            "message": "\n".join(lines),
            "priority": 4,
            "tags": ["warning"],
            "markdown": True,
        },
    )
    if not published:
        # Recorded only once it has actually been delivered, so a publisher
        # that was briefly unreachable reports on the next poll instead of
        # losing the only notice this revision ever gets.
        print("production auto-deploy: CI refusal notification failed", file=sys.stderr)
        return
    _write_private(_ci_refusal_path(config), marker.encode("ascii", "replace") + b"\n")


@dataclass(frozen=True)
class Selection:
    """What one poll decided, and enough of why to be able to say so.

    `candidate` is the revision to deploy, when there is one. `judged` and
    `verdict` carry the CI answer worth announcing — for the revision that
    stopped the walk, or for the head while its own run is still going. A
    `verdict` of None means CI was never consulted, which is not the same as
    CI having nothing to say: the caller must leave the announced refusal alone
    rather than treat an unasked question as an answer. `attempted` names the
    revision the poller has already had its turn at, which is what makes
    "nothing to do" different from "nothing may deploy".
    """

    candidate: str | None = None
    judged: str | None = None
    verdict: tuple[str, str, str] | None = None
    attempted: str | None = None


def select_revision(
    config: Config, head: str, runs, retry_sha: str | None = None
) -> Selection:
    """Choose the newest revision CI has released, walking main backwards.

    CI takes longer than the merge cadence, so main's head is usually still
    running while the revision behind it is already green. Waiting for the head
    means waiting out a run that has nothing to do with the change that already
    passed — half an hour of a deployable revision sitting undeployed, for
    every merge that lands while a run is going.

    So a revision CI has not judged is stepped over rather than waited for. It
    may be the head, whose run has not finished and which deploys in its own
    right once it does; it may equally be a revision the workflow cancelled
    when the next merge superseded it, which will never be judged at all. Two
    merges inside one CI window leave a run of those, which is why the walk
    cannot stop at the first revision behind the head.

    A judgement ends the walk. A revision CI refused blocks every deployment
    behind it, exactly as a red head always has. A revision already attempted
    means this poller has had its turn at it — and at everything older, which
    is what keeps the walk from ever going backwards.
    """

    attempted = attempted_shas(config)
    unjudged: Selection | None = None
    for sha in candidate_revisions(config, head, runs):
        if sha in attempted and sha != retry_sha:
            return Selection(attempted=sha)
        verdict = ci_verdict(config, sha, runs)
        if verdict[0] == CI_GREEN:
            return Selection(candidate=sha, judged=sha, verdict=verdict)
        if verdict[0] not in (CI_PENDING, CI_SUPERSEDED):
            return Selection(judged=sha, verdict=verdict)
        if unjudged is None:
            # Normally the head, its own run still going. Announced to nobody,
            # but it is what clears a refusal once the revision is re-run.
            unjudged = Selection(judged=sha, verdict=verdict)
    return unjudged if unjudged is not None else Selection()


def _eligible_revision(
    config: Config, head: str, retry_sha: str | None
) -> Selection:
    """Decide what this poll may deploy, and how CI judged what it examined.

    An explicit retry overrides the attempted record for one revision, not the
    ordering: the revision still has to be the one the walk would have chosen
    anyway, so a retry can never put an older revision back on the NAS than one
    a later poll has already deployed.
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
        # Eligibility is the part that reaches the network. Failing it leaves
        # the poller unable to deploy anything at all, and a poll that decides
        # nothing looks exactly like a poll with nothing to do, so the outcome
        # is tracked rather than only printed to a cron mailbox nobody reads.
        try:
            head = resolve_main_sha(config)
            selection = _eligible_revision(config, head, retry_sha)
        except EligibilityError as error:
            note_blind_poll(config, str(error))
            raise
        note_seeing_poll(config)
        if selection.verdict is not None:
            note_ci_refusal(config, selection.judged, *selection.verdict)
        candidate = selection.candidate
        if candidate is None:
            return None
        if retry_sha is not None:
            forget_attempt(config, retry_sha)

        # Recorded before the attempt: a crash mid-deploy must not become a
        # retry loop on the next five-minute tick.
        record_attempt(config, candidate)
        started = _timestamp()
        with attempt_log(config, candidate) as log:
            log_path = Path(log.name)
            succeeded = deploy(config, candidate, log)
            finished = _timestamp()
            if succeeded:
                record_success(config, candidate, finished)
            # A successful deployment reports itself, from inside the run,
            # where the manifests and the Git history that say what shipped are
            # still at hand. Announcing it a second time here would add a
            # revision and a duration to a message that already said more.
            #
            # Best effort, but never silent: a misconfigured publisher would
            # otherwise lose every failure with nothing to show for it.
            if not succeeded and not notify(
                config,
                "failed",
                candidate,
                started,
                finished,
                log_path,
            ):
                warning = "production auto-deploy: outcome notification failed"
                log.write(warning.encode("ascii") + b"\n")
                print(warning, file=sys.stderr)
        return succeeded


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


def converge(config: Config, arguments: list[str]) -> int:
    """Run one operator ansible-playbook invocation under the deployment lock.

    Issue #326: the poller serialises itself, but the documented manual path was
    a bare ansible-playbook that took no lock at all, so on a host polling every
    five minutes any hand-run converge lasting longer than five minutes would
    overlap the poller's. That is not hypothetical -- it happened, and it
    surfaced 1463 tasks in as an unsafe-deployment-target refusal, because the
    poller had repointed `current` underneath a run that was still converging
    services against the release it had activated itself.

    What this mode adds is the lock and nothing else. The arguments, the
    inventory, the vault password provider, the tags and the working directory
    stay the operator's, because the poller's checkout is at whatever revision
    update_checkout last reset it to: imposing it here would silently converge a
    different tree than the operator is reading. So this is deliberately not a
    second deploy path -- it is `flock` around the operator's own command, using
    the poller's own lock rather than a second scheme, and writing the holder
    record that plain flock(1) cannot.

    The child is run with the inherited terminal: --ask-vault-pass has to be able
    to prompt, and the operator has to see the recap as it happens, so the output
    is deliberately neither captured nor logged. There is no timeout for the same
    reason -- a converge is an attended operation that legitimately runs for
    hours, and killing one at an arbitrary deadline is the one thing worse than
    letting it finish.
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
        try:
            completed = subprocess.run(
                ["ansible-playbook", *arguments], env=environment, check=False
            )
        except OSError as error:
            print(
                f"production auto-deploy: could not run ansible-playbook: {error}",
                file=sys.stderr,
            )
            return 1
        return completed.returncode


def _next_poll_verdict(config: Config, state: dict) -> tuple[str, str]:
    """Explain what the next poll would do, without doing any of it.

    Silence is the normal outcome of a poll, so an operator otherwise cannot
    tell a healthy idle poller from a broken one.
    """

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
        successful = state["last_successful"]
        if successful is not None and successful["sha"] == stopped:
            return head, f"nothing to do: {stopped[:9]} is deployed"
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
    head, verdict = _next_poll_verdict(config, state)
    print(f"current {config.branch}: {head}")
    print(f"next poll: {verdict}")


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
        elif argument == "--retry-failed" and remaining and mode is None:
            mode = "retry"
            retry_sha = remaining.pop(0)
        elif argument == "--converge" and mode is None:
            # Everything after --converge belongs to ansible-playbook, not to
            # this parser: the operator's own flags are passed through
            # unexamined, and several of them (--check, --diff, --tags) collide
            # with nothing here only because parsing stops at this point. The
            # launcher supplies --config first, so it is always already seen.
            mode = "converge"
            playbook_arguments = list(remaining)
            remaining = []
            if playbook_arguments and playbook_arguments[0] == "--":
                playbook_arguments = playbook_arguments[1:]
        else:
            return None
    if config_path is None or mode is None:
        return None
    if mode == "retry" and (
        retry_sha is None or SHA_PATTERN.fullmatch(retry_sha) is None
    ):
        return None
    if mode == "converge" and not playbook_arguments:
        return None
    return config_path, mode, retry_sha, playbook_arguments


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
        outcome = poll(config, retry_sha=retry_sha)
    except ConfigurationError:
        print("production auto-deploy: unusable configuration", file=sys.stderr)
        return 1
    except EligibilityError:
        # Not "nothing to deploy": poll() returns None for that. Reaching
        # here means the candidate could not be established at all.
        print("production auto-deploy: could not determine a candidate",
              file=sys.stderr)
        return 0
    if outcome is False:
        print("production auto-deploy: attempt failed", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
