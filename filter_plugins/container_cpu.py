"""Filters for deriving and verifying the managed container CPU policy."""

import importlib.util
from decimal import Decimal, InvalidOperation
from pathlib import Path

from ansible.errors import AnsibleFilterError


# Filter plugins cannot import module_utils/ by name, and putting the repository
# root on sys.path to reach it would shadow site-packages with library/, roles/,
# services/ and tests/ for the whole Ansible process. Loading the file by path
# shares the guards with no global side effect. tests/policy_test.rb executes
# every filter plugin and fails if one of them touches sys.path.
_GUARDS_SPEC = importlib.util.spec_from_file_location(
    "nas_platform_schema_guards",
    Path(__file__).resolve().parents[1] / "module_utils" / "schema_guards.py",
)
_GUARDS = importlib.util.module_from_spec(_GUARDS_SPEC)
_GUARDS_SPEC.loader.exec_module(_GUARDS)


NANOCPUS_PER_CPU = 1_000_000_000


def platform_container_cpuset(available_cpus, requested_budget, require_headroom):
    """Return a contiguous zero-based CPU set after validating host headroom."""
    available = _GUARDS.integer(available_cpus, "Docker CPU count")
    budget = _GUARDS.integer(requested_budget, "container CPU budget")
    if not isinstance(require_headroom, bool):
        raise AnsibleFilterError("container CPU headroom policy must be boolean")
    if available < 1:
        raise AnsibleFilterError("Docker must report at least one logical CPU")
    if budget < 0:
        raise AnsibleFilterError("container CPU budget cannot be negative")
    if budget == 0:
        if require_headroom:
            raise AnsibleFilterError("production container CPU budget must be explicit")
        budget = available
    if budget > available:
        raise AnsibleFilterError("container CPU budget exceeds Docker CPU capacity")
    if require_headroom and budget >= available:
        raise AnsibleFilterError("production container CPU budget leaves no host headroom")
    return "0" if budget == 1 else f"0-{budget - 1}"


def _expected_nanocpus(service, spec):
    try:
        cpus = Decimal(str(spec["cpus"]))
    except (KeyError, InvalidOperation, TypeError, ValueError) as error:
        raise AnsibleFilterError(f"{service}: Compose CPU quota is invalid") from error
    nanocpus = cpus * NANOCPUS_PER_CPU
    if cpus <= 0 or nanocpus != nanocpus.to_integral_value():
        raise AnsibleFilterError(f"{service}: Compose CPU quota is invalid")
    return int(nanocpus)


def platform_container_cpu_runtime_errors(
    compose_services, inspections, expected_services, expected_cpuset
):
    """Return non-secret drift messages for running Compose containers."""
    if not isinstance(compose_services, dict) or not compose_services:
        raise AnsibleFilterError("Compose CPU service policy must be a nonempty mapping")
    if not isinstance(inspections, list) or not inspections:
        raise AnsibleFilterError("runtime CPU inspection must contain managed containers")
    if (
        not isinstance(expected_services, list)
        or not expected_services
        or any(not isinstance(service, str) for service in expected_services)
        or len(set(expected_services)) != len(expected_services)
        or any(service not in compose_services for service in expected_services)
    ):
        raise AnsibleFilterError("expected CPU service selection is invalid")
    if not isinstance(expected_cpuset, str) or not expected_cpuset:
        raise AnsibleFilterError("effective container CPU set must be nonempty")

    errors = []
    seen = set()
    expected = set(expected_services)
    for inspection in inspections:
        if not isinstance(inspection, dict):
            raise AnsibleFilterError("runtime CPU inspection entry must be a mapping")
        service = inspection.get("Config", {}).get("Labels", {}).get(
            "com.docker.compose.service"
        )
        if not isinstance(service, str) or service not in expected or service in seen:
            raise AnsibleFilterError(
                "runtime CPU inspection has an unknown or duplicate service"
            )
        seen.add(service)
        expected_nano = _expected_nanocpus(service, compose_services[service])
        host_config = inspection.get("HostConfig", {})
        actual_set = host_config.get("CpusetCpus")
        actual_nano = host_config.get("NanoCpus")
        if actual_set != expected_cpuset:
            errors.append(
                f"{service}: effective CPU set is {actual_set}, expected {expected_cpuset}"
            )
        if actual_nano != expected_nano:
            errors.append(
                f"{service}: effective CPU quota is {actual_nano}, "
                f"expected {expected_nano} nanocpus"
            )
    for service in expected - seen:
        errors.append(f"{service}: no running container found")
    return sorted(errors)


class FilterModule:
    """Expose managed container CPU policy filters."""

    def filters(self):
        return {
            "platform_container_cpuset": platform_container_cpuset,
            "platform_container_cpu_runtime_errors": platform_container_cpu_runtime_errors,
        }
