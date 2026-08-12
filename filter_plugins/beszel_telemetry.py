"""Ansible filter wrappers for Beszel persisted telemetry evidence."""

from pathlib import Path
import sys


sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from module_utils.beszel_telemetry import evaluate_telemetry


def beszel_latest_telemetry_record(response):
    if not isinstance(response, dict):
        return {}
    payload = response.get("json")
    if not isinstance(payload, dict):
        return {}
    items = payload.get("items")
    if not isinstance(items, list) or not items or not isinstance(items[0], dict):
        return {}
    return items[0]


def beszel_telemetry_evidence(
    system_id,
    system_record,
    container_record,
    required_categories,
    freshness_seconds,
):
    return evaluate_telemetry(
        system_id,
        system_record,
        container_record,
        required_categories,
        freshness_seconds,
    )


class FilterModule:
    def filters(self):
        return {
            "beszel_latest_telemetry_record": beszel_latest_telemetry_record,
            "beszel_telemetry_evidence": beszel_telemetry_evidence,
        }
