#!/usr/bin/env python3
"""Private authenticated relay for Dozzle container events and Beszel host alerts."""

from __future__ import annotations

import collections
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


# `docker stop` sends SIGTERM, a foreground run ends on SIGINT. See
# serve_until_stopped for why they are blocked rather than handled.
STOP_SIGNALS = frozenset({signal.SIGINT, signal.SIGTERM})
MAX_BODY_BYTES = 16 * 1024
MAX_STATE_BYTES = 64 * 1024
MAX_STATE_ENTRIES = 128
# Separate from MAX_STATE_ENTRIES: counters may always be dropped, unhealthy
# entries may not, so a shared bound would let counters starve them.
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

# Emergency priority: Pushover requires both `retry` and `expire`, and caps a
# message at 50 retries, so this re-alerts every 60s for ~50 minutes or until
# acknowledged. `expire` stays above the cap so it stays correct if `retry` moves.
# Not role-configurable: an out-of-range value makes Pushover refuse every OOM alert.
EMERGENCY_PRIORITY = 2
EMERGENCY_RETRY_SECONDS = 60
EMERGENCY_EXPIRE_SECONDS = 3600
# Pushover's own cap; tests/dozzle_alert_relay_test.py checks it binds first.
EMERGENCY_MAX_RETRIES = 50

# Bounds one publish and so how long a hung Pushover holds the flock in
# process_event (#658). Not NOTIFICATION_TIMEOUT_SECONDS: policy_test pins that
# name identical across the scripts, and this one may change alone.
PUBLISH_TIMEOUT_SECONDS = 10

# Pushover refuses (4xx) messages over 1024 characters, so an over-long alert is
# lost. Bounded on the escaped length: `'` becomes `&#x27;`. compose_message
# drops detail lines from the last until the whole message fits.
MAX_ESCAPED_FIELD_CHARACTERS = 384
MAX_MESSAGE_CHARACTERS = 1024
# Pushover's title cap. The title is not escaped; the renderers' slices are the
# only guard, so keep them.
MAX_TITLE_CHARACTERS = 250
MAX_TITLE_CONTAINER_CHARACTERS = 128

# Pushover caps `url` at 512 and `url_title` at 100; a long link base is refused
# at start-up. The route /container/<12-char short id> is Dozzle's own (v11.0.1).
MAX_URL_CHARACTERS = 512
CONTAINER_ROUTE = "/container/"
MAX_LINK_BASE_CHARACTERS = MAX_URL_CHARACTERS - len(CONTAINER_ROUTE) - 64
URL_TITLE = "Open in Dozzle"
MAX_URL_TITLE_CHARACTERS = 100

# Beszel 0.20.0's shoutrrr generic webhook (template=json) posts exactly these
# keys; the message ends with a blank line and a link.
BESZEL_ENVELOPE_KEYS = {"title", "message"}
# internal/alerts/alerts_status.go: sendStatusAlert. The body is the title with
# the emoji trimmed, so it carries nothing the title does not.
BESZEL_STATUS_TITLE = re.compile(
    r"Connection to (?P<system>.+) is (?P<state>down \U0001F534|up \u2705)\Z"
)
# The system name may contain spaces, so the title is parsed from its fixed end.
BESZEL_THRESHOLD_TITLE = re.compile(r"(?P<rest>.+) (?P<direction>above|below) threshold\Z")
# Every metric name sendSystemAlert can put in a title. Longest first, so a
# system is never read as ending in part of a longer name.
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
# hub.MakeLink's route; anything but a short alphanumeric record id is refused.
BESZEL_SYSTEM_ROUTE = "/system/"
BESZEL_SYSTEM_ID_PATTERN = re.compile(r"[A-Za-z0-9]{1,64}\Z")
BESZEL_URL_TITLE = "Open in Beszel"
# Golem has its own Pushover application. Copy of beszel_remote_systems in
# roles/beszel/defaults/main.yml; tests/dozzle_alert_relay_test.py keeps them in step.
GOLEM_BESZEL_SYSTEM = "Golem"
# The monitoring name before it was capitalised. Accepted beside the new one
# because golem-platform and this repository deploy independently, and the hub
# record is renamed by roles/beszel only on the NAS's next converge; drop it once
# both have. Compared exactly, so "GOLEM" or "golem-2" are still not Golem.
GOLEM_FORMER_NAME = "golem"
GOLEM_BESZEL_SYSTEMS = (GOLEM_BESZEL_SYSTEM, GOLEM_FORMER_NAME)
GOLEM_IN_UNPARSED_TITLE = re.compile(
    rf"(?:\A| on )(?:{'|'.join(map(re.escape, GOLEM_BESZEL_SYSTEMS))})(?=[: ]|\Z)"
)
# golem's container events reach /alerts from golem's Dozzle agent: Dozzle
# v11.1.2's hub pushes its rules and this relay's dispatcher to every agent, and
# the agent dispatches them itself with .Container.HostName set to its own
# DOZZLE_HOSTNAME (internal/container/docker/client.go: NewLocalClient). golem
# sets that to this name, which is also the `|Golem` label dozzle_remote_agent
# gives the agent in inventory/group_vars/all/service_dozzle.yml;
# tests/dozzle_alert_relay_test.py holds this copy to that one. Compared whole,
# so a NAS container host that merely contains the name stays the NAS's.
GOLEM_DOZZLE_HOST = "Golem"
# validate_envelope rewrites either spelling to GOLEM_DOZZLE_HOST, so health
# state, ceilings and the Host line do not split across the rename.
GOLEM_DOZZLE_HOSTS = (GOLEM_DOZZLE_HOST, GOLEM_FORMER_NAME)
# An /alerts envelope identical to one already published within this window is
# acknowledged and dropped. Docker stamps each event to the nanosecond and the
# envelope carries that stamp, so a repeat is the same delivery twice, never a
# second crash. Golem's Dozzle agent was seen delivering one crash three times
# after its rules were pushed twice without a restart.
DUPLICATE_WINDOW = timedelta(minutes=10)
MAX_DUPLICATE_ENTRIES = 256
# The palette scripts/production_auto_deploy.py documents, spelled as it spells
# it; tests/policy_test.rb holds the copies identical.
COLOR_GREEN = "#2e7d32"
COLOR_RED = "#c62828"
COLOR_AMBER = "#f9a825"
COLOR_GREY = "#9e9e9e"
# parse_timestamp counts from 0001-01-01; Pushover's `timestamp` is Unix seconds.
UNIX_EPOCH_SECONDS = (datetime(1970, 1, 1).toordinal() - 1) * 86_400

# Upstream diagnostics are bounded: the log is capped at 10m x 3.
MAX_DIAGNOSTIC_CHARACTERS = 256
# An unbounded read on the error socket is an unbounded wait inside the state lock.
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
        "pushover_golem_token",
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
        golem_token=None,
    ):
        self.pushover_golem_token = golem_token
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
        # Order matters: the first refusal is what start-up reports.
        resolved = cls._required_settings(values)
        relay_port = cls._relay_port(resolved["ALERT_RELAY_PORT"])
        api_url = cls._pushover_api_url(resolved["PUSHOVER_API_URL"])
        link_base, link_problem = cls._dozzle_link(values)
        alerts_token, beszel_link_base, beszel_link_problem = cls._beszel_settings(values)
        golem_token = optional_setting(values, "PUSHOVER_GOLEM_TOKEN")
        container_ceiling, oom_container_ceiling, global_ceiling = cls._daily_ceilings(resolved)
        state_path = cls._validated_state_path(resolved["ALERT_STATE_PATH"])

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
            golem_token,
        )

    @staticmethod
    def _required_settings(values):
        # No shape rule on Pushover credentials: a guessed pattern would refuse a real
        # one with the fix locked inside the encrypted vault.
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
        return resolved

    @staticmethod
    def _relay_port(port):
        # No fallback: the port's only home is dozzle_alert_relay_port, and a default
        # here could silently disagree with the healthcheck and dispatcher URL.
        if not PORT_PATTERN.fullmatch(port) or int(port) > 65535:
            raise ConfigurationError("ALERT_RELAY_PORT must be a TCP port number")
        return int(port)

    @staticmethod
    def _pushover_api_url(value):
        # A whole URL so a lane can point it at a recorder. Query and fragment are
        # refused: credentials travel in the form body.
        parsed = urllib.parse.urlsplit(value)
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
        return urllib.parse.urlunsplit(
            (parsed.scheme, parsed.netloc, parsed.path, "", "")
        )

    @staticmethod
    def _dozzle_link(values):
        """(link_base, link_problem): exactly one of the two is None."""
        # Optional on purpose: `current` is repointed several roles before roles/dozzle
        # re-renders this environment, and a relay that crash-looped on a missing link
        # base would lose every alert meanwhile (#605). Missing costs only the link.
        raw_link_base = values.get("ALERT_RELAY_LINK_BASE")
        if not isinstance(raw_link_base, str) or not raw_link_base:
            return None, "ALERT_RELAY_LINK_BASE is not set; alerts will carry no Dozzle link"
        try:
            return validated_link_base(raw_link_base), None
        except ConfigurationError as error:
            return None, f"{error}; alerts will carry no Dozzle link"

    @staticmethod
    def _beszel_settings(values):
        """(alerts_token, beszel_link_base, beszel_link_problem), never refused."""
        # Optional for the same reason. Without the Alerts token /beszel answers 503;
        # without the Golem token golem's alerts go out on Alerts and its container
        # events on Containers, each saying so.
        alerts_token = optional_setting(values, "PUSHOVER_ALERTS_TOKEN")
        raw_beszel_link_base = values.get("BESZEL_LINK_BASE")
        if not isinstance(raw_beszel_link_base, str) or not raw_beszel_link_base:
            return alerts_token, None, (
                "BESZEL_LINK_BASE is not set; Beszel alerts will carry no link"
            )
        try:
            return alerts_token, validated_link_base(raw_beszel_link_base), None
        except ConfigurationError:
            return alerts_token, None, (
                "BESZEL_LINK_BASE must be an HTTP(S) origin; "
                "Beszel alerts will carry no link"
            )

    @staticmethod
    def _daily_ceilings(resolved):
        """(container, oom_container, global) daily alert ceilings, in that order."""
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
        # Refused at start-up rather than silently inverted.
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
        return container_ceiling, oom_container_ceiling, global_ceiling

    @staticmethod
    def _validated_state_path(value):
        state_path = Path(value)
        if not state_path.is_absolute() or state_path.name in {"", ".", ".."}:
            raise ConfigurationError("ALERT_STATE_PATH must be an absolute file path")
        return state_path

def optional_setting(values, name):
    """The setting `name`, or None when it is absent, empty or holds a control character."""
    value = values.get(name)
    if not isinstance(value, str) or not value or contains_control(value):
        return None
    return value


def validated_link_base(value):
    """Dozzle's origin as the link base, or ConfigurationError saying why not.

    Refused rather than repaired: no userinfo, path, query or fragment, and short
    enough that any id keeps the url inside Pushover's cap. Never echoes the value.
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
        "host": GOLEM_DOZZLE_HOST if host in GOLEM_DOZZLE_HOSTS else host,
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


def golem_fallback_line(application):
    """The amber Reason line on a golem message sent on `application` instead of Golem."""
    return (
        f'\u2753 <b>Reason</b> <font color="{COLOR_AMBER}">Golem app token not set</font>'
        f"; sent on {application}"
    )


def render_notification(event, link_base, golem_fallback=False):
    """Render one event as Pushover form fields.

    Priorities: OOM 2 (acknowledge loop), Unexpected exit and Unhealthy 1 (bypass
    quiet hours), Recovery -1 (silent badge). Only `message` is HTML; the title is
    plain text, so the name goes in raw. A pre-1970 timestamp is left off.
    golem_fallback marks a golem event sent on Containers because the Golem token
    is not set.
    """
    rule = event["rule"]
    container = html_escape(event["container"])
    title, state, closing = notification_wording(
        rule, event["container"][:MAX_TITLE_CONTAINER_CHARACTERS], event["exitCode"]
    )
    # No closing promises a recovery: a recreated container never closes its
    # predecessor's entry.
    if link_base is None and rule == "Unhealthy":
        closing = ""
    priority = {
        "OOM": EMERGENCY_PRIORITY,
        "Unexpected exit": 1,
        "Unhealthy": 1,
        "Recovery": -1,
    }[rule]
    fields = {
        "title": title,
        "message": compose_message(
            f"<b>{container}</b> {state}",
            notification_details(event, container, link_base)
            + ([golem_fallback_line("Containers")] if golem_fallback else []),
            closing,
        ),
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


def notification_wording(rule, name, exit_code):
    """(title, state, closing) for one rule; `name` is the raw, title-bounded name.

    The title carries the whole meaning: a lock screen shows no HTML.
    """
    return {
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


def notification_details(event, container, link_base):
    """The detail lines of a container alert; `container` is already escaped."""
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
    details = [
        f"\U0001f5a5️ <b>Host</b> {html_escape(event['host'])}",
        f"\U0001f4e6 <b>Container</b> {shown}",
    ]
    if event["rule"] == "Unexpected exit":
        details.append(
            f'\U0001f522 <b>Exit code</b> <font color="{COLOR_RED}">{html_escape(event["exitCode"])}</font>'
        )
    details.append(f"\U0001f552 <b>When</b> {human_time(parse_timestamp(event['timestamp']))}")
    return details

def validate_beszel_envelope(payload):
    """Beszel's alert exactly as its generic webhook sends it, or SchemaError."""
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

    kind is "status", "threshold", or None for any unrecognised title; problem is
    True for an alert and False for a recovery.
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


def beszel_is_golem(alert):
    """Whether a Beszel alert is about golem; the parsed system is compared whole."""
    system = classify_beszel(alert)["system"]
    if system is not None:
        return system in GOLEM_BESZEL_SYSTEMS
    return GOLEM_IN_UNPARSED_TITLE.search(alert["title"]) is not None


def beszel_link(link, link_base):
    """The link Beszel sent, only if it is this relay's own Beszel system page."""
    if link_base is None:
        return None
    route = f"{link_base}{BESZEL_SYSTEM_ROUTE}"
    if not link.startswith(route) or not BESZEL_SYSTEM_ID_PATTERN.fullmatch(link[len(route):]):
        return None
    return link


def render_beszel(alert, link_base, now, golem_fallback=False):
    """Render one Beszel alert as Pushover form fields.

    Alert 1, recovery -1; an unrecognised title goes at 1 unless it ends in
    Beszel's check mark. golem_fallback adds an amber Reason line when a golem
    alert goes out on Alerts because the Golem token is unset.
    """
    parsed = classify_beszel(alert)
    fields = {"html": "1", "priority": 1 if parsed["problem"] else -1}
    link = beszel_link(parsed["link"], link_base)
    if link is not None:
        fields["url"] = link
        fields["url_title"] = BESZEL_URL_TITLE
    fallback_line = golem_fallback_line("Alerts")
    if parsed["kind"] is None:
        text = parsed["body"].strip() or alert["title"]
        escaped = html_escape(text, MAX_MESSAGE_CHARACTERS, MAX_MESSAGE_CHARACTERS)
        lines = escaped.split("\n")
        if golem_fallback:
            lines = [fallback_line, ""] + lines
        return dict(
            fields,
            title=alert["title"][:MAX_TITLE_CHARACTERS],
            message=fit_message(lines),
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
    if golem_fallback:
        details.append(fallback_line)
    details.append(f"\U0001f552 <b>When</b> {human_time(datetime_nanoseconds(now))}")
    return dict(
        fields,
        title=title[:MAX_TITLE_CHARACTERS],
        message=compose_message(lead, details),
    )


def render_ceiling_notice(event, scope, ceiling, day, oom_allowance=None):
    """Render the one message a tripped ceiling is allowed to send.

    Priority 1: the platform going quiet is worse news than any suppressed alert.
    `oom_allowance` says OOM kills still get through; None for the global scope.
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
    # Bound before the try so the handler knows whether it owns a descriptor (#658).
    directory_fd = None
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
        if directory_fd is not None:
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

    A day key rather than a rolling window: a backwards clock jump cannot wedge it.
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

    # Older schemas migrate rather than being refused; a migrated document starts
    # with a full daily allowance.
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

    Only healthy entries may be evicted, while any counter may, so bytes come from
    counters first (lowest count first). This defers, not prevents, the
    all-unhealthy raise; MAX_BUDGET_ENTRIES has the numbers.
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
    """One sanitiser for every field that reaches the log.

    Redact before truncating (half a credential is still a leak); strip control
    characters so no line can forge a second log entry.
    """
    text = str(value)
    for secret in (
        config.pushover_token, config.pushover_user_key,
        config.pushover_alerts_token, config.pushover_golem_token,
    ):
        if secret:
            text = text.replace(secret, "[redacted]")
    text = "".join(
        character if not contains_control(character) else "?" for character in text
    )
    return text[:maximum]


def report_upstream_failure(config, notification, reason, detail):
    """Say on stderr that an alert was not delivered.

    Dozzle is told 502 and does not retry, so this is the only trace. One
    assembled write, because print() issues two and this server is threaded.
    """
    line = (
        f"alert-relay: {reason}: "
        f"alert={log_safe(notification.get('title', 'unknown'), config)} "
        f"detail={log_safe(detail, config)}\n"
    )
    sys.stderr.write(line)
    sys.stderr.flush()


def report_refused_envelope(config, route, error):
    """Say on stderr that an envelope was refused, which a 400 never did (#699).

    SchemaError messages name a field, never its value; log_safe runs regardless.
    One assembled write, as in report_upstream_failure.
    """
    line = (
        f"alert-relay: refused an envelope on {route}: "
        f"{log_safe(f'{type(error).__name__}: {error}', config)}\n"
    )
    sys.stderr.write(line)
    sys.stderr.flush()


def read_upstream_detail(error):
    """The far end's own explanation, bounded; a failed read never masks the failure."""
    try:
        return error.read(MAX_DIAGNOSTIC_BYTES).decode("utf-8", errors="replace")
    except Exception:  # noqa: BLE001 - a failed read must not replace the failure
        return "the error response could not be read"


def publish(config, notification, token):
    """POST one message to Pushover, as the application `token` names.

    Credentials travel as `token` and `user` form fields, so a recorded request
    body is a credential.
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
    # Rejection and outage are reported differently: an outage heals, a rejection
    # never does. HTTPError first: it subclasses URLError, which subclasses OSError.
    try:
        with NO_REDIRECT_OPENER.open(request, timeout=PUBLISH_TIMEOUT_SECONDS) as response:
            if not 200 <= response.status < 300:
                # Defensive: urllib raises HTTPError for >= 400 and redirects are refused.
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
    """Today's budget, reset whenever the stored day is not today's (either direction).

    A missing budget is today's empty one, so an upgrade starts with a full allowance.
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

    Without it a failing state write lost each increment, and 500 events published
    500 alerts. Failing closed would silence alerting when the disk fills, so the
    bound degrades to per-process (ceiling x restarts with a broken store).
    Its lock is NOT the ceiling's interlock: process_event's flock is. Owned by
    the server, not the module, so the restart test still proves the store half.
    """

    def __init__(self):
        self._lock = threading.Lock()
        self._budget = None

    def raise_floor(self, budget):
        """`budget`, never lower than what this process has already authorised (elementwise)."""
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
        """Adopt a charged budget as the new floor, only after its publish went out.

        It is bounded_state's result, so the floor cannot grow with container churn.
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
    ("silent", budget); the caller records the budget only after publishing.
    Global backstop first, then a per-container allowance; OOM gets a higher
    allowance rather than an exemption, because a crash loop is unbounded.
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

    # A Beszel host alert has no container, so it counts against the global ceiling only.
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


def process_event(config, event, floor, delivered):
    """Reconcile one event, publish what the ceiling allows, and persist.

    `floor` has no default: a default would switch the safety device off.
    Nor has `delivered`, for the same reason.
    """
    identity = f"{event['host']}\0{event['containerId']}"
    now = utc_now()
    golem = event["host"] == GOLEM_DOZZLE_HOST
    golem_fallback = golem and config.pushover_golem_token is None
    with LockedState(config.alert_state_path) as state_file:
        # Under the flock, which serialises concurrent deliveries of one event,
        # and before the ceiling so a repeat is charged nothing.
        if delivered.seen(event, now):
            return
        entries, stored_budget, migration_required = state_file.read()
        # Read, then corrected upwards, never downwards: a lost increment must not
        # grant the same allowance twice.
        budget = floor.raise_floor(rolled_budget(stored_budget, now))
        proposed = {key: dict(entry) for key, entry in entries.items()}
        publication_required = event["rule"] in {"OOM", "Unexpected exit"}

        if event["rule"] in {"Unhealthy", "Recovery"}:
            publication_required = health_transition(event, identity, entries, proposed)
            if publication_required is None:
                return

        # Charged only once the transition says publish, so suppressed duplicates are free.
        notification = None
        charged = budget
        if publication_required:
            decision = charge_budget(budget, identity, event["rule"], config)
            charged = decision[1]
            notification = decision_notification(config, event, decision, golem_fallback)

        proposed, charged, document = bounded_state(proposed, charged, now)
        replacement_required = (
            migration_required or proposed != entries or charged != stored_budget
        )
        # Publish, raise the floor, then persist, ALL INSIDE THE FLOCK: the flock (not
        # BudgetFloor's lock) is the ceiling interlock. Moving publish out breaches the
        # ceiling silently (measured: 40 delivered against a ceiling of 10). Do not.
        # Publish first so a refusing upstream spends nothing; floor before persist so
        # the bound survives a failed write; a failed persist still returns 500.
        if notification is not None:
            # golem's events go out on the Golem application; a ceiling notice
            # stays on Containers, as process_beszel keeps its own on Alerts.
            token = config.pushover_token
            if golem and decision[0] == "publish":
                if golem_fallback:
                    sys.stderr.write(
                        "alert-relay: PUSHOVER_GOLEM_TOKEN is not set; "
                        "a Golem container event was sent on the Containers application\n"
                    )
                    sys.stderr.flush()
                else:
                    token = config.pushover_golem_token
            publish(config, notification, token)
            # Only once it went out: a repeat of a failed publish is a retry.
            delivered.record(event, now)
        floor.record(charged)
        if replacement_required:
            state_file.replace(proposed, charged, document)


def health_transition(event, identity, entries, proposed):
    """Whether an Unhealthy or Recovery event publishes; None drops it unrecorded.

    `proposed` receives the entry this event leaves behind.
    """
    incoming_state = (
        "unhealthy" if event["rule"] == "Unhealthy" else "healthy"
    )
    incoming_order = parse_timestamp(event["timestamp"])
    existing = entries.get(identity)
    if existing is None:
        publication_required = incoming_state == "unhealthy"
    else:
        existing_order = parse_timestamp(existing["timestamp"])
        if incoming_order < existing_order:
            return None
        if incoming_order == existing_order:
            if existing["state"] == "healthy":
                return None
            if incoming_state == "unhealthy":
                return True
            proposed[identity] = {
                "identity": identity,
                "state": "healthy",
                "timestamp": event["timestamp"],
            }
            return True
        publication_required = incoming_state == "unhealthy" or existing[
            "state"
        ] == "unhealthy"
    proposed[identity] = {
        "identity": identity,
        "state": incoming_state,
        "timestamp": event["timestamp"],
    }
    return publication_required


def decision_notification(config, event, decision, golem_fallback=False):
    """The Pushover fields a charge_budget decision authorises, or None if silent."""
    if decision[0] == "publish":
        return render_notification(event, config.alert_relay_link_base, golem_fallback)
    if decision[0] == "notice":
        return render_ceiling_notice(
            event, decision[2], decision[3], decision[1]["day"], decision[4]
        )
    return None

def process_beszel(config, alert, floor):
    """Charge one Beszel alert against the global ceiling, publish it, persist.

    Same order and lock as process_event. Golem alerts use the Golem application,
    or Alerts with a Reason line when its token is unset; ceiling notices use Alerts.
    """
    now = utc_now()
    golem = beszel_is_golem(alert)
    golem_fallback = golem and config.pushover_golem_token is None
    token = config.pushover_golem_token if golem and not golem_fallback else config.pushover_alerts_token
    with LockedState(config.alert_state_path) as state_file:
        entries, stored_budget, migration_required = state_file.read()
        budget = floor.raise_floor(rolled_budget(stored_budget, now))
        decision = charge_budget(budget, None, None, config)
        charged = decision[1]
        notification = None
        if decision[0] == "publish":
            notification = render_beszel(alert, config.beszel_link_base, now, golem_fallback)
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
            if decision[0] == "notice":
                token = config.pushover_alerts_token
            elif golem_fallback:
                # One write per alert, naming the setting and never a value.
                sys.stderr.write(
                    "alert-relay: PUSHOVER_GOLEM_TOKEN is not set; "
                    "a Golem alert was sent on the Alerts application\n"
                )
                sys.stderr.flush()
            publish(config, notification, token)
        floor.record(charged)
        if replacement_required:
            state_file.replace(proposed, charged, document)


class DeliveredEvents:
    """The /alerts envelopes this process has published, to drop an exact repeat.

    Per process and bounded, like BudgetFloor: a restart forgets, so a repeat
    straddling one is delivered twice, and past MAX_DUPLICATE_ENTRIES the oldest
    are forgotten early. Both fail towards sending, never towards silence.
    """

    def __init__(self, window=None, capacity=MAX_DUPLICATE_ENTRIES):
        # Read at construction rather than bound as a default, so a test can
        # shorten the module's window before create_server.
        self._window = DUPLICATE_WINDOW if window is None else window
        self._capacity = capacity
        self._published = collections.OrderedDict()

    @staticmethod
    def key(event):
        return (event["host"], event["containerId"], event["event"],
                event["timestamp"], event["rule"])

    def seen(self, event, now):
        """Whether `event` was published within the window. Call under the flock."""
        while self._published:
            oldest_key, published_at = next(iter(self._published.items()))
            # A clock that stepped back forgets too: towards sending again.
            if timedelta(0) <= now - published_at < self._window:
                break
            del self._published[oldest_key]
        return self.key(event) in self._published

    def record(self, event, now):
        """Remember `event` as published. Call under the flock, after the publish."""
        key = self.key(event)
        self._published.pop(key, None)
        self._published[key] = now
        while len(self._published) > self._capacity:
            self._published.popitem(last=False)


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
        # Same token, content type and size bound; they differ in envelope and application.
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
            process_event(
                self.server.config, event, self.server.budget_floor,
                self.server.delivered_events,
            )
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

    # Access logging off deliberately: publish() reports undelivered alerts on
    # stderr, and a request log would bury them.
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
    server.delivered_events = DeliveredEvents()
    return server


def stop_on_signal(server):
    """Shut `server` down when a stop signal arrives. Runs off the main thread.

    server.shutdown() blocks until the accept loop stops, so it cannot run on it.
    """
    signal.sigwait(STOP_SIGNALS)
    server.shutdown()


def serve_until_stopped(server):
    """Serve until a stop signal arrives, then close the listener and return.

    As PID 1 this process gets no default signal dispositions, and a raising
    handler can be swallowed by socketserver (#516), so stop signals are blocked
    before any thread exists and one daemon thread sigwaits for them. SIGKILL
    still ends it at 137. `init: true` was not taken: this relay forks nothing and
    takes its own stop signals; only interpreter start-up is left uncovered.
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
    # Blocked before config and before any thread, so only interpreter start-up
    # meets a default disposition; see serve_until_stopped.
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
    # All interfaces inside the container namespace only: the host publication is
    # 127.0.0.1 (for golem's Tailscale Serve forward), and the Compose-network
    # address Dozzle and Beszel dial is not known in advance.
    server = create_server(("0.0.0.0", config.alert_relay_port), config)
    serve_until_stopped(server)


if __name__ == "__main__":
    main()
