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
# The fetch in update_checkout gets neither of the two budgets around it. Not
# ls-remote's ten seconds above, because a fetch legitimately transfers; not
# COMMAND_TIMEOUT_SECONDS below, because it runs while this process holds the
# deployment lock, and #351 is what an hour of that costs -- a blackholed
# connection parked the lock for an hour, during which deployment_bundle refuses
# every hand-run converge and the polls in the window return None. The packed
# repository is nine megabytes and this fetch is incremental against a checkout
# that already exists, so three minutes is headroom over a slow link rather than
# a budget anything legitimate can reach.
GIT_FETCH_TIMEOUT_SECONDS = 3 * 60
# merge-base and checkout reach no network at all. What they can still wait on
# is a stuck filesystem, and an hour of that is an hour of the lock just the
# same, so they are bounded too -- generously, because a checkout writes files.
GIT_LOCAL_TIMEOUT_SECONDS = 60
NOTIFICATION_TIMEOUT_SECONDS = 10
# The tests raise the notification budget on a loaded machine, where spawning the
# stub curl alone can outlast ten seconds (#319's shape). Unset or unusable, it is
# NOTIFICATION_TIMEOUT_SECONDS; it never exceeds five minutes of a held lock.
NOTIFICATION_TIMEOUT_ENVIRONMENT = "PLATFORM_AUTO_DEPLOY_NOTIFICATION_TIMEOUT_SECONDS"
NOTIFICATION_TIMEOUT_CEILING_SECONDS = 5 * 60
# curl's own total budget for one healthchecks.io ping (#606). The ping runs
# after the deployment lock is released, so this bounds a tick's wall time and
# never the lock; the process deadline is a backstop for a curl that ignores it.
HEALTHCHECKS_TIMEOUT_SECONDS = 10
# https, and nothing a curl config line would read as more than one URL: no
# whitespace, which ends the value or starts a directive, and no quote or
# backslash, which end or escape it. Byte for byte the vault contract's HTTPS_URL
# in filter_plugins/vault_credential_schema.py, which tests/policy_vault_test.rb
# holds: drift would let the contract accept a URL this poller ignores, and the
# check would then alert on silence from a healthy poller.
HEALTHCHECKS_URL_PATTERN = re.compile(r'^https://[^\s"\\]+\Z')
# Consecutive polls that fail before eligibility is even decided. At the
# five-minute cron cadence this is a quarter hour of being unable to see
# main, which no transient network blip should reach.
BLIND_POLL_THRESHOLD = 3
# Pushover's own caps, spelled exactly as services/dozzle/alert_relay.py and
# scripts/image_prune.py spell them; tests/policy_test.rb holds the copies
# identical. Over any of them is a 4xx and a lost message rather than a cut one.
# The escaped-field bound is on html_escape's result, because escaping expands.
MAX_ESCAPED_FIELD_CHARACTERS = 384
MAX_MESSAGE_CHARACTERS = 1024
MAX_TITLE_CHARACTERS = 250
# The tap-through link: https only, and omitted rather than cut when too long.
MAX_URL_CHARACTERS = 512
MAX_URL_TITLE_CHARACTERS = 100
COMMAND_TIMEOUT_SECONDS = 60 * 60
# --verify holds the deployment lock for as long as verify.yml runs, and #351 is
# what an hour of a held lock costs. Half the hourly cadence, so a stuck run is a
# failure before the next one is due rather than a lock the next poll waits out.
VERIFY_TIMEOUT_SECONDS = 30 * 60
# Each hourly-only tag runs after the services, in the same lock hold, under its
# own budget, so a service run that timed out still leaves it one. The hold is at
# most 30 + 10 per hourly-only tag: 40 minutes today, under the hourly cadence.
HOURLY_ONLY_VERIFY_TIMEOUT_SECONDS = 10 * 60
# One palette for styled messages: mid-tones that read on Pushover's light and
# dark themes alike. Green is recovered, healthy or new; red failed or killed;
# amber degraded; grey metadata. Spelled identically in scripts/image_prune.py
# and services/dozzle/alert_relay.py, and tests/policy_test.rb holds the copies
# identical, so one state reads as one colour whichever program sent it.
COLOR_GREEN = "#2e7d32"
COLOR_RED = "#c62828"
COLOR_AMBER = "#f9a825"
COLOR_GREY = "#9e9e9e"
# What an hourly-only tag's failure looks like in its log, and what each change
# of its verdict pages as: a title, a lead line, and a closing line that may be
# empty. The array run also runs verify.yml's always-tagged setup (Docker
# modules, vault contract, GPU, Compose files), and a failure there is no
# evidence about the disks, so "degraded" is claimed only when the log carries
# the literal that opens roles/host_prep/tasks/verify_mdraid.yml's fail_msg. Any
# other failure, a timeout included, is "unchecked": the check could not run. The
# record keeps which, so a recovery says "healthy" only after a real mismatch.
MDRAID_MISMATCH_MARKER = "MDRAID-BASELINE-MISMATCH"
HOURLY_ONLY_VERIFY_CHECKS = {
    "platform_verify_mdraid": {
        "marker": MDRAID_MISMATCH_MARKER,
        "fail": (
            "\U0001f7e0 RAID degraded",
            f'<b>RAID arrays</b> are <font color="{COLOR_RED}">degraded</font>',
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
}
TOOLING_TIMEOUT_SECONDS = 15 * 60
# The ladder for the three commands in a deployment that reach a third party:
# the checkout fetch, the pip install and the collection install. Few attempts,
# because they are retried only when they fail fast, and a fast failure that
# repeats three times in seven seconds is not a blip. The backoffs are one
# shorter than the attempt count by construction, and are spent under the
# deployment lock, which is why they are seconds rather than the minutes an
# unlocked ladder could afford.
NETWORK_RETRY_ATTEMPTS = 3
NETWORK_RETRY_BACKOFF_SECONDS = (2, 5)
# Consecutive ticks a revision may fail transiently before it is quarantined
# anyway. Forgiving without a bound is worse than not forgiving: a cause that
# only looks transient would be retried every five minutes forever, holding the
# lock for most of each one, which is the starvation this issue is about.
TRANSIENT_FORGIVENESS_LIMIT = 3
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
# Where site.yml writes what a release shipped, for announce_release (#558).
# deploy() alone exports it: the manifests and the Git history are read inside
# the play, and this script has no YAML parser. An operator's --converge never
# carries it, so site.yml publishes its own plain summary there instead.
SUMMARY_PATH_ENVIRONMENT = "PLATFORM_DEPLOYMENT_SUMMARY_PATH"
# The GitHub API is called anonymously: sixty requests an hour per address, of
# which the five-minute poll spends twelve. A Renovate batch can move dozens of
# images, so release-notes links stop at this many lookups and this budget.
MAX_PULL_REQUEST_LOOKUPS = 8
PULL_REQUEST_LOOKUP_BUDGET_SECONDS = 30


class ConfigurationError(ValueError):
    """The on-disk configuration cannot be trusted to drive a deployment."""


class EligibilityError(RuntimeError):
    """No candidate revision could be established for this poll."""


class DeploymentError(RuntimeError):
    """The candidate revision could not be deployed."""


class TransientDeploymentError(DeploymentError):
    """The deployment failed for a reason that says nothing about the revision.

    Raised only from the steps that run before the first play, so a revision
    that fails this way changed nothing on the target and the next tick may try
    it again. Every raiser is either a network-shaped command whose retry ladder
    is exhausted or a command that timed out, and a timeout is evidence about
    the host rather than about what is being deployed.
    """


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
    # Checks only the hourly --verify run selects, each in an invocation and a
    # verdict record of its own, because a deployment must not fail on them.
    # Comma-separated; optional in the file: see load_config.
    hourly_only_verify_tags: str
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
    # Dead-man's-switch check URLs at healthchecks.io, one per signal: the tick
    # heartbeat and the hourly verify verdict (#606, #610). Secret: the token in
    # the path is the check's whole authentication. Empty means no ping, which
    # is what an older configuration reads as; see load_config.
    healthchecks_poller_ping_url: str = ""
    healthchecks_verify_ping_url: str = ""
    # The protected curl config of each Pushover application this poller sends
    # to (#558): the Alerts app for what needs a human, the Deployments app for
    # routine records. Each holds its own application's token and the user key,
    # so no credential reaches this file or a command line. None means that
    # application cannot be published to; see load_config.
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


def load_config(path: str | os.PathLike[str]) -> Config:
    """Read the non-secret poller configuration written by the installer role."""

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
            # Never a refusal (#327). The install play copies this script before
            # it renders the file, so the first tick after the move to Pushover
            # reads a configuration the ntfy-era template wrote, which names no
            # Pushover config at all. Refusing it would stop every deployment
            # with nothing able to heal the host; reading it as "cannot publish"
            # costs one tick's notifications and one stderr line.
            raw = payload.get(field.name)
            usable = type(raw) is str and Path(raw).is_absolute()
            values[field.name] = Path(raw) if usable else None
            if not usable:
                unpublishable.append(field.name)
            continue
        if field.name in _PING_URL_FIELDS:
            # Never a refusal, in either direction. Absent is every configuration
            # written before #606 and the one this poller meets when the install
            # play copies it and then fails to render (#327). Unusable is a
            # monitoring value that must not stop deployments. Both read as "no
            # ping", and the external check alerts on exactly that silence.
            raw = payload.get(field.name, "")
            usable = type(raw) is str and HEALTHCHECKS_URL_PATTERN.match(raw)
            values[field.name] = raw if usable else ""
            continue
        if field.name not in payload:
            # The install play copies this script before it renders the file, so
            # for one run -- or for good, if the render fails -- this poller reads
            # a configuration an older template wrote. Refusing it would fail
            # every tick with nothing able to heal it (#327). Absent means no
            # hourly-only checks: the services still verify, and the array check
            # starts once the render lands. An older file's periodic_verify_tags
            # is ignored on purpose, since it restates the whole deploy list.
            if field.name == "hourly_only_verify_tags":
                values[field.name] = ""
                continue
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
    # Two URLs for one check is what the vault contract refuses, compared by the
    # same function. A configuration that still carries them pings neither, so
    # both checks go silent and alert, rather than every tick vouching for a
    # verify that stopped running.
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


def _run_network_command(
    arguments, *, failure: str, budget: float, **options
) -> subprocess.CompletedProcess:
    """Run one command that reaches a third party, under a total deadline.

    Two properties matter more here than the retry itself.

    The budget is a *total*. Every attempt draws from one deadline, so a ladder
    can never hold the deployment lock longer than the single attempt it
    replaced -- which is the whole point of #351, and exactly what a plain
    retries=3 over an hour-long timeout would have made three times worse.

    And a timeout is never retried in place. A stalled attempt has already spent
    the budget, and the next five-minute tick will try again with the lock
    released, which is the only kind of waiting that costs nobody else anything.
    A killed `git fetch` can also leave its own ref locks behind, so retrying it
    immediately is the least likely attempt to succeed. Only a fast non-zero
    exit is retried, and those are cheap enough that several fit under one
    deadline.

    An exhausted ladder is transient because every caller is network-shaped: a
    fetch here runs seconds after ls-remote proved the remote and the branch
    reachable, a pip install reaches pypi.org and a collection install reaches
    galaxy.ansible.com. A cause that is not really transient still fails
    identically every tick, which is what may_retry_after_transient_failure
    bounds.
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
    payload = _github_get(config, f"actions/workflows/{config.workflow}/runs?{query}")
    try:
        runs = payload["workflow_runs"]
    except (KeyError, TypeError) as error:
        raise EligibilityError("GitHub response is invalid") from error
    if not isinstance(runs, list):
        raise EligibilityError("GitHub response is invalid")
    return tuple(run for run in runs if isinstance(run, dict))


def _github_get(config: Config, path: str, timeout: float = NETWORK_TIMEOUT_SECONDS):
    """One bounded, anonymous GitHub API read under this repository, parsed as JSON.

    EligibilityError for anything that is not a readable answer.
    """

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

    Renovate merges by rebase, so its commits carry no "(#NNN)" to read a number
    from; GitHub's commit-to-pull-request index is the only record. Renovate's
    pull request body carries the upstream release notes, which is why the link
    is worth a request. EligibilityError when GitHub cannot say.
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

    Each commit is asked about once, at most MAX_PULL_REQUEST_LOOKUPS of them,
    inside one total deadline. The first failure -- a 403 for a spent rate
    limit included -- ends the lookups: asking again only spends more of a
    budget the next poll needs, and the cost is links, never the message.
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


def _transient_path(config: Config) -> Path:
    return config.state_root / "transient-failures"


def read_transient_failures(config: Config) -> tuple[str | None, int]:
    """The revision currently being forgiven, and how many ticks it has cost.

    Unreadable or unrecognisable state reads as no revision at all, exactly as
    read_blind_polls treats its own: this file bounds a retry, so losing it must
    cost the retry rather than the poller.
    """

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

    The counter is per revision, so a different candidate starts the budget
    over and a revision that eventually deploys leaves an inert record behind
    rather than needing to be cleared. Reaching the limit clears the record and
    refuses: the revision is quarantined as it would have been before, because a
    cause that has failed identically for TRANSIENT_FORGIVENESS_LIMIT ticks is
    not the network blip this exists to absorb.

    Fails closed. A counter that cannot be written cannot bound the forgiveness
    it grants, and an unbounded retry would hold the deployment lock for most of
    every five minutes -- worse than the quarantine it replaces.
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
    """The one file every deployment on this host serialises on.

    Named here rather than in each caller because roles/deployment_bundle has to
    find the same file from Ansible, and it derives it from the account's home
    exactly as roles/production_auto_deploy derives state_root. Two spellings of
    one path would be a lock nobody shares.
    """

    return config.state_root / "deployment.lock"


# The flock alone says only that somebody is deploying, and #326 is exactly the
# story of an operator who could not tell what was happening: the race surfaced
# as a containment refusal naming an unsafe deployment target, so the honest
# first reading was a corrupted deployment tree rather than a second converge. A
# holder that says "pid 4711, operator converge, started at ..." turns that into
# a fact. That is this script's own history, so it sits above the definition,
# where the identity comparison below does not read it.
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


def deployment_lock_held(config: Config) -> bool:
    """Whether somebody holds the deployment lock, asked without becoming its holder.

    For --status, which must stay read-only: the file is opened read-only so an
    absent one is never created, no holder record is written, and a free lock is
    released here rather than at close so the poller's own next tick cannot see
    this read as a deployment. The same probe as
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


def update_checkout(config: Config, sha: str, log=None) -> None:
    """Materialise the candidate revision in the controller checkout.

    A candidate behind the head is named by GitHub's record of what it ran,
    which is a record of the past: a revision can have been rewritten off the
    branch since. Only the branch just fetched says what main is now, so the
    revision has to be an ancestor of it before anything is checked out --
    against FETCH_HEAD, which this fetch wrote, rather than a remote-tracking
    ref some other command may have left behind.

    The three steps are on two budgets and two failure classes, because only the
    first of them reaches the network. A fetch that fails is somebody else's
    outage seconds after ls-remote reached the same remote, so it retries and is
    transient. `merge-base --is-ancestor` returning non-zero is the answer to
    its question -- the revision was rewritten off the branch -- and a failing
    checkout is a local repository that needs a person; both are permanent facts
    about this candidate and quarantine it. A timeout is neither: it says the
    host is stuck, so it is transient wherever it happens.
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
    """Match the controller virtualenv to the candidate's own pins.

    This has to happen before any ansible process starts, which is why the
    checkout is done with git rather than ansible-pull: the tooling that would
    run ansible-pull is the very tooling being corrected.
    """

    # This reaches pypi.org, so it takes the ladder and its failure is
    # transient (#415). It keeps TOOLING_TIMEOUT_SECONDS unchanged: the budget
    # is a total the attempts and their backoffs share, so the ladder can never
    # hold the deployment lock longer than the single attempt it replaces.
    requirements = config.checkout / "controller-requirements.txt"
    _run_network_command(
        [
            _tooling_bin(config) / "pip",
            "install",
            "--quiet",
            "--upgrade",
            "--requirement",
            str(requirements),
        ],
        failure="controller tooling could not be synchronised",
        budget=TOOLING_TIMEOUT_SECONDS,
        cwd=config.checkout,
        env={"PATH": config.tool_path, "LC_ALL": "C"},
        log=log,
    )

    # Collections are a separate dependency set from the Python pins, and the
    # modules the playbooks call live in them. This one reaches
    # galaxy.ansible.com, so it takes the same ladder for the same reason.
    _run_network_command(
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
    """Every play runs through ansible-playbook from the candidate checkout.

    verify.yml carries its tag list and the others must not receive it, so the
    tags belong to individual invocations rather than one shared command.
    """

    vault = _vault_arguments(config)
    return (
        ["ansible-playbook", *vault, "validate-vault.yml"],
        ["ansible-playbook", *vault, "site.yml"],
        _verify_invocation(config, config.verify_tags),
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
    """Deploy one candidate revision, stopping at the first failing play.

    False means this revision failed. TransientDeploymentError means the
    deployment failed without ever reaching the target, and the caller owns what
    that costs -- it is raised rather than folded into False because
    TransientDeploymentError is a DeploymentError, so the broad clause below
    would otherwise swallow the classification and leave a change that reads
    correctly and does nothing.
    """

    # Here and nowhere else: verify.yml shares _ansible_environment, and an
    # operator's converge must keep the plain summary site.yml publishes itself.
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

    The same verdict as roles/ntfy/tasks/pushover_publish.yml (#598): 200 with
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


def commit_link(config: Config, sha: str) -> str:
    """The revision as an <a href> to its commit page, for an html=1 message.

    The SHA is validated hex; the repository is configuration, so it is escaped
    with the quotes that would otherwise end the attribute.
    """

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
    retrying: bool = False,
) -> dict:
    """Build the Pushover fields for a failed deployment.

    Only a failure is rendered here. A successful deployment reports itself from
    inside the run, where what shipped is still at hand. retrying is whether the
    attempt was forgotten after a transient failure, which is the one case the
    next poll takes the same revision again.
    """

    details = [f"\U0001f516 <b>Revision</b> {commit_link(config, sha)}"]
    if run_link(run_url):
        details.append(run_link(run_url))
    details += [
        f"\U0001f552 <b>When</b> {readable_time(finished)}",
        f"⏱️ <b>Took</b> {format_duration(started, finished)}",
        log_line(log_path),
    ]
    closing = (
        "<i>Nothing reached the host; the next poll tries this revision again.</i>"
        if retrying
        else "<i>The poller will not retry this revision; merge a fix to main.</i>"
    )
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
    retrying: bool = False,
) -> bool:
    """Publish a failed deployment to the Alerts application."""

    return publish(
        config,
        "alerts",
        render_notification(config, sha, started, finished, log_path, run_url, retrying),
    )


def _summary_path(config: Config) -> Path:
    return config.state_root / "deployment-summary.json"


_IMAGE_KINDS = frozenset({"updated", "added", "removed", "repinned"})


def read_release_summary(path: Path, candidate: str) -> dict:
    """The summary site.yml wrote for candidate; ValueError when there is none to trust.

    Version 1 and this very release, or nothing: a file left by an earlier
    release, or by a site.yml that predates the handshake, describes something
    else. Every field is checked before any of it reaches a message.
    """

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

    fit_message drops lines from the end, which would take the footer first, so
    the body is sized here: commits give way before images, each dropped run of
    lines is counted in its own section, and fit_message is only the backstop.
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
    # Links in the body name twelve-character SHAs, which GitHub resolves: the
    # markup counts against Pushover's 1024, and full SHAs alone pushed an
    # ordinary three-image, four-commit release over it. The button has its
    # own 512 and keeps them whole.
    commit_lines = [
        f'• <a href="https://github.com/{repository}/commit/{commit["sha"][:12]}">'
        f"{html_escape(commit['subject'])}</a>"
        for commit in summary["commits"]
    ]
    duration = format_duration(started, finished)
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

    Never raises and never changes an outcome: the release is already recorded
    as deployed, and a message about it is worth no more than that. A summary
    that is missing -- a site.yml older than the handshake -- stale or malformed
    costs the message; GitHub unreachable costs the release-notes links; a
    refused or unanswered send costs the message. Each says so in one stderr
    line, and none is retried: the next release has its own message.
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

    app is "alerts" or "deployments". The token and the user key live only in
    that application's protected curl config, so argv -- readable by every
    account on the host, and carried whole by a TimeoutExpired -- holds nothing
    but the message. Every field goes as --form-string, which never reads a
    leading @ or < as a file.

    Only an accepted answer counts as delivered, so a state record that moves
    after delivery does not move on a refusal or on silence. A refusal names the
    vault keys to fix and never a value; neither outcome raises, because a
    notification nobody received must not also stop a deployment.
    """

    # An application this script configures no curl config for reads as cannot
    # publish, like an unconfigured one, rather than raising.
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
        # ValueError is a NUL byte in a field, which no argv can carry: nothing
        # was sent, and a notice that cannot be sent must not raise either.
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
    """A ping URL's /fail sibling: on the path, before any query (#606).

    Appending to the whole string put it after a query -- `uuid?rid=42/fail` --
    which healthchecks.io reads as a plain success ping. The fragment is never
    sent anyway, so it is dropped rather than left to carry the suffix.
    """

    parts = urlsplit(url)
    return urlunsplit(parts._replace(path=f"{parts.path.rstrip('/')}/fail", fragment=""))


def ping_healthchecks(config: Config, url: str, failed: bool) -> None:
    """Report one run to an external dead-man's switch. Never raises (#606).

    Every alert this platform raises comes from the host it would be reporting
    about, so a stopped host, daemon or cron says nothing. healthchecks.io
    alerts when these pings stop, from outside, and marks a check down at once
    on `/fail`.

    The URL goes to curl on stdin, never on the command line: argv is readable
    by every account on the host, and a TimeoutExpired carries argv in its repr.
    curl's own output is captured and dropped because its errors name the URL;
    the one line printed here names nothing. And no failure here can change an
    exit code or a recorded state -- a monitor that fails a deployment is worse
    than the silence it replaces, and the silence is reported anyway.
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
        # -1 on the Alerts app: it closes an alarm, so it belongs beside it,
        # and it is a record rather than something to wake anybody for.
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
            # The operator's explicit retry starts the forgiveness budget over
            # too. Inheriting a spent one would quarantine the revision again on
            # the first blip after the very intervention meant to clear it.
            clear_transient_failures(config)

        # Recorded before the attempt: a crash mid-deploy must not become a
        # retry loop on the next five-minute tick.
        record_attempt(config, candidate)
        started = _timestamp()
        retrying = False
        with attempt_log(config, candidate) as log:
            log_path = Path(log.name)
            try:
                succeeded = deploy(config, candidate, log)
            except TransientDeploymentError as error:
                # Nothing reached the target: every step that raises this runs
                # before the first play. So the attempted record can be undone,
                # and the next tick retries the revision rather than an operator
                # -- #351, on a host whose premise is that nobody touches it.
                # Bounded, and only ever undone here, where the record was made.
                succeeded = False
                note = f"production auto-deploy: transient failure: {error}"
                log.write(note.encode("ascii", "replace") + b"\n")
                if may_retry_after_transient_failure(config, candidate):
                    forget_attempt(config, candidate)
                    retrying = True
            finished = _timestamp()
            if succeeded:
                record_success(config, candidate, finished)
                # After the record, so nothing about the message can change
                # it. What shipped was written by site.yml, which read the
                # manifests and the Git history; succeeded means verify.yml
                # passed too, so this is the one message a release gets.
                announce_release(config, candidate, started, finished)
            # A failure is announced here, best effort but never silent: a
            # misconfigured publisher would otherwise lose every failure with
            # nothing to show for it.
            #
            # The link is to the run that released the revision, which is what
            # a human opens first to see what changed and whether it was green.
            if not succeeded and not notify(
                config,
                candidate,
                started,
                finished,
                log_path,
                selection.verdict[2] if selection.verdict else "",
                retrying=retrying,
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
        # Never inherited: announce_release does not run after an operator's
        # command, so a converge that wrote the summary would announce nothing.
        environment.pop(SUMMARY_PATH_ENVIRONMENT, None)
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


def _verify_verdict_path(config: Config, tag: str | None = None) -> Path:
    """verify-verdict for the services; verify-verdict-<name> per hourly-only tag."""

    suffix = "" if tag is None else "-" + tag.removeprefix("platform_verify_")
    return config.state_root / f"verify-verdict{suffix}"


def _hourly_only_tags(config: Config) -> list[str]:
    return [tag for tag in config.hourly_only_verify_tags.split(",") if tag]


def read_verify_verdict(config: Config, tag: str | None = None) -> str | None:
    """The last verdict --verify recorded: "pass", "fail", or None for no record.

    A file of its own, like every other fact in the state directory, so poll()
    never rewrites it and a state directory from an older poller simply lacks it.
    """

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

    No record reads as a pass: a first failure pages and a first pass does not.
    The record moves only after delivery, as note_ci_refusal's does, because a
    recorded failure nobody received would make every later one a quiet repeat.
    tag None is the services' verdict; an hourly-only tag keeps its own record and
    pages under its own title, so the two signals never mask each other (#609).
    failure is "fail", or "unchecked" for an hourly-only check that could not run;
    a record of either pages its change, and only "fail" is recovered from.
    """

    verdict = "pass" if passed else failure
    previous = read_verify_verdict(config, tag)
    if verdict == previous:
        return
    if verdict != "pass" or previous is not None:
        failed = verdict != "pass"
        run_url = ""
        if failed and tag is None:
            # Best effort, and only here, where the verdict changed: one more
            # anonymous GitHub request, whose failure costs the link and nothing
            # else.
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
    # Caught rather than raised: verify.yml did run, so "could not verify" would
    # be false. The cost of an unwritable state root is a page every run, which
    # is the loudest way to report it.
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

    It runs from the controller checkout, which is the only tree carrying the
    playbooks, and only while that checkout holds the last successful revision.
    A deployment detaches it to the candidate before any play runs, so after a
    failed one it holds a revision whose verify.yml may name services that never
    activated -- and that failure has already paged. Verification resumes with
    the next successful deployment.

    Under the deployment lock, taken without waiting (#326): a deployment in
    progress runs verify.yml itself, and the next hour tries again. Nothing here
    writes the attempted record or the last success, so a failed verify cannot
    hold back the next poll.
    """

    with deployment_lock(config, holder="verify") as acquired:
        if not acquired:
            print(
                "production auto-deploy: verify skipped, "
                f"{_holder_description(read_lock_holder(config))} holds "
                f"{lock_path(config)}"
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
        # verify.yml runs its roles before its tasks, and a failing host leaves
        # the run, so a service failure in the same invocation would hide an
        # hourly-only check and a paged one would hide the services (#609). One
        # invocation and one record per tag, whatever the services' outcome.
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
        # poll() records the attempt before it deploys, so attempted-and-not-
        # successful is also what a deployment in progress looks like: on
        # 2026-09-13 this reported a converging revision as failed and offered
        # --retry-failed against it. The flock is the liveness truth. State is
        # read after the probe, so a deployment that finished during the CI
        # query above reads as deployed rather than as failed.
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
        if mode == "verify":
            # The verify check's ping (#610), keyed only on what verify() hands
            # back, so it survives any change to how verify() reaches its
            # verdict. True pings plain and False pings /fail, every run,
            # whatever note_verify_verdict decided to page: the check needs the
            # heartbeat, not the change. A run that could not verify at all -- any
            # raise, OSError included, which leaves `passed` False -- pings /fail
            # as well, because off the box a verification that could not run is
            # a failure. None is a skip -- lock held, nothing deployed, the
            # checkout not at the deployed revision -- and pings nothing, so a
            # verify that keeps skipping goes silent and alerts after the grace
            # period, which is the state that must not hide. ping_healthchecks
            # never raises, so this `finally` changes no exception, return value
            # or message.
            passed = False
            try:
                passed = verify(config)
            except OSError as error:
                # Nothing was verified, so no verdict is recorded and Pushover hears
                # nothing; the external verify check still hears /fail from the
                # `finally` below.
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
        # The tick heartbeat (#606), sent after poll() has released the lock.
        # None is healthy: nothing to deploy, a quarantined revision waiting for
        # an operator, or the lock held by a deployment or a verify. True is a
        # deployment. False is a failed deployment and pings /fail, but only for
        # the tick that failed: the revision is quarantined after one attempt,
        # so the ticks after a #327- or #559-shaped failure have nothing to do
        # and ping plain again -- /fail, then plain, then plain. A transient
        # failure is retried for up to TRANSIENT_FORGIVENESS_LIMIT ticks and
        # pings /fail on each. That is the intent rather than a gap: a failure
        # that persists on the box is paged there, through Pushover, and --status
        # names the revision; these external checks exist to hear the NAS or
        # the poller being gone, which nothing on the box can report. An
        # unhandled raise leaves `outcome` False: a tick that did not finish.
        # An EligibilityError pings plain: GitHub could not be read, but the
        # poller is alive and deciding, and sustained blindness already pages
        # on-box after BLIND_POLL_THRESHOLD polls, where a /fail here would page
        # off-box on a single GitHub blip. A manual --retry-failed pings
        # nothing, so it cannot vouch for a dead cron. ping_healthchecks never
        # raises, so this `finally` changes no exception, exit code or message.
        outcome = False
        try:
            outcome = poll(config, retry_sha=retry_sha)
        except EligibilityError:
            outcome = None
            raise
        finally:
            if mode == "poll":
                ping_healthchecks(config, config.healthchecks_poller_ping_url,
                                  outcome is False)
    except ConfigurationError:
        # No ping: the URL is in the file that could not be trusted. The tick
        # check hears silence and alerts once its grace period runs out.
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
