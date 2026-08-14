#!/usr/bin/env python3
"""Fast deterministic tests for the production Beszel telemetry probe."""

from datetime import datetime, timedelta, timezone
from pathlib import Path
import sys


ROOT = Path(__file__).resolve().parents[1]
sys.dont_write_bytecode = True
sys.path.insert(0, str(ROOT))

from module_utils.beszel_telemetry import (  # noqa: E402
    TransientTelemetryError,
    evaluate_telemetry,
    poll_telemetry,
)


NOW = datetime(2026, 8, 12, 12, 0, tzinfo=timezone.utc)


def records(created):
    system = {
        "id": "system-stats-safe",
        "system": "system-safe",
        "type": "1m",
        "created": created.isoformat(),
        "stats": {
            "cpu": 0.0,
            "m": 8.0,
            "mu": 2.0,
            "mp": 25.0,
            "d": 100.0,
            "du": 40.0,
            "dp": 40.0,
            "g": {"0": {"n": "Intel", "u": 0.0}},
        },
    }
    containers = {
        "id": "container-stats-safe",
        "system": "system-safe",
        "type": "1m",
        "created": created.isoformat(),
        "stats": [{"n": "hub", "c": 0.0, "m": 0.1}],
    }
    return system, containers


def assert_true(condition, message):
    if not condition:
        raise AssertionError(message)


def test_exact_record_shape():
    system, containers = records(NOW - timedelta(seconds=30))
    for record_name, record in (("system", system), ("containers", containers)):
        for invalid_id in (None, "", "  ", "bad id", 123):
            mutated = dict(record)
            if invalid_id is None:
                mutated.pop("id")
            else:
                mutated["id"] = invalid_id
            evidence = evaluate_telemetry(
                "system-safe",
                mutated if record_name == "system" else system,
                mutated if record_name == "containers" else containers,
                ["core", "disk", "containers", "gpu"],
                180,
                NOW,
            )
            assert_true(evidence["missing_categories"], f"accepted invalid {record_name} record ID")

    for invalid_created in ("2026-08-12T11:59:00", 123, None):
        mutated = dict(system)
        mutated["created"] = invalid_created
        evidence = evaluate_telemetry(
            "system-safe", mutated, containers, ["core", "disk", "containers"], 180, NOW
        )
        assert_true("core" in evidence["missing_categories"], "accepted timestamp without timezone")


def test_fast_empty_poll_reaches_next_sample():
    monotonic = [0.0]
    calls = []
    system, containers = records(NOW + timedelta(seconds=61))

    def fetch(collection, timeout):
        calls.append((collection, timeout))
        monotonic[0] += 0.01
        if monotonic[0] < 61:
            return None
        return system if collection == "system_stats" else containers

    evidence = poll_telemetry(
        system_id="system-safe",
        required_categories=["core", "disk", "containers"],
        freshness_seconds=180,
        timeout_seconds=90,
        request_timeout_seconds=3,
        delay_seconds=3,
        fetcher=fetch,
        monotonic=lambda: monotonic[0],
        wall_clock=lambda: NOW + timedelta(seconds=monotonic[0]),
        sleep=lambda seconds: monotonic.__setitem__(0, monotonic[0] + seconds),
    )
    assert_true(not evidence["missing_categories"], "fast empty responses stopped before next sample")
    assert_true(60 <= monotonic[0] <= 90, "poll did not use the real configured window")
    assert_true(all(0 < timeout <= 3 for _, timeout in calls), "request timeout was not capped")


def test_slow_poll_stays_within_deadline():
    monotonic = [0.0]
    timeouts = []

    def fetch(_collection, timeout):
        timeouts.append(timeout)
        monotonic[0] += timeout
        raise TransientTelemetryError("unreachable")

    evidence = poll_telemetry(
        system_id="system-safe",
        required_categories=["core", "disk", "containers"],
        freshness_seconds=180,
        timeout_seconds=0.05,
        request_timeout_seconds=0.02,
        delay_seconds=0.01,
        fetcher=fetch,
        monotonic=lambda: monotonic[0],
        wall_clock=lambda: NOW,
        sleep=lambda seconds: monotonic.__setitem__(0, monotonic[0] + seconds),
    )
    assert_true(evidence["missing_categories"], "unreachable collections unexpectedly verified")
    assert_true(monotonic[0] <= 0.05, "slow requests exceeded the global deadline")
    assert_true(all(timeout <= 0.02 for timeout in timeouts), "request exceeded configured cap")


if __name__ == "__main__":
    test_exact_record_shape()
    test_fast_empty_poll_reaches_next_sample()
    test_slow_poll_stays_within_deadline()
    print("Beszel telemetry production probe passed")
