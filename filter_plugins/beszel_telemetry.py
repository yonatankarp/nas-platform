"""Ansible filter wrappers for Beszel persisted telemetry evidence."""

import importlib.util
from pathlib import Path


# Filter plugins cannot import module_utils/ by name, and putting the repo root
# on sys.path to reach it would shadow site-packages with library/, roles/,
# services/ and tests/ for the whole Ansible process. Loading the file by path
# imports the same evaluator with no global side effect.
_TELEMETRY_SPEC = importlib.util.spec_from_file_location(
    "nas_platform_beszel_telemetry",
    Path(__file__).resolve().parents[1] / "module_utils" / "beszel_telemetry.py",
)
_TELEMETRY = importlib.util.module_from_spec(_TELEMETRY_SPEC)
_TELEMETRY_SPEC.loader.exec_module(_TELEMETRY)
evaluate_telemetry = _TELEMETRY.evaluate_telemetry


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
