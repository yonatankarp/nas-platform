#!/usr/bin/env python3
"""Private authenticated relay for Dozzle container events and Beszel host alerts."""

from __future__ import annotations

import contextlib
from datetime import datetime, timedelta, timezone
import fcntl
import hmac
import html
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import re
import secrets
import signal
import stat
import sys
import threading
import urllib.error
import urllib.parse
import urllib.request


# The signals a deliberate stop arrives as: `docker stop` sends SIGTERM and
# SIGKILLs at the end of the grace period, and SIGINT is what a foreground run
# ends on. See serve_until_stopped for why they are blocked rather than handled.
STOP_SIGNALS = frozenset({signal.SIGINT, signal.SIGTERM})
MAX_BODY_BYTES = 16 * 1024
MAX_STATE_BYTES = 64 * 1024
MAX_STATE_ENTRIES = 128
# The ceiling's own bound on state growth, and the reason it is separate from
# MAX_STATE_ENTRIES rather than shared with it. A counter is not a health entry:
# bounded_state may drop any counter, because the global counter beneath them is
# what actually guarantees the quota, while a health entry may only be dropped
# once it is healthy. Sharing one bound would let counters take bytes from
# health entries that cannot be evicted.
#
# WHAT THAT BUYS IS A DEFERRAL, NOT A PREVENTION, and the difference is worth
# stating because the opposite was claimed here first. A document of nothing but
# unhealthy entries still reaches
# `raise StateError("unhealthy state exceeds bounds")` -- byte-identical to the
# line that has always been there, and not something the counters introduced.
# Measured: a short ASCII host stores 128 entries and fails at 129, which is
# MAX_STATE_ENTRIES binding rather than the byte bound; a 256-character
# non-ASCII host stores 39 and fails at 40. Shedding counters first buys back
# exactly the counters' own bytes and nothing more -- 39 entries reconcile
# alongside 128 counters by shedding all 128 -- so the entry ceiling is the same
# as it is with no counters at all. Thirty containers run on this NAS, so
# neither number is in reach.
MAX_BUDGET_ENTRIES = 128
HEALTHY_RETENTION = timedelta(days=30)
STATE_VERSION = 3
LEGACY_STATE_VERSIONS = (1, 2)
MINIMUM_TIMESTAMP = "0001-01-01T00:00:00Z"
DAY_PATTERN = re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2}\Z")
ENVELOPE_KEYS = {
    "version",
    "rule",
    "containerId",
    "container",
    "host",
    "event",
    "healthStatus",
    "exitCode",
    "timestamp",
}
RELATIONSHIPS = {
    "OOM": ("oom", "", ""),
    "Unhealthy": ("health_status", "unhealthy", ""),
    "Recovery": ("health_status", "healthy", ""),
}
CONTAINER_ID_PATTERN = re.compile(r"[0-9a-f]{12,64}\Z")
TIMESTAMP_PATTERN = re.compile(
    r"(?P<instant>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})"
    r"(?P<fraction>\.[0-9]{1,9})?Z\Z"
)
TIMESTAMP_FORMAT = "%Y-%m-%dT%H:%M:%S"
EXIT_CODE_PATTERN = re.compile(r"(?:0|[1-9][0-9]{0,2})\Z")
PORT_PATTERN = re.compile(r"[1-9][0-9]{0,4}\Z")
CEILING_PATTERN = re.compile(r"[1-9][0-9]{0,5}\Z")

# Pushover's emergency priority, and the two parameters it refuses a message
# without: the API rejects priority 2 outright unless both `retry` and `expire`
# are present. They are what the acknowledge semantic this relay exists for is
# made of -- the phone re-alerts every `retry` seconds until somebody
# acknowledges it, until `expire` seconds have passed, or until Pushover's own
# retry cap is reached, whichever comes first.
#
# THAT THIRD TERM IS EASY TO LEAVE OUT AND THIS COMMENT LEFT IT OUT. It read
# "an hour of re-alerting once a minute is already sixty alerts", which is
# arithmetic the API does not perform: Pushover caps a message at 50 retries
# regardless of `expire`, and says so in its own worked example, where
# retry=30 with expire=10800 escalates for 25 minutes rather than three hours.
# So what this configuration actually does is re-alert every 60 seconds and
# stop at the cap, about 50 minutes in, or the moment somebody acknowledges.
#
# WHY `expire` STAYS ABOVE WHAT THE CAP CAN REACH. 3600 leaves roughly ten
# minutes the cap makes unreachable, and that slack is deliberate rather than
# an oversight now that it is measured: the two are independent bounds, one on
# elapsed time and one on count, and `expire` is the one that stays correct if
# `retry` is ever changed. Lowering it to 50 * 60 would make the two coincide
# today and silently become the binding term the moment `retry` moved. The
# assertion below is what keeps this paragraph true: the cap must be the term
# that fires first.
#
# Both values are interior to Pushover's documented bounds rather than at them
# (retry floor 30 seconds, expire ceiling 10800), so a message is accepted
# whatever the exact limits are today.
#
# NOT ROLE-CONFIGURABLE, unlike the ceilings below, and that is a decision. The
# ceilings are numbers a household might reasonably want to tune and cannot set
# to anything Pushover would reject. These two can: below 30 or above 10800 the
# API refuses the message, so every out-of-memory alert would be lost to a 4xx
# the relay reports only as a 502. A knob whose wrong setting silences the one
# alert this transport was chosen for is worth more than the tuning it offers.
#
# Retries do not each cost a message against the monthly quota -- one emergency
# message is one message however many times Pushover re-alerts it -- so the
# ceiling below is a bound on the relay's event rate, not on this.
EMERGENCY_PRIORITY = 2
EMERGENCY_RETRY_SECONDS = 60
EMERGENCY_EXPIRE_SECONDS = 3600
# Pushover's own cap, named so the claim above is checkable rather than prose.
# Nothing sends this value -- it is not a parameter -- but the paragraph above
# depends on the cap being the binding term, and a later edit to `retry` could
# make that false without touching a line of it.
#
# Checked by tests/dozzle_alert_relay_test.py rather than here. A module-level
# assertion would have been the wrong place by some distance: these are literals
# in this file, so only a developer can get them wrong, and refusing to start
# would turn a too-short escalation window -- which still alerts -- into a relay
# that reports nothing at all. The gate is where a developer's mistake belongs.
EMERGENCY_MAX_RETRIES = 50

# Pushover refuses a message longer than 1024 characters, and refuses it with a
# 4xx -- so an over-long alert is not a truncated alert, it is a lost one. The
# bound below is on the ESCAPED length rather than on the input, which is the
# half a bound on the input cannot reach: `'` becomes `&#x27;`, so 128
# characters of container name can render as 768 and two such fields overrun the
# cap between them. Real Docker names cannot contain any of the five escaped
# characters, so nothing on this platform reaches it; the envelope accepts any
# non-control text in that field, so something could.
#
# 384 apiece keeps any one line well inside the cap. The whole message is not
# bounded by construction any more: the container's name appears in the lead and
# in a detail line beside a link of up to 512 characters, so compose_message
# drops detail lines from the last until it fits.
MAX_ESCAPED_FIELD_CHARACTERS = 384
MAX_MESSAGE_CHARACTERS = 1024
# The title has a cap of its own, 250, and it is reached by a shorter input than
# the message cap is: the title is NOT escaped, so nothing expands, but it is
# also not bounded by anything except the slice in each renderer. The envelope
# admits a 256-character container name, and 256 plus a prefix is already over.
# Named rather than left implicit in those slices because the slices are the
# whole guard -- removing one produced a 268-character title and a lost alert
# while every test stayed green.
MAX_TITLE_CHARACTERS = 250
MAX_TITLE_CONTAINER_CHARACTERS = 128

# The tap-through link to the container's page in Dozzle, and Pushover's caps on
# it: `url` at most 512 characters, `url_title` at most 100. Over either is a
# 4xx and a lost alert, the same as an over-long message, so the link is bounded
# by construction rather than cut: the base is refused at start-up when it is
# longer than MAX_LINK_BASE_CHARACTERS, which leaves room for the route and the
# longest container id the envelope admits.
#
# The route is Dozzle's own, read from the pinned image's source (v11.0.1):
# assets/pages/container/[id].vue is the file-based route /container/:id, and
# the page looks the id up in a store keyed by container.id. That id is the
# 12-character short id -- internal/docker/client.go builds every container
# with c.ID[:12], and internal/notification/types.go hands that same field to
# the dispatcher template as .Container.ID -- so the envelope's containerId is
# exactly the key the page resolves.
MAX_URL_CHARACTERS = 512
CONTAINER_ROUTE = "/container/"
MAX_LINK_BASE_CHARACTERS = MAX_URL_CHARACTERS - len(CONTAINER_ROUTE) - 64
URL_TITLE = "Open in Dozzle"
MAX_URL_TITLE_CHARACTERS = 100

# Beszel's host alerts, POSTed to /beszel by Beszel 0.19.0's shoutrrr generic
# webhook with template=json: exactly {"title", "message"}, where message is
# Beszel's body followed by a blank line and a link (internal/alerts/alerts.go:
# SendShoutrrrAlert). Beszel sends a recovery through the same URL as the alert
# it closes, so it cannot give the two different priorities; this relay can.
BESZEL_ENVELOPE_KEYS = {"title", "message"}
# internal/alerts/alerts_status.go: sendStatusAlert. The body is the title with
# the emoji trimmed, so it carries nothing the title does not.
BESZEL_STATUS_TITLE = re.compile(
    r"Connection to (?P<system>.+) is (?P<state>down \U0001F534|up \u2705)\Z"
)
# internal/alerts/alerts_system.go: sendSystemAlert. The system name is the
# user's own text and may contain spaces, so the title is read from its fixed
# end: the direction, then a metric name from the list below, and whatever is
# left is the system.
BESZEL_THRESHOLD_TITLE = re.compile(r"(?P<rest>.+) (?P<direction>above|below) threshold\Z")
# Every metric name sendSystemAlert can put in a title, as it renders them:
# Disk becomes "disk usage", LoadAvgN becomes "Nm load", the CPU state alerts
# keep their labels, and everything but CPU and GPU is lowercased. Longest
# first, so a system is never read as ending in part of a longer name.
BESZEL_METRICS = (
    "CPU Steal Time", "CPU I/O Wait", "temperature", "disk usage", "bandwidth",
    "15m load", "battery", "5m load", "1m load", "memory", "CPU", "GPU",
)
# The one alert whose problem is the low side (alerts_system.go: isLowAlert).
# Not among beszel_alerts today; handled because it costs one comparison.
BESZEL_INVERTED_METRIC = "battery"
# "%s averaged %.2f%s for the previous %v %s." Anchored on the literals rather
# than on the unit, which is "%", "°C", " MB/s" or nothing at all.
BESZEL_AVERAGE_BODY = re.compile(
    r"(?P<descriptor>.+) averaged (?P<value>-?[0-9]+\.[0-9]{2})(?P<unit>.*)"
    r" for the previous (?P<minutes>[0-9]+) minutes?\.\Z"
)
# The link hub.MakeLink builds: the app URL, then /system/<PocketBase record id>,
# each part url.PathEscape'd. A record id is short and alphanumeric, so anything
# else after the route is refused rather than escaped, and a link that does not
# start with this relay's own configured base never reaches an href.
BESZEL_SYSTEM_ROUTE = "/system/"
BESZEL_SYSTEM_ID_PATTERN = re.compile(r"[A-Za-z0-9]{1,64}\Z")
BESZEL_URL_TITLE = "Open in Beszel"
# The palette scripts/production_auto_deploy.py documents, spelled as it spells
# it; tests/policy_test.rb holds the copies identical.
COLOR_GREEN = "#2e7d32"
COLOR_RED = "#c62828"
COLOR_AMBER = "#f9a825"
COLOR_GREY = "#9e9e9e"
# parse_timestamp counts from 0001-01-01; Pushover's `timestamp` is Unix seconds.
UNIX_EPOCH_SECONDS = (datetime(1970, 1, 1).toordinal() - 1) * 86_400

# How much of an upstream diagnostic reaches the log. Bounded because the text
# is the far end's rather than ours, because the stack caps this log at 10m x 3
# and a large error body would spend that, and because the clause an operator
# needs -- "user identifier is not a valid user" -- is at the front.
MAX_DIAGNOSTIC_CHARACTERS = 256
# How much of an error response is read at all. HTTPError is a file-like object
# on a socket, so an unbounded read is an unbounded wait inside the state lock.
MAX_DIAGNOSTIC_BYTES = 4096


class ConfigurationError(Exception):
    pass


class SchemaError(Exception):
    pass


class StateError(Exception):
    pass


class UpstreamError(Exception):
    pass


class NoRedirectHandler(urllib.request.HTTPRedirectHandler):
    def redirect_request(
        self, _request, _file_pointer, _code, _message, _headers, _url
    ):
        return None


NO_REDIRECT_OPENER = urllib.request.build_opener(NoRedirectHandler)


class Config:
    """Validated immutable runtime settings."""

    __slots__ = (
        "alert_relay_token",
        "alert_relay_port",
        "pushover_api_url",
        "alert_relay_link_base",
        "alert_relay_link_problem",
        "pushover_token",
        "pushover_user_key",
        "alert_state_path",
        "container_ceiling",
        "oom_container_ceiling",
        "global_ceiling",
        "pushover_alerts_token",
        "beszel_link_base",
        "beszel_link_problem",
    )

    def __init__(
        self,
        relay_token,
        relay_port,
        api_url,
        pushover_token,
        pushover_user_key,
        state_path,
        container_ceiling,
        oom_container_ceiling,
        global_ceiling,
        link_base,
        link_problem=None,
        alerts_token=None,
        beszel_link_base=None,
        beszel_link_problem=None,
    ):
        self.pushover_alerts_token = alerts_token
        self.beszel_link_base = beszel_link_base
        self.beszel_link_problem = beszel_link_problem
        self.alert_relay_token = relay_token
        self.alert_relay_link_base = link_base
        self.alert_relay_link_problem = link_problem
        self.alert_relay_port = relay_port
        self.pushover_api_url = api_url
        self.pushover_token = pushover_token
        self.pushover_user_key = pushover_user_key
        self.alert_state_path = state_path
        self.container_ceiling = container_ceiling
        self.oom_container_ceiling = oom_container_ceiling
        self.global_ceiling = global_ceiling

    @classmethod
    def from_mapping(cls, values):
        names = (
            "ALERT_RELAY_TOKEN",
            "ALERT_RELAY_PORT",
            "PUSHOVER_API_URL",
            "PUSHOVER_TOKEN",
            "PUSHOVER_USER_KEY",
            "ALERT_STATE_PATH",
            "ALERT_DAILY_CONTAINER_CEILING",
            "ALERT_DAILY_OOM_CONTAINER_CEILING",
            "ALERT_DAILY_GLOBAL_CEILING",
        )
        resolved = {}
        for name in names:
            value = values.get(name)
            if not isinstance(value, str) or not value or contains_control(value):
                raise ConfigurationError(f"{name} is required")
            resolved[name] = value

        # Deliberately without a fallback: the listener port has exactly one home,
        # dozzle_alert_relay_port in inventory/group_vars/all/service_dozzle.yml, and it reaches
        # this process through ALERT_RELAY_PORT in the rendered environment file.
        # A default here would be a second copy that could silently disagree with
        # the Compose healthcheck and the dispatcher URL built from the same home.
        port = resolved["ALERT_RELAY_PORT"]
        if not PORT_PATTERN.fullmatch(port) or int(port) > 65535:
            raise ConfigurationError("ALERT_RELAY_PORT must be a TCP port number")
        relay_port = int(port)

        # Unlike the publisher this replaced, the endpoint carries a path:
        # Pushover's message API is /1/messages.json, and the whole URL is a
        # variable rather than a host so a lane can redirect it at a recorder
        # without reaching the household's real devices. A query or a fragment
        # is refused because the credentials travel in the form body and a URL
        # carrying its own parameters is a sign of a hand-edited endpoint.
        parsed = urllib.parse.urlsplit(resolved["PUSHOVER_API_URL"])
        if (
            parsed.scheme not in {"http", "https"}
            or not parsed.hostname
            or parsed.username is not None
            or parsed.password is not None
            or not parsed.path.startswith("/")
            or parsed.path.endswith("/")
            or parsed.query
            or parsed.fragment
        ):
            raise ConfigurationError("PUSHOVER_API_URL must be an HTTP(S) endpoint URL")
        api_url = urllib.parse.urlunsplit(
            (parsed.scheme, parsed.netloc, parsed.path, "", "")
        )

        # The tap-through link is the one setting here the relay does WITHOUT
        # rather than refusing to start over. The relay script reaches the
        # container through the `current` release symlink, which
        # deployment_bundle repoints early in a converge, while this environment
        # is re-rendered only when roles/dozzle runs, several roles later. A relay
        # restarted inside that window runs the new script against the old
        # environment; had a missing link base been fatal, it would crash-loop
        # and lose every container alert until a later converge reached Dozzle --
        # indefinitely, if the deployment failed before then. CLAUDE.md's rule
        # is that anything new tolerates its absence for one deployment, and
        # #605's that a relay which refuses to start alerts worse than one that
        # alerts imperfectly. So an absent or invalid base costs the link only,
        # said once on stderr at start-up; the gate still refuses a role default
        # the validator would not accept (tests/dozzle_alert_relay_test.py).
        link_base = None
        link_problem = None
        raw_link_base = values.get("ALERT_RELAY_LINK_BASE")
        if not isinstance(raw_link_base, str) or not raw_link_base:
            link_problem = (
                "ALERT_RELAY_LINK_BASE is not set; alerts will carry no Dozzle link"
            )
        else:
            try:
                link_base = validated_link_base(raw_link_base)
            except ConfigurationError as error:
                link_problem = f"{error}; alerts will carry no Dozzle link"

        # Beszel's two settings are optional for the same reason, and for one
        # more: until a converge reaches roles/dozzle the running environment is
        # the one rendered before they existed. Without the Alerts token /beszel
        # answers 503 and says so on stderr; /alerts, which never needed it,
        # keeps working. Without a usable link base a Beszel alert carries no
        # button.
        alerts_token = values.get("PUSHOVER_ALERTS_TOKEN")
        if not isinstance(alerts_token, str) or not alerts_token or contains_control(alerts_token):
            alerts_token = None
        beszel_link_base = None
        beszel_link_problem = None
        raw_beszel_link_base = values.get("BESZEL_LINK_BASE")
        if not isinstance(raw_beszel_link_base, str) or not raw_beszel_link_base:
            beszel_link_problem = (
                "BESZEL_LINK_BASE is not set; Beszel alerts will carry no link"
            )
        else:
            try:
                beszel_link_base = validated_link_base(raw_beszel_link_base)
            except ConfigurationError:
                beszel_link_problem = (
                    "BESZEL_LINK_BASE must be an HTTP(S) origin; "
                    "Beszel alerts will carry no link"
                )

        # Deliberately no shape rule on either credential. Both are issued by
        # pushover.net and this platform cannot vouch for their form; the same
        # argument filter_plugins/vault_credential_schema.py records for the
        # vault rules applies here, and a guessed pattern would refuse a real
        # credential with the fix locked inside an encrypted file.
        ceilings = []
        for name in (
            "ALERT_DAILY_CONTAINER_CEILING",
            "ALERT_DAILY_OOM_CONTAINER_CEILING",
            "ALERT_DAILY_GLOBAL_CEILING",
        ):
            if not CEILING_PATTERN.fullmatch(resolved[name]):
                raise ConfigurationError(f"{name} must be a positive alert count")
            ceilings.append(int(resolved[name]))
        container_ceiling, oom_container_ceiling, global_ceiling = ceilings
        # An OOM allowance below the ordinary one would be the opposite of what
        # the higher threshold is for, and a global backstop below a per-container
        # allowance would make the per-container ceiling unreachable and so
        # unprovable. Both are refused at start-up rather than silently inverted.
        if oom_container_ceiling < container_ceiling:
            raise ConfigurationError(
                "ALERT_DAILY_OOM_CONTAINER_CEILING must not be below "
                "ALERT_DAILY_CONTAINER_CEILING"
            )
        if global_ceiling < oom_container_ceiling:
            raise ConfigurationError(
                "ALERT_DAILY_GLOBAL_CEILING must not be below "
                "ALERT_DAILY_OOM_CONTAINER_CEILING"
            )

        state_path = Path(resolved["ALERT_STATE_PATH"])
        if not state_path.is_absolute() or state_path.name in {"", ".", ".."}:
            raise ConfigurationError("ALERT_STATE_PATH must be an absolute file path")

        return cls(
            resolved["ALERT_RELAY_TOKEN"],
            relay_port,
            api_url,
            resolved["PUSHOVER_TOKEN"],
            resolved["PUSHOVER_USER_KEY"],
            state_path,
            container_ceiling,
            oom_container_ceiling,
            global_ceiling,
            link_base,
            link_problem,
            alerts_token,
            beszel_link_base,
            beszel_link_problem,
        )


def validated_link_base(value):
    """Dozzle's origin as the link base, or ConfigurationError saying why not.

    The host is the tailnet/LAN name roles/dozzle renders from
    platform_public_host, so the link opens only on a device that can reach the
    NAS -- off the tailnet the alert still arrives with a link that does not
    load, which is the honest limit rather than a defect. Refused rather than
    repaired, the way PUSHOVER_API_URL is: no userinfo, no path (this deployment
    sets no DOZZLE_BASE, so Dozzle serves from the root), no query or fragment,
    and a length that keeps the finished url inside Pushover's cap whatever id is
    appended. The message never carries the value, which could hold userinfo.
    """
    link = urllib.parse.urlsplit(value)
    try:
        port_valid = link.port is None or link.port > 0
    except ValueError:
        port_valid = False
    if (
        contains_control(value)
        or link.scheme not in {"http", "https"}
        or not link.hostname
        or not port_valid
        or link.username is not None
        or link.password is not None
        or link.path not in {"", "/"}
        or link.query
        or link.fragment
        or value.endswith("?")
        or value.endswith("#")
        or len(value) > MAX_LINK_BASE_CHARACTERS
    ):
        raise ConfigurationError(
            "ALERT_RELAY_LINK_BASE must be an HTTP(S) origin of at most "
            f"{MAX_LINK_BASE_CHARACTERS} characters"
        )
    return urllib.parse.urlunsplit((link.scheme, link.netloc, "", "", ""))


def contains_control(value):
    return any(ord(character) < 0x20 or ord(character) == 0x7F for character in value)


def require_utf8(value, error):
    try:
        value.encode("utf-8")
    except UnicodeEncodeError:
        raise SchemaError(error) from None


def require_text(payload, key, maximum):
    value = payload[key]
    if not isinstance(value, str) or not value or len(value) > maximum or contains_control(value):
        raise SchemaError(f"invalid {key}")
    require_utf8(value, f"invalid {key}")
    return value


def parse_timestamp(value):
    matched = TIMESTAMP_PATTERN.fullmatch(value)
    if not matched:
        raise ValueError("timestamp syntax differs")
    try:
        parsed = datetime.strptime(matched.group("instant"), TIMESTAMP_FORMAT)
    except ValueError:
        raise ValueError("timestamp calendar differs") from None
    canonical = (
        f"{parsed.year:04d}-{parsed.month:02d}-{parsed.day:02d}T"
        f"{parsed.hour:02d}:{parsed.minute:02d}:{parsed.second:02d}"
        f"{matched.group('fraction') or ''}Z"
    )
    if canonical != value:
        raise ValueError("timestamp is not canonical")
    fraction = (matched.group("fraction") or ".0")[1:].ljust(9, "0")
    whole_seconds = (
        (parsed.toordinal() - 1) * 86_400
        + parsed.hour * 3_600
        + parsed.minute * 60
        + parsed.second
    )
    return whole_seconds * 1_000_000_000 + int(fraction)


def valid_timestamp(value):
    try:
        parse_timestamp(value)
        return True
    except ValueError:
        return False


def utc_now():
    return datetime.now(timezone.utc)


def datetime_nanoseconds(value):
    if value.tzinfo is None or value.utcoffset() != timedelta(0):
        raise StateError("retention clock is not UTC")
    normalized = value.astimezone(timezone.utc)
    whole_seconds = (
        (normalized.toordinal() - 1) * 86_400
        + normalized.hour * 3_600
        + normalized.minute * 60
        + normalized.second
    )
    return whole_seconds * 1_000_000_000 + normalized.microsecond * 1_000


def validate_envelope(payload):
    if not isinstance(payload, dict) or set(payload) != ENVELOPE_KEYS:
        raise SchemaError("envelope keys differ")
    if type(payload["version"]) is not int or payload["version"] != 1:
        raise SchemaError("unsupported version")

    rule = require_text(payload, "rule", 32)
    container_id = require_text(payload, "containerId", 64)
    container = require_text(payload, "container", 256)
    host = require_text(payload, "host", 256)
    event = require_text(payload, "event", 32)
    timestamp = require_text(payload, "timestamp", 40)
    if not CONTAINER_ID_PATTERN.fullmatch(container_id):
        raise SchemaError("invalid containerId")
    if not valid_timestamp(timestamp):
        raise SchemaError("invalid timestamp")

    health_status = payload["healthStatus"]
    exit_code = payload["exitCode"]
    if not isinstance(health_status, str) or not isinstance(exit_code, str):
        raise SchemaError("status fields must be strings")
    if contains_control(health_status) or contains_control(exit_code):
        raise SchemaError("invalid status fields")
    require_utf8(health_status, "invalid status fields")
    require_utf8(exit_code, "invalid status fields")

    if rule == "Unexpected exit":
        if (
            event != "die"
            or health_status != ""
            or not EXIT_CODE_PATTERN.fullmatch(exit_code)
        ):
            raise SchemaError("invalid unexpected-exit relationship")
        numeric_exit = int(exit_code)
        if numeric_exit > 255 or numeric_exit in {0, 130, 143}:
            raise SchemaError("invalid unexpected exit code")
    elif rule in RELATIONSHIPS:
        if (event, health_status, exit_code) != RELATIONSHIPS[rule]:
            raise SchemaError("invalid rule relationship")
    else:
        raise SchemaError("unknown rule")

    return {
        "rule": rule,
        "containerId": container_id,
        "container": container,
        "host": host,
        "event": event,
        "healthStatus": health_status,
        "exitCode": exit_code,
        "timestamp": timestamp,
    }


def html_escape(value, maximum=128, escaped_maximum=MAX_ESCAPED_FIELD_CHARACTERS):
    """Bound a container- or host-supplied string, then make it inert markup.

    Truncation comes first, the way the markdown escaping this replaced did it:
    escaping first and cutting afterwards can split `&amp;` in the middle and
    leave a dangling entity at the boundary.

    The second bound is on the result rather than the input, and it drops whole
    input characters rather than cutting the escaped text, for that same reason.
    It exists because escaping expands: a field of 128 apostrophes renders as 768
    characters, and two such fields put the message past Pushover's 1024-character
    cap -- which is a rejected message and a lost alert, not a truncated one.

    `quote=True` although these only ever land in element text. Pushover parses
    `message` under html=1 as five tags -- <b>, <i>, <u>, <font color> and
    <a href> -- of which this relay emits <b> and <font color>; the narrowness
    is ours, not the API's. Two of those five take attributes, so escaping the quotes costs
    two entities and removes the whole class of mistake a later `<a href="...">`
    would introduce.
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


def human_time(nanoseconds):
    """An instant from parse_timestamp as `14 Sep 02:03 UTC`, read at a glance."""
    moment = datetime(1, 1, 1) + timedelta(microseconds=nanoseconds // 1000)
    return f"{moment.day} {moment:%b %H:%M} UTC"


def render_notification(event, link_base):
    """Render one event as Pushover form fields.

    Priorities, and why each. OOM is 2: it is the acknowledge semantic this
    relay was moved to Pushover for, and a container the kernel killed is the
    one event here that should keep re-alerting until a human says they have
    seen it. `Unexpected exit` and `Unhealthy` are 1, which bypasses the
    recipient's quiet hours without an acknowledgement loop -- a service that
    has gone unhealthy overnight is worth waking up a phone for, and 0 would let
    quiet hours hold it until morning. `Recovery` is -1, a badge with no sound:
    it is a record that closes an earlier alert, not something to wake up for.

    The -1 replaces a second topic. Recovery used to be routed to
    nas-containers purely so it could be muted separately from nas-critical;
    Pushover expresses "do not make a noise about this" on the message itself,
    so the second topic has no remaining job and the relay no longer has one.

    Only `message` is parsed as HTML under `html=1`. `title` is plain text on
    Pushover's side, so the container name goes into it raw and deliberately --
    escaping it would show `&amp;` to a human reading a notification title.

    `url` opens the container's page in Dozzle (see CONTAINER_ROUTE for the
    route and why the id fits it), and is left off with its `url_title` when
    the relay has no valid link base (see Config); and `timestamp` is when Docker reported the
    event rather than when Pushover received it, so a delayed delivery still
    reads at the right time. The containerId is validated hex and the base is
    validated in Config, so neither needs quoting and the url cannot exceed
    Pushover's cap. A timestamp before 1970 -- the envelope admits one, Docker
    never sends one -- is left off rather than sent negative for Pushover to
    refuse.
    """
    rule = event["rule"]
    host = html_escape(event["host"])
    container = html_escape(event["container"])
    name = event["container"][:MAX_TITLE_CONTAINER_CHARACTERS]
    exit_code = event["exitCode"]
    # The title carries the whole meaning, because a lock screen shows the title
    # and no HTML; the lead line says it again with the state coloured. No OOM
    # line names an exit code: the envelope pins exitCode to "" for that rule
    # (RELATIONSHIPS), so there is none to show. The OOM closing is what
    # emergency_fields sends, and no rule claims a restart: that is each
    # container's own Compose policy, which this relay never sees.
    title, state, closing = {
        "OOM": (
            f"\U0001f4a5 Out of memory · {name}",
            f'was <font color="{COLOR_RED}">killed</font> by the kernel for running out of memory',
            f"<i>Repeats every {EMERGENCY_RETRY_SECONDS} seconds until acknowledged, "
            f"at most {EMERGENCY_MAX_RETRIES} times.</i>",
        ),
        "Unexpected exit": (
            f"\U0001f6d1 {name} exited ({exit_code})",
            f'<font color="{COLOR_RED}">stopped unexpectedly</font>',
            "",
        ),
        "Unhealthy": (
            f"\U0001f7e0 {name} unhealthy",
            f'is <font color="{COLOR_AMBER}">unhealthy</font>',
            "<i>Open it in Dozzle to see why.</i>",
        ),
        "Recovery": (
            f"\U0001f7e2 {name} recovered",
            f'is <font color="{COLOR_GREEN}">healthy</font> again',
            "",
        ),
    }[rule]
    # No closing promises a recovery: state is keyed on host and container id,
    # so a container recreated under the same name -- every image bump -- never
    # closes the entry its predecessor opened, and neither does one the ceiling
    # suppressed or the store evicted. Pointing at Dozzle is true only with a link.
    if link_base is None and rule == "Unhealthy":
        closing = ""
    shown = container
    if link_base is not None:
        # Validated in Config and hex after it, so escaping changes nothing
        # today; it is what keeps a quote from ending the attribute regardless.
        href = html_escape(
            f"{link_base}{CONTAINER_ROUTE}{event['containerId']}",
            MAX_URL_CHARACTERS,
            6 * MAX_URL_CHARACTERS,
        )
        shown = f'<a href="{href}">{container}</a>'
    details = [f"\U0001f5a5️ <b>Host</b> {host}", f"\U0001f4e6 <b>Container</b> {shown}"]
    if rule == "Unexpected exit":
        details.append(
            f'\U0001f522 <b>Exit code</b> <font color="{COLOR_RED}">{html_escape(exit_code)}</font>'
        )
    details.append(f"\U0001f552 <b>When</b> {human_time(parse_timestamp(event['timestamp']))}")
    priority = {
        "OOM": EMERGENCY_PRIORITY,
        "Unexpected exit": 1,
        "Unhealthy": 1,
        "Recovery": -1,
    }[rule]
    fields = {
        "title": title,
        "message": compose_message(f"<b>{container}</b> {state}", details, closing),
        "html": "1",
        "priority": priority,
    }
    if link_base is not None:
        fields["url"] = f"{link_base}{CONTAINER_ROUTE}{event['containerId']}"
        fields["url_title"] = URL_TITLE
    unix_seconds = parse_timestamp(event["timestamp"]) // 1_000_000_000 - UNIX_EPOCH_SECONDS
    if unix_seconds >= 0:
        fields["timestamp"] = unix_seconds
    return emergency_fields(fields)


def validate_beszel_envelope(payload):
    """Beszel's alert exactly as its generic webhook sends it, or SchemaError.

    Exactly the two keys, both strings. The title may not carry a control
    character; the message may carry newlines, because Beszel separates its body
    from the link with a blank line, and nothing else.
    """
    if not isinstance(payload, dict) or set(payload) != BESZEL_ENVELOPE_KEYS:
        raise SchemaError("envelope keys differ")
    title = payload["title"]
    message = payload["message"]
    if not isinstance(title, str) or not isinstance(message, str) or not title:
        raise SchemaError("title and message must be strings")
    if contains_control(title) or contains_control(message.replace("\n", "")):
        raise SchemaError("invalid control characters")
    require_utf8(title, "invalid title")
    require_utf8(message, "invalid message")
    return {"title": title, "message": message}


def classify_beszel(alert):
    """What a Beszel alert is: its kind, system, metric, direction and body.

    kind is "status", "threshold", or None for any title this relay does not
    recognise -- "Test Alert", and the S.M.A.R.T., ZFS, systemd and container
    alerts 0.19.0 can also send, which is why the fallback is a path and not a
    corner. problem is True for an alert and False for a recovery.
    """
    title = alert["title"]
    body, separator, trailing = alert["message"].rpartition("\n\n")
    if not separator or "\n" in trailing:
        body, trailing = alert["message"], ""
    result = {
        "kind": None, "system": None, "metric": None, "direction": None,
        "problem": not title.endswith("\u2705"), "body": body, "link": trailing,
    }
    status = BESZEL_STATUS_TITLE.fullmatch(title)
    if status:
        return dict(result, kind="status", system=status.group("system"),
                    problem=status.group("state").startswith("down"))
    threshold = BESZEL_THRESHOLD_TITLE.fullmatch(title)
    if threshold:
        rest = threshold.group("rest")
        for metric in BESZEL_METRICS:
            if rest.endswith(f" {metric}") and len(rest) > len(metric) + 1:
                direction = threshold.group("direction")
                return dict(
                    result, kind="threshold", system=rest[: -len(metric) - 1],
                    metric=metric, direction=direction,
                    problem=(direction == "above") != (metric == BESZEL_INVERTED_METRIC),
                )
    return result


def beszel_link(link, link_base):
    """The link Beszel sent, only if it is this relay's own Beszel system page."""
    if link_base is None:
        return None
    route = f"{link_base}{BESZEL_SYSTEM_ROUTE}"
    if not link.startswith(route) or not BESZEL_SYSTEM_ID_PATTERN.fullmatch(link[len(route):]):
        return None
    return link


def render_beszel(alert, link_base, now):
    """Render one Beszel alert as Pushover form fields.

    An alert is 1 and its recovery -1, the split Beszel cannot make itself: a
    host crossing a threshold overnight is worth waking a phone for, and the
    notice that it came back is a record rather than a reason to. An
    unrecognised title goes out as Beszel wrote it at 1, unless it ends in the
    check mark Beszel puts on good news, which goes at -1.

    The title is plain text and the message HTML, as in render_notification.
    The When line is this relay's clock, because Beszel sends no time. The link
    is the one Beszel appended, used only as the button and only when
    beszel_link accepts it.
    """
    parsed = classify_beszel(alert)
    fields = {"html": "1", "priority": 1 if parsed["problem"] else -1}
    link = beszel_link(parsed["link"], link_base)
    if link is not None:
        fields["url"] = link
        fields["url_title"] = BESZEL_URL_TITLE
    if parsed["kind"] is None:
        text = parsed["body"].strip() or alert["title"]
        escaped = html_escape(text, MAX_MESSAGE_CHARACTERS, MAX_MESSAGE_CHARACTERS)
        return dict(
            fields,
            title=alert["title"][:MAX_TITLE_CHARACTERS],
            message=fit_message(escaped.split("\n")),
        )

    name = parsed["system"][:MAX_TITLE_CONTAINER_CHARACTERS]
    shown = html_escape(parsed["system"])
    colour = COLOR_RED if parsed["problem"] else COLOR_GREEN
    details = [f"\U0001f5a5\ufe0f <b>Host</b> {shown}"]
    if parsed["kind"] == "status":
        if parsed["problem"]:
            title = f"\U0001f534 {name} unreachable"
            lead = f'<b>{shown}</b> is <font color="{colour}">unreachable</font>'
        else:
            title = f"\U0001f7e2 {name} reachable again"
            lead = f'<b>{shown}</b> is <font color="{colour}">reachable</font> again'
    else:
        metric = parsed["metric"]
        direction = parsed["direction"]
        if parsed["problem"]:
            title = f"\U0001f534 {name} {metric} {direction} threshold"
            state = direction
        else:
            title = f"\U0001f7e2 {name} {metric} back {direction} threshold"
            state = f"back {direction}"
        lead = f'<b>{shown}</b> {metric} is <font color="{colour}">{state}</font> its threshold'
        average = BESZEL_AVERAGE_BODY.fullmatch(parsed["body"])
        if average:
            emoji = "\U0001f321\ufe0f" if metric == "temperature" else "\U0001f4c8"
            minutes = average.group("minutes")
            unit = "minute" if minutes == "1" else "minutes"
            reading = html_escape(average.group("value") + average.group("unit"))
            descriptor = html_escape(average.group("descriptor"))
            details.append(
                f"{emoji} <b>Average</b> {reading} over {minutes} {unit} \u00b7 {descriptor}"
            )
    details.append(f"\U0001f552 <b>When</b> {human_time(datetime_nanoseconds(now))}")
    return dict(
        fields,
        title=title[:MAX_TITLE_CHARACTERS],
        message=compose_message(lead, details),
    )


def render_ceiling_notice(event, scope, ceiling, day, oom_allowance=None):
    """Render the one message a tripped ceiling is allowed to send.

    Silent suppression is how somebody stops noticing that their alerting died,
    so the ceiling says out loud what it has stopped sending and when it will
    start again. Priority 1 for the same reason the alerts it is replacing carry
    it: this message means the platform has gone quiet, which is worse news than
    any single alert it suppressed. Never 2 -- there is nothing to acknowledge.

    It is rendered from the event that tripped the ceiling, so the `host` is the
    one that reported it rather than a name this process would have to invent.

    `oom_allowance` is what keeps the message honest in the one case where
    "suppressed" would overstate it. A container that has spent its ordinary
    allowance still publishes out-of-memory kills up to the higher OOM one, so a
    notice that said nothing about that would be claiming a silence this relay
    is not keeping. It is None for the global scope, where nothing gets through.
    """
    host = html_escape(event["host"])
    paused = f'<font color="{COLOR_AMBER}">paused</font>'
    details = [f"\U0001f5a5️ <b>Host</b> {host}"]
    if scope == "global":
        # Every alert, not every container alert: Beszel's host alerts count
        # against the same global ceiling and stop with it.
        title = "\U0001f507 Alerts paused"
        lead = f"<b>Every alert</b> is {paused}"
    else:
        container = html_escape(event["container"])
        title = f"\U0001f507 {event['container'][:MAX_TITLE_CONTAINER_CHARACTERS]} alerts paused"
        lead = f"<b>Alerts for {container}</b> are {paused}"
        details.append(f"\U0001f4e6 <b>Container</b> {container}")
    details.append(f"\u2753 <b>Reason</b> {ceiling} alerts already sent on {day} (UTC)")
    if oom_allowance is None:
        closing = "<i>Nothing more gets through until the next UTC day.</i>"
    else:
        closing = (
            f"<i>Out-of-memory kills still get through, up to {oom_allowance} a day; "
            "everything else resumes at the next UTC day.</i>"
        )
    return {
        "title": title,
        "message": compose_message(lead, details, closing),
        "html": "1",
        "priority": 1,
    }


def emergency_fields(fields):
    """Attach retry/expire to a priority 2 message, which Pushover requires."""
    if fields["priority"] != EMERGENCY_PRIORITY:
        return fields
    return dict(
        fields,
        retry=EMERGENCY_RETRY_SECONDS,
        expire=EMERGENCY_EXPIRE_SECONDS,
    )


def open_directory_no_symlinks(path):
    absolute = Path(path)
    if not absolute.is_absolute():
        raise StateError("state directory is not absolute")
    flags = os.O_RDONLY | os.O_DIRECTORY
    no_follow = getattr(os, "O_NOFOLLOW", 0)
    try:
        directory_fd = os.open(absolute, flags | no_follow)
        details = os.fstat(directory_fd)
        if (
            not stat.S_ISDIR(details.st_mode)
            or details.st_uid != os.geteuid()
            or stat.S_IMODE(details.st_mode) != 0o700
        ):
            raise StateError("unsafe state directory")
        return directory_fd
    except (OSError, StateError) as error:
        if "directory_fd" in locals():
            os.close(directory_fd)
        if isinstance(error, StateError):
            raise
        raise StateError("state directory unavailable") from None


def check_private_regular_file(details):
    if (
        not stat.S_ISREG(details.st_mode)
        or details.st_uid != os.geteuid()
        or stat.S_IMODE(details.st_mode) != 0o600
    ):
        raise StateError("unsafe state file")


def validate_state_identity(identity):
    if not isinstance(identity, str) or identity.count("\0") != 1:
        raise StateError("invalid state identity")
    host, container_id = identity.split("\0")
    try:
        host.encode("utf-8")
        container_id.encode("utf-8")
    except UnicodeEncodeError:
        raise StateError("invalid state identity") from None
    if (
        not host
        or len(host) > 256
        or contains_control(host)
        or not CONTAINER_ID_PATTERN.fullmatch(container_id)
    ):
        raise StateError("invalid state identity")


def utc_day(now):
    """The calendar day the ceiling counts against, as an explicit UTC date.

    A calendar day rather than a rolling window, and that is the whole of the
    clock-change answer. A rolling window stores an instant and resets on
    `now - start >= one day`, which a backwards clock jump makes negative and
    which then never resets: the relay would be wedged into suppression until
    somebody noticed the silence. A day *key* has no arithmetic to go negative
    -- a clock that moves in either direction simply lands on a different key,
    and a key that is not today's resets the budget.

    Derived from the fields explicitly rather than from date.today(), which
    reads the process's local timezone; every other clock in this file is UTC
    and datetime_nanoseconds raises if it is handed anything else.
    """
    if now.tzinfo is None or now.utcoffset() != timedelta(0):
        raise StateError("budget clock is not UTC")
    return f"{now.year:04d}-{now.month:02d}-{now.day:02d}"


def empty_budget(day):
    return {"day": day, "count": 0, "notified": False, "containers": {}}


def budget_document(budget):
    ordered = [budget["containers"][identity] for identity in sorted(budget["containers"])]
    return {
        "day": budget["day"],
        "count": budget["count"],
        "notified": budget["notified"],
        "containers": ordered,
    }


def state_bytes(entries, budget):
    ordered = [entries[identity] for identity in sorted(entries)]
    document = json.dumps(
        {
            "version": STATE_VERSION,
            "entries": ordered,
            "budget": budget_document(budget),
        },
        ensure_ascii=True,
        separators=(",", ":"),
    ).encode("utf-8") + b"\n"
    if len(document) > MAX_STATE_BYTES:
        raise StateError("state document is oversized")
    return document


def parse_budget_document(raw):
    if not isinstance(raw, dict) or set(raw) != {
        "day",
        "count",
        "notified",
        "containers",
    }:
        raise StateError("state budget schema differs")
    if not isinstance(raw["day"], str) or not DAY_PATTERN.fullmatch(raw["day"]):
        raise StateError("invalid state budget day")
    if type(raw["count"]) is not int or raw["count"] < 0:
        raise StateError("invalid state budget count")
    if type(raw["notified"]) is not bool:
        raise StateError("invalid state budget notice")
    if not isinstance(raw["containers"], list):
        raise StateError("state budget schema differs")
    containers = {}
    identities = []
    for entry in raw["containers"]:
        if not isinstance(entry, dict) or set(entry) != {
            "identity",
            "count",
            "notified",
        }:
            raise StateError("state budget entry schema differs")
        validate_state_identity(entry["identity"])
        if type(entry["count"]) is not int or entry["count"] < 0:
            raise StateError("invalid state budget count")
        if type(entry["notified"]) is not bool:
            raise StateError("invalid state budget notice")
        identities.append(entry["identity"])
        containers[entry["identity"]] = dict(entry)
    if identities != sorted(set(identities)):
        raise StateError("state budget entries are not canonical")
    if len(containers) > MAX_BUDGET_ENTRIES:
        raise StateError("state budget has too many entries")
    return {
        "day": raw["day"],
        "count": raw["count"],
        "notified": raw["notified"],
        "containers": containers,
    }


def parse_state_document(raw):
    try:
        document = json.loads(raw.decode("utf-8"), object_pairs_hook=unique_object)
    except (UnicodeDecodeError, json.JSONDecodeError, SchemaError):
        raise StateError("state file is corrupt") from None
    if not isinstance(document, dict) or type(document.get("version")) is not int:
        raise StateError("state schema differs")

    # Both older schemas migrate rather than being refused, because the file
    # they describe is on the NAS right now and a relay that refused it would
    # report nothing at all. A migrated document carries no budget, which
    # process_event then rolls to today's -- so the first day after an upgrade
    # starts with a full allowance rather than inheriting one it cannot read.
    if document["version"] in LEGACY_STATE_VERSIONS:
        return parse_legacy_state_document(document), None, True

    if (
        document["version"] != STATE_VERSION
        or set(document) != {"version", "entries", "budget"}
        or not isinstance(document["entries"], list)
    ):
        raise StateError("state schema differs")
    budget = parse_budget_document(document["budget"])
    entries = {}
    identities = []
    for entry in document["entries"]:
        if not isinstance(entry, dict) or set(entry) != {
            "identity",
            "state",
            "timestamp",
        }:
            raise StateError("state entry schema differs")
        identity = entry["identity"]
        validate_state_identity(identity)
        if not isinstance(entry["state"], str) or entry["state"] not in {
            "healthy",
            "unhealthy",
        }:
            raise StateError("invalid state health")
        if not isinstance(entry["timestamp"], str) or not valid_timestamp(
            entry["timestamp"]
        ):
            raise StateError("invalid state timestamp")
        identities.append(identity)
        entries[identity] = dict(entry)
    if identities != sorted(set(identities)):
        raise StateError("state entries are not canonical")
    if len(entries) > MAX_STATE_ENTRIES:
        raise StateError("state has too many entries")
    return entries, budget, False


def parse_legacy_state_document(document):
    if document["version"] == 1:
        if set(document) != {"version", "unhealthy"} or not isinstance(
            document["unhealthy"], list
        ):
            raise StateError("state schema differs")
        identities = document["unhealthy"]
        if not all(isinstance(identity, str) for identity in identities):
            raise StateError("invalid state identity")
        if identities != sorted(set(identities)):
            raise StateError("state entries are not canonical")
        entries = {}
        for identity in identities:
            validate_state_identity(identity)
            entries[identity] = {
                "identity": identity,
                "state": "unhealthy",
                "timestamp": MINIMUM_TIMESTAMP,
            }
        return entries

    if set(document) != {"version", "entries"} or not isinstance(
        document["entries"], list
    ):
        raise StateError("state schema differs")
    entries = {}
    identities = []
    for entry in document["entries"]:
        if not isinstance(entry, dict) or set(entry) != {
            "identity",
            "state",
            "timestamp",
        }:
            raise StateError("state entry schema differs")
        validate_state_identity(entry["identity"])
        if not isinstance(entry["state"], str) or entry["state"] not in {
            "healthy",
            "unhealthy",
        }:
            raise StateError("invalid state health")
        if not isinstance(entry["timestamp"], str) or not valid_timestamp(
            entry["timestamp"]
        ):
            raise StateError("invalid state timestamp")
        identities.append(entry["identity"])
        entries[entry["identity"]] = dict(entry)
    if identities != sorted(set(identities)):
        raise StateError("state entries are not canonical")
    if len(entries) > MAX_STATE_ENTRIES:
        raise StateError("state has too many entries")
    return entries


def bounded_state(entries, budget, now):
    """Bound the whole document, shedding counters before health entries.

    The order matters and is the reason the budget is not stored as more
    `entries`. A health entry may only be evicted once it is healthy, so a
    document full of unhealthy entries has nothing left to shed and raises --
    which stops the relay reporting anything at all. A counter may always be
    evicted, because the global count beneath the per-container ones is what
    actually guarantees the quota; losing a container's counter costs at most
    one container's allowance being spent twice, and the global backstop still
    holds. So the bytes are reclaimed from the droppable structure first.

    THIS DEFERS THAT RAISE RATHER THAN PREVENTING IT. Shedding counters buys
    back the counters' own bytes and nothing else, so once they are gone the
    ceiling on all-unhealthy entries is exactly what it is with no counters at
    all: 128 at a short ASCII host, where MAX_STATE_ENTRIES binds first, and 39
    at a 256-character non-ASCII one. That raise predates the counters and is
    unchanged by them; what the shed prevents is the counters making it arrive
    sooner. MAX_BUDGET_ENTRIES carries the measurements.

    Counters are evicted lowest-count first, never oldest-first: a container
    already at its ceiling is the one whose counter is doing work, and dropping
    it would hand that container a fresh allowance and a second notice.
    """
    proposed = {identity: dict(entry) for identity, entry in entries.items()}
    cutoff = datetime_nanoseconds(now - HEALTHY_RETENTION)
    for identity, entry in list(proposed.items()):
        if entry["state"] == "healthy" and parse_timestamp(entry["timestamp"]) < cutoff:
            del proposed[identity]
    bounded_budget = dict(budget)
    bounded_budget["containers"] = {
        identity: dict(entry) for identity, entry in budget["containers"].items()
    }

    while True:
        try:
            serialized = state_bytes(proposed, bounded_budget)
        except StateError:
            serialized = None
        if (
            len(proposed) <= MAX_STATE_ENTRIES
            and len(bounded_budget["containers"]) <= MAX_BUDGET_ENTRIES
            and serialized is not None
        ):
            return proposed, bounded_budget, serialized
        counters = sorted(
            (entry["count"], identity)
            for identity, entry in bounded_budget["containers"].items()
        )
        if counters:
            del bounded_budget["containers"][counters[0][1]]
            continue
        healthy = sorted(
            (
                (parse_timestamp(entry["timestamp"]), identity)
                for identity, entry in proposed.items()
                if entry["state"] == "healthy"
            )
        )
        if not healthy:
            raise StateError("unhealthy state exceeds bounds")
        del proposed[healthy[0][1]]


def read_state_at(directory_fd, state_name):
    flags = os.O_RDONLY | os.O_NONBLOCK | getattr(os, "O_NOFOLLOW", 0)
    try:
        file_fd = os.open(state_name, flags, dir_fd=directory_fd)
    except FileNotFoundError:
        return {}, None, False
    except OSError:
        raise StateError("state file unavailable") from None
    try:
        details = os.fstat(file_fd)
        check_private_regular_file(details)
        if details.st_size > MAX_STATE_BYTES:
            raise StateError("state file is oversized")
        raw = b""
        while len(raw) <= MAX_STATE_BYTES:
            chunk = os.read(file_fd, 8192)
            if not chunk:
                break
            raw += chunk
        if len(raw) > MAX_STATE_BYTES:
            raise StateError("state file is oversized")
    finally:
        os.close(file_fd)
    return parse_state_document(raw)


def validate_operational_state_at(directory_fd, state_name):
    now = utc_now()
    entries, budget, _ = read_state_at(directory_fd, state_name)
    bounded_state(entries, rolled_budget(budget, now), now)


def state_is_ready(state_path):
    state_path = Path(state_path)
    directory_fd = open_directory_no_symlinks(state_path.parent)
    lock_fd = None
    try:
        flags = os.O_RDONLY | os.O_NONBLOCK | getattr(os, "O_NOFOLLOW", 0)
        try:
            lock_fd = os.open(
                f".{state_path.name}.lock", flags, dir_fd=directory_fd
            )
        except FileNotFoundError:
            validate_operational_state_at(directory_fd, state_path.name)
            return True
        except OSError:
            raise StateError("state lock unavailable") from None
        check_private_regular_file(os.fstat(lock_fd))
        try:
            fcntl.flock(lock_fd, fcntl.LOCK_SH | fcntl.LOCK_NB)
        except BlockingIOError:
            return True
        except OSError:
            raise StateError("state lock unavailable") from None
        validate_operational_state_at(directory_fd, state_path.name)
        return True
    finally:
        if lock_fd is not None:
            with contextlib.suppress(OSError):
                fcntl.flock(lock_fd, fcntl.LOCK_UN)
            os.close(lock_fd)
        os.close(directory_fd)


class LockedState:
    def __init__(self, state_path):
        self.state_path = Path(state_path)
        self.directory_fd = None
        self.lock_fd = None

    def __enter__(self):
        self.directory_fd = open_directory_no_symlinks(self.state_path.parent)
        flags = (
            os.O_RDWR
            | os.O_CREAT
            | os.O_NONBLOCK
            | getattr(os, "O_NOFOLLOW", 0)
        )
        try:
            self.lock_fd = os.open(
                f".{self.state_path.name}.lock",
                flags,
                0o600,
                dir_fd=self.directory_fd,
            )
            check_private_regular_file(os.fstat(self.lock_fd))
            fcntl.flock(self.lock_fd, fcntl.LOCK_EX)
            return self
        except (OSError, StateError):
            self.__exit__(None, None, None)
            raise StateError("state lock unavailable") from None

    def __exit__(self, _exception_type, _exception, _traceback):
        if self.lock_fd is not None:
            with contextlib.suppress(OSError):
                fcntl.flock(self.lock_fd, fcntl.LOCK_UN)
            os.close(self.lock_fd)
            self.lock_fd = None
        if self.directory_fd is not None:
            os.close(self.directory_fd)
            self.directory_fd = None

    def read(self):
        return read_state_at(self.directory_fd, self.state_path.name)

    def replace(self, entries, budget, document=None):
        document = document if document is not None else state_bytes(entries, budget)
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
        temporary_fd = None
        temporary_name = None
        try:
            for _attempt in range(10):
                candidate = f".{self.state_path.name}.{secrets.token_hex(16)}.tmp"
                try:
                    temporary_fd = os.open(
                        candidate, flags, 0o600, dir_fd=self.directory_fd
                    )
                    temporary_name = candidate
                    break
                except FileExistsError:
                    continue
            if temporary_fd is None:
                raise StateError("state temporary file unavailable")
            os.fchmod(temporary_fd, 0o600)
            written = 0
            while written < len(document):
                written += os.write(temporary_fd, document[written:])
            os.fsync(temporary_fd)
            os.close(temporary_fd)
            temporary_fd = None
            os.replace(
                temporary_name,
                self.state_path.name,
                src_dir_fd=self.directory_fd,
                dst_dir_fd=self.directory_fd,
            )
            os.fsync(self.directory_fd)
        except OSError:
            if temporary_fd is not None:
                os.close(temporary_fd)
            if temporary_name is not None:
                with contextlib.suppress(FileNotFoundError):
                    os.unlink(temporary_name, dir_fd=self.directory_fd)
            raise StateError("state replacement failed") from None


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise SchemaError("duplicate JSON key")
        result[key] = value
    return result


def log_safe(value, config, maximum=MAX_DIAGNOSTIC_CHARACTERS):
    """One sanitiser, and every field that reaches the log goes through it.

    REDACT BEFORE TRUNCATING. Truncating first can cut a credential in half and
    leave that half in the log, and half a credential is still a leak. The
    ordering is the whole reason this is one function rather than two steps at
    the call site.

    Control characters go because a log line is a line. A newline inside an
    upstream response -- or inside a container name, which is text this platform
    does not author -- forges a second entry in a log that Dozzle renders, which
    is exactly the tool somebody is looking at when they read it.

    Applied to the alert's own title as well as to the upstream's text, although
    the envelope already rejects control characters in `container`. A sanitiser
    with an exception is a sanitiser with a path that was missed.
    """
    text = str(value)
    for secret in (config.pushover_token, config.pushover_user_key, config.pushover_alerts_token):
        if secret:
            text = text.replace(secret, "[redacted]")
    text = "".join(
        character if not contains_control(character) else "?" for character in text
    )
    return text[:maximum]


def report_upstream_failure(config, notification, reason, detail):
    """Say out loud that an alert was not delivered.

    Without this the whole path is silent: there is no logging anywhere in this
    module, /healthz reports only on the state store, and Dozzle is told 502 and
    does not retry. A rejected alert simply vanished, and against Pushover a
    rejection is reachable in a way it never was against a local server -- the 250
    and 1024 caps, the priority-2 parameters, and credentials that were revoked
    or mistyped.

    stderr because that is `docker logs`, and therefore Dozzle, which is the
    tool whose job is showing somebody this.

    ONE write, assembled with its own newline. print() issues two -- the text,
    then the terminator -- and this server is threaded, so two concurrent
    failures can interleave into a merged line. A log that garbles under
    concurrency is worse than no log, because it gets read as evidence of
    something it did not say.

    No credential can reach here: both travel in the request body, which is
    never logged, and log_safe redacts them from the far end's text anyway
    in case it echoes one back.
    """
    line = (
        f"alert-relay: {reason}: "
        f"alert={log_safe(notification.get('title', 'unknown'), config)} "
        f"detail={log_safe(detail, config)}\n"
    )
    sys.stderr.write(line)
    sys.stderr.flush()


def report_refused_envelope(config, route, error):
    """Say out loud that an envelope was refused, which a 400 never did.

    #699 is what that silence costs. Dozzle v11.1.0 began rendering event
    timestamps in local time, the relay's TIMESTAMP_PATTERN accepts only the
    `Z` spelling, and every health alert was refused here -- for three days of
    CI, across six runs and three diagnostic changes, with nothing on either
    side naming a reason. Dozzle said only "webhook returned status code 400";
    this end said nothing at all, because none of the 400 paths wrote a line.
    report_upstream_failure covers the far end rejecting US; this covers us
    rejecting the near end, and the two together close the route.

    The exception's own text is the diagnosis and it is safe to print: every
    SchemaError message here names a FIELD and never its value
    ("timestamp syntax differs", "invalid container"), which is the same
    discipline the managed-user schema keeps for the same reason. log_safe runs
    over it regardless, because a message is a poor place to discover an
    exception to that rule.

    ONE assembled write, for report_upstream_failure's reason: this server is
    threaded and print() issues two writes, so concurrent refusals can
    interleave into a line that reads as something neither of them said.
    """
    line = (
        f"alert-relay: refused an envelope on {route}: "
        f"{log_safe(f'{type(error).__name__}: {error}', config)}\n"
    )
    sys.stderr.write(line)
    sys.stderr.flush()


def read_upstream_detail(error):
    """The far end's own explanation, bounded, and never at the cost of the failure.

    Pushover answers a rejection with an `errors` array naming the bad
    parameter, which is what separates "the user key is wrong" from "the message
    is too long" from "priority 2 without retry" -- three failures a status code
    alone leaves an operator guessing between. A read that fails must not mask
    the rejection it was trying to describe, so it degrades to saying so.
    """
    try:
        return error.read(MAX_DIAGNOSTIC_BYTES).decode("utf-8", errors="replace")
    except Exception:  # noqa: BLE001 - a failed read must not replace the failure
        return "the error response could not be read"


def publish(config, notification, token):
    """POST one message to Pushover, as the application `token` names.

    Container events go out on the Containers application and Beszel's host
    alerts on the Alerts one, so the caller chooses; the user key is shared.

    Pushover authenticates by form field rather than by header: the application
    token and the user key are `token` and `user` in the body, and there is no
    Authorization header at all. Both are therefore in the request body rather
    than in a header, which is worth knowing wherever a request is captured --
    a recorded body is a credential.
    """
    body = urllib.parse.urlencode(
        {
            "token": token,
            "user": config.pushover_user_key,
            **notification,
        }
    ).encode("ascii")
    request = urllib.request.Request(
        config.pushover_api_url,
        data=body,
        headers={"Content-Type": "application/x-www-form-urlencoded"},
        method="POST",
    )
    # The two failures below were one failure until #558's review: both raised
    # `UpstreamError("upstream unavailable")`, byte for byte, so a permanent
    # rejection and a transient outage were the same object to every caller and
    # the same silence to every operator. They now differ in the exception and
    # in the log, because the response to them differs -- an outage heals and a
    # rejection never does.
    #
    # HTTPError first, and that ordering is load-bearing: it subclasses URLError
    # which subclasses OSError, so the broad branch below would swallow every
    # rejection if it came first.
    try:
        with NO_REDIRECT_OPENER.open(request, timeout=10) as response:
            if not 200 <= response.status < 300:
                # Defensive rather than reached: urllib raises HTTPError for
                # anything at or above 400, and the redirect handler refuses 3xx
                # into an HTTPError too, so nothing known lands here.
                report_upstream_failure(
                    config, notification,
                    f"pushover rejected the alert (HTTP {response.status})",
                    "the response carried no error body",
                )
                raise UpstreamError("upstream rejected the message")
    except urllib.error.HTTPError as error:
        status = error.code
        detail = read_upstream_detail(error)
        error.close()
        report_upstream_failure(
            config, notification,
            f"pushover rejected the alert (HTTP {status})", detail,
        )
        raise UpstreamError("upstream rejected the message") from None
    except (OSError, urllib.error.URLError) as error:
        report_upstream_failure(
            config, notification,
            f"pushover unreachable ({type(error).__name__})",
            "the alert was not delivered and will not be retried",
        )
        raise UpstreamError("upstream unavailable") from None


def rolled_budget(budget, now):
    """Today's budget, resetting whenever the stored day is not today's.

    Not "reset when a day has elapsed": the comparison is equality against a
    date key, so a clock that moved backwards resets exactly as a clock that
    moved forwards does. There is no window whose start can end up in the
    future and no difference that can go negative, which is the one way a
    ceiling wedges itself permanently shut.

    A missing budget -- a state file written by an older schema, or none at all
    -- is today's empty one, so an upgrade starts with a full allowance rather
    than inheriting a count it cannot read.
    """
    day = utc_day(now)
    if budget is None or budget["day"] != day:
        return empty_budget(day)
    return {
        "day": day,
        "count": budget["count"],
        "notified": budget["notified"],
        "containers": {
            identity: dict(entry) for identity, entry in budget["containers"].items()
        },
    }


class BudgetFloor:
    """What this process has already authorised today, held outside the store.

    THE DEFECT THIS EXISTS FOR. The ceiling lived entirely in the state file,
    so a state write that failed took the increment with it: the next event
    re-read an unchanged document, saw the same count, and published again.
    Measured at 10/25/200 with the write always failing, 500 events produced
    500 alerts and no notice, against 10 alerts and one notice with the write
    working. The notice latch was worse, because nothing backed it at all --
    ten over-ceiling events produced ten notices instead of one.

    That is not a theoretical failure. `/state` filling or remounting read-only
    is the same class of event this relay exists to report, so the quota bomb
    the ceiling was added to prevent was reachable through the ceiling's own
    storage, and reachable silently: the relay answers Dozzle 500 and keeps on
    publishing.

    FAILING CLOSED WOULD BE WORSE. Refusing to publish when the write fails
    silences alerting on a host whose disk has just filled, which is the one
    moment somebody needs to hear from it. So the bound degrades instead: with
    the store working it is durable across restarts, and with the store failing
    it holds for the lifetime of this process.

    WHAT "THE LIFETIME OF THIS PROCESS" IS WORTH, stated because the phrase
    flatters itself. A relay whose store is unwritable is in exactly the
    situation where it may also be restarting, and each restart starts from the
    last count that LANDED -- so the real bound with the store broken is
    `ceiling x restarts`, not `ceiling`. Measured with the write always failing
    and nothing ever persisting: five restarts of a hundred events each
    delivered 50 alerts and 5 notices, where one process would have delivered
    10 and 1. That is a bounded degradation of a device that previously had no
    bound at all in this state -- the same run before BudgetFloor published
    every one of the 500 -- and it is the honest description rather than a
    reason to reach for something durable-but-unwritable.

    A store that is UNREADABLE rather than unwritable does not leak at all:
    read_state_at raises at the top of process_event, before anything is
    rendered or published, so the request ends in a 500 with nothing sent.

    THIS LOCK IS NOT THE CEILING'S INTERLOCK. `self._lock` covers exactly two
    things -- reading the dict in raise_floor and assigning it in record -- and
    the ceiling's decision is a check-then-act spanning both, plus a publish in
    between. Three separate acquisitions guard nothing across the whole
    sequence. What makes it atomic is the exclusive flock process_event holds
    for all of it; see the ordering comment there, which also records what that
    costs and why it is still right.

    OWNED BY THE SERVER, not by the module. A module-level cache would survive
    a create_server in the same interpreter, which is how the restart case in
    tests/dozzle_alert_relay_test.py stands in for a container recreation -- so
    it would have made that case stop proving the state-backed half it exists
    to prove. One server is one process here.
    """

    def __init__(self):
        self._lock = threading.Lock()
        self._budget = None

    def raise_floor(self, budget):
        """`budget`, never lower than what this process has already authorised.

        Elementwise: the larger count and the latched notice win, on the global
        scope and on each container. A stored document that lost an increment
        is corrected; one that is ahead of this process is left alone.
        """
        with self._lock:
            floor = self._budget
        if floor is None or floor["day"] != budget["day"]:
            return budget
        containers = {
            identity: dict(entry) for identity, entry in budget["containers"].items()
        }
        for identity, entry in floor["containers"].items():
            stored = containers.get(identity)
            containers[identity] = {
                "identity": identity,
                "count": max(entry["count"], stored["count"]) if stored else entry["count"],
                "notified": entry["notified"] or bool(stored and stored["notified"]),
            }
        return {
            "day": budget["day"],
            "count": max(budget["count"], floor["count"]),
            "notified": budget["notified"] or floor["notified"],
            "containers": containers,
        }

    def record(self, budget):
        """Adopt a charged budget as the new floor.

        Called only after the publish it authorised has actually gone out, so a
        refusing upstream still consumes nothing -- the property the
        publish-before-persist order already had, and which this must not cost.
        Both halves now have to hold at once.

        The budget recorded is the one bounded_state returned, so the floor
        inherits that bound and cannot grow with container churn. A counter the
        bound shed is one this floor forgets too, which is the same degradation
        the shed already accepts: the global count beneath them is what
        guarantees the quota.
        """
        with self._lock:
            self._budget = {
                "day": budget["day"],
                "count": budget["count"],
                "notified": budget["notified"],
                "containers": {
                    identity: dict(entry)
                    for identity, entry in budget["containers"].items()
                },
            }


def charge_budget(budget, identity, rule, config):
    """Decide what today's remaining allowance lets this alert be.

    Returns ("publish", budget), ("notice", budget, scope, ceiling, oom) or
    ("silent", budget). The budget returned is a new mapping; the caller writes
    it only once the publish it authorised has actually gone out, so an upstream
    that is refusing does not quietly eat the day's allowance.

    Two ceilings, one counter. The global count is the backstop that makes the
    monthly quota a guarantee rather than a hope, and it is checked first so a
    platform that has already gone quiet does not then emit one notice per
    container on top. Beneath it each container has its own allowance, so one
    noisy container cannot drown out a real alert somewhere else.

    OOM is compared against a higher per-container allowance rather than being
    exempt, and the crash loop is why. A container the kernel kills, that
    `restart: unless-stopped` starts again, that the kernel kills again, emits
    an unbounded `oom` stream; a fully exempt rule would relay all of it and
    the quota would be gone. It still counts against the global backstop for
    the same reason. What the higher allowance buys is that a container whose
    ordinary alerts have been suppressed can still report that it was killed.
    """
    ceiling = (
        config.oom_container_ceiling if rule == "OOM" else config.container_ceiling
    )
    proposed = {
        "day": budget["day"],
        "count": budget["count"],
        "notified": budget["notified"],
        "containers": {
            key: dict(entry) for key, entry in budget["containers"].items()
        },
    }
    if proposed["count"] >= config.global_ceiling:
        if proposed["notified"]:
            return ("silent", proposed)
        proposed["notified"] = True
        # None rather than an allowance: the global backstop stops every rule,
        # out-of-memory kills included.
        return ("notice", proposed, "global", config.global_ceiling, None)

    # No identity is a Beszel host alert. It has no container to charge, and a
    # state identity requires a container id, so it counts against the global
    # ceiling alone -- the bound that makes the monthly quota a guarantee.
    if identity is None:
        proposed["count"] += 1
        return ("publish", proposed)

    entry = proposed["containers"].get(
        identity, {"identity": identity, "count": 0, "notified": False}
    )
    if entry["count"] >= ceiling:
        if entry["notified"]:
            return ("silent", proposed)
        entry = dict(entry, notified=True)
        proposed["containers"][identity] = entry
        # The notice names the OOM allowance only while there is one left to
        # name: past it, "suppressed" is the whole truth for this container.
        remaining_oom = (
            config.oom_container_ceiling
            if entry["count"] < config.oom_container_ceiling
            else None
        )
        return ("notice", proposed, "container", ceiling, remaining_oom)

    proposed["count"] += 1
    proposed["containers"][identity] = dict(entry, count=entry["count"] + 1)
    return ("publish", proposed)


def process_event(config, event, floor):
    """Reconcile one event, publish what the ceiling allows, and persist.

    `floor` is required rather than defaulted, because a default would be a way
    to call this with the safety device switched off -- which is exactly the
    shape of the defect it was added to close.
    """
    identity = f"{event['host']}\0{event['containerId']}"
    now = utc_now()
    with LockedState(config.alert_state_path) as state_file:
        entries, stored_budget, migration_required = state_file.read()
        # The store is read first and then corrected upwards, never trusted
        # downwards: a document whose last increment never landed would
        # otherwise hand this process the same allowance a second time.
        budget = floor.raise_floor(rolled_budget(stored_budget, now))
        proposed = {key: dict(entry) for key, entry in entries.items()}
        publication_required = event["rule"] in {"OOM", "Unexpected exit"}

        if event["rule"] in {"Unhealthy", "Recovery"}:
            incoming_state = (
                "unhealthy" if event["rule"] == "Unhealthy" else "healthy"
            )
            incoming_order = parse_timestamp(event["timestamp"])
            existing = entries.get(identity)
            if existing is not None:
                existing_order = parse_timestamp(existing["timestamp"])
                if incoming_order < existing_order:
                    return
                if incoming_order == existing_order:
                    if existing["state"] == "healthy":
                        return
                    if incoming_state == "unhealthy":
                        publication_required = True
                    else:
                        publication_required = True
                        proposed[identity] = {
                            "identity": identity,
                            "state": "healthy",
                            "timestamp": event["timestamp"],
                        }
                else:
                    publication_required = incoming_state == "unhealthy" or existing[
                        "state"
                    ] == "unhealthy"
                    proposed[identity] = {
                        "identity": identity,
                        "state": incoming_state,
                        "timestamp": event["timestamp"],
                    }
            else:
                publication_required = incoming_state == "unhealthy"
                proposed[identity] = {
                    "identity": identity,
                    "state": incoming_state,
                    "timestamp": event["timestamp"],
                }

        # The ceiling is charged only once the transition logic above has said
        # this event is worth publishing at all, so a suppressed duplicate does
        # not spend the day's allowance on a message nobody was going to get.
        notification = None
        charged = budget
        if publication_required:
            decision = charge_budget(budget, identity, event["rule"], config)
            charged = decision[1]
            if decision[0] == "publish":
                notification = render_notification(
                    event, config.alert_relay_link_base
                )
            elif decision[0] == "notice":
                notification = render_ceiling_notice(
                    event, decision[2], decision[3], charged["day"], decision[4]
                )

        proposed, charged, document = bounded_state(proposed, charged, now)
        replacement_required = (
            migration_required or proposed != entries or charged != stored_budget
        )
        # Publish, then raise the floor, then persist -- and all three of those
        # positions are load-bearing in a different direction.
        #
        # ALL OF IT INSIDE THE FLOCK, WHICH IS THE INTERLOCK. The ceiling is a
        # check-then-act: raise_floor reads, charge_budget decides, record and
        # replace write, and the publish those authorise sits between them.
        # BudgetFloor's own lock covers only its dict and spans none of that, so
        # it is NOT what keeps two concurrent events from each seeing the same
        # remaining allowance -- the exclusive flock LockedState holds across
        # this whole block is. Measured with the window widened to 50ms: with
        # the flock, a ceiling of 10 delivered 10 and never had two publishes in
        # flight; with the flock removed and BudgetFloor left in place, the same
        # ceiling delivered 40 with 40 concurrent publishes. The floor still
        # looked like protection the whole time.
        #
        # SO `publish` IS DELIBERATELY INSIDE THE LOCK, and the cost is real and
        # is not an oversight: it holds a 10-second HTTP timeout, so a hung
        # Pushover serialises every concurrent Dozzle POST behind it. That is
        # accepted here because the timeout bounds it and this relay's event
        # volume is a handful of container transitions, not a stream. Moving the
        # publish out is the obvious throughput fix and it BREACHES THE CEILING
        # SILENTLY -- the measurement above is what that costs. Do not take it.
        #
        # PUBLISH BEFORE EITHER RECORD: an UpstreamError here leaves the
        # increment nowhere, so an upstream that is refusing cannot silently
        # consume the whole daily allowance while delivering nothing.
        #
        # FLOOR BEFORE PERSIST: recording in memory cannot fail, so the bound
        # survives a state write that does. Before this the ceiling lived only
        # in the file, and a failing write meant no bound at all -- 500 events
        # published 500 alerts and no notice. BudgetFloor records the
        # measurement.
        #
        # PERSIST LAST, and its failure still reaches the caller as a 500. The
        # event was delivered, so that status is about the store rather than
        # about the alert; what it must no longer mean is that the ceiling
        # forgot the alert happened.
        if notification is not None:
            publish(config, notification, config.pushover_token)
        floor.record(charged)
        if replacement_required:
            state_file.replace(proposed, charged, document)


def process_beszel(config, alert, floor):
    """Charge one Beszel alert against the global ceiling, publish it, persist.

    The order and the lock are process_event's, for the reasons recorded there:
    everything from raise_floor to replace inside the flock, publish before the
    floor records, the floor before the persist. There is no health state to
    reconcile, so every Beszel alert is a publication the ceiling decides on.
    """
    now = utc_now()
    with LockedState(config.alert_state_path) as state_file:
        entries, stored_budget, migration_required = state_file.read()
        budget = floor.raise_floor(rolled_budget(stored_budget, now))
        decision = charge_budget(budget, None, None, config)
        charged = decision[1]
        notification = None
        if decision[0] == "publish":
            notification = render_beszel(alert, config.beszel_link_base, now)
        elif decision[0] == "notice":
            system = classify_beszel(alert)["system"] or "Beszel"
            notification = render_ceiling_notice(
                {"host": system}, decision[2], decision[3], charged["day"], decision[4]
            )
        proposed, charged, document = bounded_state(entries, charged, now)
        replacement_required = (
            migration_required or proposed != entries or charged != stored_budget
        )
        if notification is not None:
            publish(config, notification, config.pushover_alerts_token)
        floor.record(charged)
        if replacement_required:
            state_file.replace(proposed, charged, document)


class RelayRequestHandler(BaseHTTPRequestHandler):
    server_version = "DozzleAlertRelay/1"

    def do_GET(self):  # noqa: N802 - BaseHTTPRequestHandler API
        if self.path != "/healthz":
            self.send_text(404, "not found\n")
            return
        try:
            state_is_ready(self.server.config.alert_state_path)
        except StateError:
            self.send_text(503, "state unavailable\n")
            return
        self.send_text(200, "ok\n")

    def do_POST(self):  # noqa: N802 - BaseHTTPRequestHandler API
        # /alerts is Dozzle's and /beszel is Beszel's. Both take the same bearer
        # token, the same content type and the same size bound; they differ only
        # in the envelope and in which Pushover application publishes.
        if self.path not in {"/alerts", "/beszel"}:
            self.send_text(404, "not found\n")
            return
        authorization = self.headers.get("Authorization", "")
        expected = f"Bearer {self.server.config.alert_relay_token}"
        try:
            authorized = hmac.compare_digest(
                authorization.encode("ascii"), expected.encode("ascii")
            )
        except UnicodeEncodeError:
            authorized = False
        if not authorized:
            self.send_text(401, "unauthorized\n")
            return
        if self.headers.get("Content-Type", "").split(";", 1)[0].strip().lower() != "application/json":
            self.send_text(400, "invalid request\n")
            return
        try:
            content_length = int(self.headers.get("Content-Length", ""))
        except ValueError:
            self.send_text(400, "invalid request\n")
            return
        if content_length < 1:
            self.send_text(400, "invalid request\n")
            return
        if content_length > MAX_BODY_BYTES:
            self.send_text(413, "request too large\n")
            return
        raw = self.rfile.read(content_length)
        if len(raw) != content_length:
            self.send_text(400, "invalid request\n")
            return
        if self.path == "/beszel":
            self.handle_beszel(raw)
            return
        try:
            payload = json.loads(raw.decode("utf-8"), object_pairs_hook=unique_object)
            event = validate_envelope(payload)
        except (UnicodeDecodeError, json.JSONDecodeError, SchemaError) as caught:
            report_refused_envelope(self.server.config, "/alerts", caught)
            self.send_text(400, "invalid request\n")
            return
        try:
            process_event(self.server.config, event, self.server.budget_floor)
        except StateError:
            self.send_text(500, "state unavailable\n")
            return
        except UpstreamError:
            self.send_text(502, "upstream unavailable\n")
            return
        self.send_empty(204)

    def handle_beszel(self, raw):
        config = self.server.config
        try:
            payload = json.loads(raw.decode("utf-8"), object_pairs_hook=unique_object)
            alert = validate_beszel_envelope(payload)
        except (UnicodeDecodeError, json.JSONDecodeError, SchemaError) as caught:
            report_refused_envelope(config, "/beszel", caught)
            self.send_text(400, "invalid request\n")
            return
        if config.pushover_alerts_token is None:
            # One write per refused alert, like report_upstream_failure, naming
            # the setting and never a value.
            sys.stderr.write(
                "alert-relay: PUSHOVER_ALERTS_TOKEN is not set; a Beszel alert was not delivered\n"
            )
            sys.stderr.flush()
            self.send_text(503, "alerts token unavailable\n")
            return
        try:
            process_beszel(config, alert, self.server.budget_floor)
        except StateError:
            self.send_text(500, "state unavailable\n")
            return
        except UpstreamError:
            self.send_text(502, "upstream unavailable\n")
            return
        self.send_empty(204)

    def send_empty(self, status_code):
        self.send_response(status_code)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def send_text(self, status_code, text):
        body = text.encode("utf-8")
        self.send_response(status_code)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    # Access logging is deliberately off, and this override is what turns it
    # off. It is NOT where a failure gets reported: publish() writes to stderr
    # when an alert is not delivered, which is the line an operator wants, and
    # resurrecting a request log here would bury it under one entry per Dozzle
    # POST -- most of which are the events that were delivered fine.
    def log_message(self, _format, *_args):
        pass


class RelayServer(ThreadingHTTPServer):
    daemon_threads = True


def create_server(address, config):
    server = RelayServer(address, RelayRequestHandler)
    server.config = config
    # One floor per server, so the bound is per process. See BudgetFloor for
    # why it does not live on the module.
    server.budget_floor = BudgetFloor()
    return server


def stop_on_signal(server):
    """Shut `server` down when a stop signal arrives. Runs off the main thread.

    server.shutdown() blocks until the accept loop has stopped, so it can only
    be called from a thread that is not running it. That is the whole reason
    this waits here rather than in a signal handler, where the caller would be
    the accept loop itself and would wait for a loop waiting for it.
    """
    signal.sigwait(STOP_SIGNALS)
    server.shutdown()


def serve_until_stopped(server):
    """Serve until a stop signal arrives, then close the listener and return.

    WHY A STOP IS WAITED FOR RATHER THAN HANDLED. Compose starts this script in
    exec form, so in its container the Python process is the container's init.
    PID 1 is the one process the kernel applies no default signal disposition
    to: a signal nothing installed a handler for is discarded rather than
    terminating it. A relay that handled nothing but SIGINT -- which is all this
    did until #516, as the KeyboardInterrupt out of serve_forever -- therefore
    ignored `docker stop` outright, and Docker SIGKILLed it at the end of the
    ten second grace period for exit 137. Since #493 the `die` rule no longer
    excludes 137 and it matches every container, so every recreation of this
    container paged, through this container, which is the only path the
    platform's alerts have.

    A handler that raises does not fix that, and the measurement is worth
    keeping: socketserver reports any exception raised while it is dispatching a
    request through handle_error and carries on serving, so a stop signal
    landing between accept and the worker thread starting is swallowed and the
    process hangs until the SIGKILL it was meant to avoid. That was observed
    once in eight attempts, on SIGINT, with a client connecting at start-up. The
    same window has always made the KeyboardInterrupt path unreliable.

    So the signals are blocked before any thread exists and one thread waits for
    them with sigwait. Nothing is ever delivered asynchronously, so there is no
    window to land in and no handler re-entering a lock the interrupted code
    already holds; blocking is inherited, so no request thread can take a stop
    signal either. SIGKILL cannot be blocked, which is the point: an
    out-of-memory kill still ends this process at 137 and still pages.

    What this does not cover is the interpreter's own start-up, before main()
    blocks anything: a stop arriving there still meets PID 1 with no
    disposition and is discarded, and the container is SIGKILLed for 137.
    `init: true` would close it, and was not taken: this platform's rule for that
    key is that an init shim is for a PID 1 that never reaps what it forks or
    cannot act on a stop signal at all, and this relay forks nothing and takes
    its stop signals itself.
    The window is interpreter start-up wide and a recreation stops a container
    that has been running for hours, so nothing this platform does can land in
    it; a stop aimed at a relay that is itself restarting could.

    The waiter is a daemon, so a caller that stops the server itself -- which is
    how the entry point is exercised in tests -- still returns from here.
    """
    waiter = threading.Thread(
        target=stop_on_signal, args=(server,), name="alert-relay-stop", daemon=True
    )
    waiter.start()
    try:
        server.serve_forever()
    finally:
        server.server_close()


def main():
    # Blocked before the configuration is read and before any thread exists, so
    # the only window in which a stop signal meets a default disposition is the
    # interpreter's own start-up. serve_until_stopped records what that leaves
    # open and why it was left.
    signal.pthread_sigmask(signal.SIG_BLOCK, STOP_SIGNALS)
    try:
        config = Config.from_mapping(os.environ)
    except ConfigurationError:
        raise SystemExit("alert relay configuration is invalid") from None
    if config.alert_relay_link_problem is not None:
        # One write, like report_upstream_failure, and it names the setting
        # rather than its value.
        sys.stderr.write(f"alert-relay: {config.alert_relay_link_problem}\n")
        sys.stderr.flush()
    if config.beszel_link_problem is not None:
        sys.stderr.write(f"alert-relay: {config.beszel_link_problem}\n")
        sys.stderr.flush()
    # All interfaces, but only inside this container's network namespace: the relay
    # publishes no host port (services/dozzle/compose.yml gives it no ports mapping,
    # which tests/contracts/dozzle.sh enforces), so the only addresses in reach are
    # the Compose-network address Dozzle dials by service name and the loopback the
    # healthcheck probes. Narrowing to loopback would break the first of those, and
    # the container address is assigned at start time rather than known here.
    server = create_server(("0.0.0.0", config.alert_relay_port), config)
    serve_until_stopped(server)


if __name__ == "__main__":
    main()
