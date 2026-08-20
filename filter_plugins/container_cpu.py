"""Filters for deriving and verifying the managed container CPU policy."""

from ansible.errors import AnsibleFilterError


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


class FilterModule:
    """Expose managed container CPU policy filters."""

    def filters(self):
        return {"platform_container_cpuset": platform_container_cpuset}
