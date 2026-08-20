"""Filters for deriving and verifying the managed container CPU policy."""

from decimal import Decimal, InvalidOperation

from ansible.errors import AnsibleFilterError


NANOCPUS_PER_CPU = 1_000_000_000


def _require_integer(value, label):
    if isinstance(value, bool) or not isinstance(value, int):
        raise AnsibleFilterError(f"{label} must be an integer")
    return value


def platform_container_cpuset(available_cpus, requested_budget, require_headroom):
    """Return a contiguous zero-based CPU set after validating host headroom."""
    available = _require_integer(available_cpus, "Docker CPU count")
    budget = _require_integer(requested_budget, "container CPU budget")
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


def platform_container_cpu_runtime_errors(compose_services, inspections, expected_cpuset):
    """Return non-secret drift messages for running Compose containers."""
    if not isinstance(compose_services, dict) or not compose_services:
        raise AnsibleFilterError("Compose CPU service policy must be a nonempty mapping")
    if not isinstance(inspections, list) or not inspections:
        raise AnsibleFilterError("runtime CPU inspection must contain managed containers")
    if not isinstance(expected_cpuset, str) or not expected_cpuset:
        raise AnsibleFilterError("effective container CPU set must be nonempty")

    errors = []
    seen = set()
    for inspection in inspections:
        if not isinstance(inspection, dict):
            raise AnsibleFilterError("runtime CPU inspection entry must be a mapping")
        service = inspection.get("Config", {}).get("Labels", {}).get(
            "com.docker.compose.service"
        )
        if not isinstance(service, str) or service not in compose_services or service in seen:
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
    return sorted(errors)


class FilterModule:
    """Expose managed container CPU policy filters."""

    def filters(self):
        return {
            "platform_container_cpuset": platform_container_cpuset,
            "platform_container_cpu_runtime_errors": platform_container_cpu_runtime_errors,
        }
