#!/usr/bin/env python3
"""Private authenticated Dozzle event relay for structured ntfy alerts."""

from __future__ import annotations

import contextlib
import fcntl
import hmac
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import re
import stat
import threading
import urllib.error
import urllib.parse
import urllib.request


MAX_BODY_BYTES = 16 * 1024
MAX_STATE_BYTES = 64 * 1024
STATE_VERSION = 1
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
    r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?Z\Z"
)
MARKDOWN_PATTERN = re.compile(r"([\\`*_{}\[\]()#+\-.!|>])")


class ConfigurationError(Exception):
    pass


class SchemaError(Exception):
    pass


class StateError(Exception):
    pass


class UpstreamError(Exception):
    pass


class Config:
    """Validated immutable runtime settings."""

    __slots__ = (
        "alert_relay_token",
        "ntfy_publish_url",
        "ntfy_topic",
        "ntfy_token",
        "alert_state_path",
    )

    def __init__(self, relay_token, publish_url, topic, ntfy_token, state_path):
        self.alert_relay_token = relay_token
        self.ntfy_publish_url = publish_url
        self.ntfy_topic = topic
        self.ntfy_token = ntfy_token
        self.alert_state_path = state_path

    @classmethod
    def from_mapping(cls, values):
        names = (
            "ALERT_RELAY_TOKEN",
            "NTFY_PUBLISH_URL",
            "NTFY_TOPIC",
            "NTFY_TOKEN",
            "ALERT_STATE_PATH",
        )
        resolved = {}
        for name in names:
            value = values.get(name)
            if not isinstance(value, str) or not value or contains_control(value):
                raise ConfigurationError(f"{name} is required")
            resolved[name] = value

        parsed = urllib.parse.urlsplit(resolved["NTFY_PUBLISH_URL"])
        if (
            parsed.scheme not in {"http", "https"}
            or not parsed.hostname
            or parsed.username is not None
            or parsed.password is not None
            or parsed.path not in {"", "/"}
            or parsed.query
            or parsed.fragment
        ):
            raise ConfigurationError("NTFY_PUBLISH_URL must be an HTTP(S) root URL")
        publish_url = urllib.parse.urlunsplit(
            (parsed.scheme, parsed.netloc, "/", "", "")
        )

        topic = resolved["NTFY_TOPIC"]
        if len(topic) > 128 or not re.fullmatch(r"[A-Za-z0-9_-]+", topic):
            raise ConfigurationError("NTFY_TOPIC is invalid")
        state_path = Path(resolved["ALERT_STATE_PATH"])
        if not state_path.is_absolute() or state_path.name in {"", ".", ".."}:
            raise ConfigurationError("ALERT_STATE_PATH must be an absolute file path")

        return cls(
            resolved["ALERT_RELAY_TOKEN"],
            publish_url,
            topic,
            resolved["NTFY_TOKEN"],
            state_path,
        )


def contains_control(value):
    return any(ord(character) < 0x20 or ord(character) == 0x7F for character in value)


def require_text(payload, key, maximum):
    value = payload[key]
    if not isinstance(value, str) or not value or len(value) > maximum or contains_control(value):
        raise SchemaError(f"invalid {key}")
    return value


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
    if not TIMESTAMP_PATTERN.fullmatch(timestamp):
        raise SchemaError("invalid timestamp")

    health_status = payload["healthStatus"]
    exit_code = payload["exitCode"]
    if not isinstance(health_status, str) or not isinstance(exit_code, str):
        raise SchemaError("status fields must be strings")
    if contains_control(health_status) or contains_control(exit_code):
        raise SchemaError("invalid status fields")

    if rule == "Unexpected exit":
        if event != "die" or health_status != "" or not re.fullmatch(r"\d{1,3}", exit_code):
            raise SchemaError("invalid unexpected-exit relationship")
        numeric_exit = int(exit_code)
        if numeric_exit > 255 or exit_code in {"0", "130", "137", "143"}:
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


def markdown_escape(value, maximum=128):
    bounded = value[:maximum]

    def escape(match):
        character = match.group(1)
        position = match.start()
        if (
            character == "_"
            and position > 0
            and position + 1 < len(bounded)
            and bounded[position - 1].isalnum()
            and bounded[position + 1].isalnum()
        ):
            return character
        return f"\\{character}"

    return MARKDOWN_PATTERN.sub(escape, bounded)


def render_notification(event, topic):
    rule = event["rule"]
    host = markdown_escape(event["host"])
    container = markdown_escape(event["container"])
    title_container = event["container"][:128]
    title_prefix = {
        "OOM": "Out of memory",
        "Unexpected exit": "Unexpected exit",
        "Unhealthy": "Unhealthy",
        "Recovery": "Recovered",
    }[rule]
    title = f"{title_prefix} · {title_container}"
    lines = [f"**Host:** `{host}`", f"**Container:** `{container}`"]
    if rule == "Unexpected exit":
        lines.append(f"**Exit code:** `{event['exitCode']}`")
    else:
        status_text = {
            "OOM": "out of memory",
            "Unhealthy": "unhealthy",
            "Recovery": "healthy",
        }[rule]
        lines.append(f"**Status:** `{status_text}`")
    priority, tags = {
        "OOM": (5, ["rotating_light", "skull"]),
        "Unexpected exit": (5, ["warning", "skull"]),
        "Unhealthy": (5, ["rotating_light", "warning"]),
        "Recovery": (3, ["white_check_mark"]),
    }[rule]
    return {
        "topic": topic,
        "title": title,
        "message": "\n".join(lines),
        "priority": priority,
        "tags": tags,
        "markdown": True,
    }


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
            or stat.S_IMODE(details.st_mode) & 0o022
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


class LockedState:
    def __init__(self, state_path):
        self.state_path = Path(state_path)
        self.directory_fd = None
        self.lock_fd = None

    def __enter__(self):
        self.directory_fd = open_directory_no_symlinks(self.state_path.parent)
        flags = os.O_RDWR | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0)
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
        flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
        try:
            file_fd = os.open(self.state_path.name, flags, dir_fd=self.directory_fd)
        except FileNotFoundError:
            return set()
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
        try:
            document = json.loads(raw.decode("utf-8"), object_pairs_hook=unique_object)
        except (UnicodeDecodeError, json.JSONDecodeError, SchemaError):
            raise StateError("state file is corrupt") from None
        if (
            not isinstance(document, dict)
            or set(document) != {"version", "unhealthy"}
            or type(document["version"]) is not int
            or document["version"] != STATE_VERSION
            or not isinstance(document["unhealthy"], list)
        ):
            raise StateError("state schema differs")
        entries = document["unhealthy"]
        if not all(isinstance(entry, str) for entry in entries):
            raise StateError("invalid state identity")
        if entries != sorted(set(entries)):
            raise StateError("state entries are not canonical")
        for entry in entries:
            if entry.count("\0") != 1:
                raise StateError("invalid state identity")
            host, container_id = entry.split("\0")
            if (
                not host
                or len(host) > 256
                or contains_control(host)
                or not CONTAINER_ID_PATTERN.fullmatch(container_id)
            ):
                raise StateError("invalid state identity")
        return set(entries)

    def replace(self, unhealthy):
        document = json.dumps(
            {"version": STATE_VERSION, "unhealthy": sorted(unhealthy)},
            ensure_ascii=True,
            separators=(",", ":"),
        ).encode("utf-8") + b"\n"
        temporary_name = (
            f".{self.state_path.name}.{os.getpid()}.{threading.get_ident()}.tmp"
        )
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
        temporary_fd = None
        try:
            temporary_fd = os.open(
                temporary_name, flags, 0o600, dir_fd=self.directory_fd
            )
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
            try:
                os.unlink(temporary_name, dir_fd=self.directory_fd)
            except FileNotFoundError:
                pass
            raise StateError("state replacement failed") from None

def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise SchemaError("duplicate JSON key")
        result[key] = value
    return result


def publish(config, notification):
    body = json.dumps(notification, ensure_ascii=False, separators=(",", ":")).encode(
        "utf-8"
    )
    request = urllib.request.Request(
        config.ntfy_publish_url,
        data=body,
        headers={
            "Authorization": f"Bearer {config.ntfy_token}",
            "Content-Type": "application/json",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=10) as response:
            if not 200 <= response.status < 300:
                raise UpstreamError("upstream rejected publish")
    except urllib.error.HTTPError as error:
        error.close()
        raise UpstreamError("upstream unavailable") from None
    except (OSError, urllib.error.URLError):
        raise UpstreamError("upstream unavailable") from None


def process_event(config, event):
    identity = f"{event['host']}\0{event['containerId']}"
    with LockedState(config.alert_state_path) as state_file:
        unhealthy = state_file.read()
        if event["rule"] == "Recovery" and identity not in unhealthy:
            return

        proposed = set(unhealthy)
        if event["rule"] == "Unhealthy":
            proposed.add(identity)
        elif event["rule"] == "Recovery":
            proposed.remove(identity)

        publish(config, render_notification(event, config.ntfy_topic))
        if proposed != unhealthy:
            state_file.replace(proposed)


class RelayRequestHandler(BaseHTTPRequestHandler):
    server_version = "DozzleAlertRelay/1"

    def do_GET(self):  # noqa: N802 - BaseHTTPRequestHandler API
        if self.path != "/healthz":
            self.send_text(404, "not found\n")
            return
        self.send_text(200, "ok\n")

    def do_POST(self):  # noqa: N802 - BaseHTTPRequestHandler API
        if self.path != "/alerts":
            self.send_text(404, "not found\n")
            return
        authorization = self.headers.get("Authorization", "")
        expected = f"Bearer {self.server.config.alert_relay_token}"
        if not hmac.compare_digest(authorization, expected):
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
        try:
            payload = json.loads(raw.decode("utf-8"), object_pairs_hook=unique_object)
            event = validate_envelope(payload)
        except (UnicodeDecodeError, json.JSONDecodeError, SchemaError):
            self.send_text(400, "invalid request\n")
            return
        try:
            process_event(self.server.config, event)
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

    def log_message(self, _format, *_args):
        pass


class RelayServer(ThreadingHTTPServer):
    daemon_threads = True


def create_server(address, config):
    server = RelayServer(address, RelayRequestHandler)
    server.config = config
    return server


def main():
    try:
        config = Config.from_mapping(os.environ)
    except ConfigurationError:
        raise SystemExit("alert relay configuration is invalid") from None
    server = create_server(("0.0.0.0", 8081), config)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
