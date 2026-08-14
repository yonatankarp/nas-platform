"""Beszel 0.18.7 persisted telemetry validation and bounded polling."""

from datetime import datetime, timezone
import re
import time


FUTURE_SKEW_SECONDS = 5
SAFE_ID = re.compile(r"^[A-Za-z0-9_-]+$")


class TransientTelemetryError(Exception):
    """A collection request that may succeed within the current deadline."""


class NonRetryableTelemetryError(Exception):
    """A collection request that cannot succeed by retrying."""


def _valid_id(value):
    return isinstance(value, str) and bool(SAFE_ID.fullmatch(value))


def _safe_id(record):
    if not isinstance(record, dict) or "id" not in record:
        return "[absent]"
    return record["id"] if _valid_id(record["id"]) else "[invalid]"


def _number(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def _fresh(record, system_id, now, freshness_seconds):
    if not isinstance(record, dict) or not _valid_id(record.get("id")):
        return False
    if record.get("system") != system_id or record.get("type") != "1m":
        return False
    created = record.get("created")
    if not isinstance(created, str):
        return False
    try:
        parsed = datetime.fromisoformat(created.replace("Z", "+00:00"))
        if parsed.tzinfo is None or parsed.utcoffset() is None:
            return False
        age = (now - parsed.astimezone(timezone.utc)).total_seconds()
    except (TypeError, ValueError, OverflowError):
        return False
    return -FUTURE_SKEW_SECONDS <= age <= freshness_seconds


def _named_metrics(entries, numeric_fields):
    if not entries:
        return False
    for entry in entries:
        if not isinstance(entry, dict):
            return False
        name = entry.get("n")
        if not isinstance(name, str) or not name.strip():
            return False
        if not all(_number(entry.get(field)) for field in numeric_fields):
            return False
    return True


def evaluate_telemetry(
    system_id,
    system_record,
    container_record,
    required_categories,
    freshness_seconds,
    now=None,
):
    """Return only safe category and record identity evidence."""
    now = now or datetime.now(timezone.utc)
    system_fresh = _fresh(system_record, system_id, now, freshness_seconds)
    container_fresh = _fresh(container_record, system_id, now, freshness_seconds)
    system_stats = system_record.get("stats") if isinstance(system_record, dict) else None
    container_stats = container_record.get("stats") if isinstance(container_record, dict) else None
    system_stats = system_stats if isinstance(system_stats, dict) else {}
    container_stats = container_stats if isinstance(container_stats, list) else []
    gpu_stats = system_stats.get("g")

    ready = {
        "core": system_fresh
        and all(_number(system_stats.get(field)) for field in ("cpu", "m", "mu", "mp"))
        and system_stats.get("m", 0) > 0,
        "disk": system_fresh
        and all(_number(system_stats.get(field)) for field in ("d", "du", "dp"))
        and system_stats.get("d", 0) > 0,
        "gpu": system_fresh
        and isinstance(gpu_stats, dict)
        and _named_metrics(gpu_stats.values(), ("u",)),
        "containers": container_fresh and _named_metrics(container_stats, ("c", "m")),
    }
    return {
        "system_id": system_id if _valid_id(system_id) else "[invalid]",
        "system_stats_id": _safe_id(system_record),
        "container_stats_id": _safe_id(container_record),
        "missing_categories": [
            category for category in required_categories if not ready.get(category, False)
        ],
    }


def poll_telemetry(
    *,
    system_id,
    required_categories,
    freshness_seconds,
    timeout_seconds,
    request_timeout_seconds,
    delay_seconds,
    fetcher,
    monotonic=time.monotonic,
    wall_clock=lambda: datetime.now(timezone.utc),
    sleep=time.sleep,
):
    """Poll both collections until ready or one monotonic deadline expires."""
    deadline = monotonic() + timeout_seconds
    system_record = None
    container_record = None
    evidence = evaluate_telemetry(
        system_id, system_record, container_record, required_categories, freshness_seconds, wall_clock()
    )
    while True:
        remaining = deadline - monotonic()
        if remaining <= 0:
            return evidence
        try:
            candidate = fetcher("system_stats", min(request_timeout_seconds, remaining))
            if candidate is not None:
                system_record = candidate
        except TransientTelemetryError:
            pass

        remaining = deadline - monotonic()
        if remaining <= 0:
            return evidence
        try:
            candidate = fetcher("container_stats", min(request_timeout_seconds, remaining))
            if candidate is not None:
                container_record = candidate
        except TransientTelemetryError:
            pass

        evidence = evaluate_telemetry(
            system_id,
            system_record,
            container_record,
            required_categories,
            freshness_seconds,
            wall_clock(),
        )
        if not evidence["missing_categories"]:
            return evidence

        remaining = deadline - monotonic()
        if remaining <= 0:
            return evidence
        sleep(min(delay_seconds, remaining))
