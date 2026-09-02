"""Filters for verifying the capability policy Docker actually applied.

The Compose file is the declaration; this is the check that the declaration
reached the daemon. The two can disagree without anything else noticing: a
container left running from before the key was added keeps the capability set
it started with, and `docker compose up` will not recreate it if nothing else
about its definition changed.

Deliberately a drift check and not a policy check. The expectation is read out
of the deployed Compose file rather than from a list pinned here, so this stays
correct as later tranches add their keys without needing a second list to keep
in agreement with tests/policy_test.rb. Which containers *must* declare the key
is that file's question; whether what they declare took effect is this one's.

Scope worth being honest about: HostConfig records what Docker was asked for,
which is not the same as what the kernel ended up applying. Reading CapBnd out
of /proc/1/status would prove the outcome, but it needs a shell inside the
container and the platform runs a distroless image (bindery) that has none.
So this catches a container running without the drop it declares, and does not
claim to be a kernel-level proof.
"""

from ansible.errors import AnsibleFilterError


def _normalize(capabilities, label):
    """Return a comparable capability set, tolerating Docker's CAP_ prefix."""
    if capabilities is None:
        return frozenset()
    if not isinstance(capabilities, list) or any(
        not isinstance(entry, str) or not entry for entry in capabilities
    ):
        raise AnsibleFilterError(f"{label} must be a list of capability names")
    return frozenset(entry.upper().removeprefix("CAP_") for entry in capabilities)


def _render(capabilities):
    return ",".join(sorted(capabilities)) if capabilities else "none"


def platform_container_capability_runtime_errors(
    compose_services, inspections, expected_services
):
    """Return non-secret drift messages comparing declared and applied capabilities.

    Every message names only the Compose service and capability names. The
    inspection entries carry each container's Env array, which is the rendered
    .env and therefore every credential the stack holds, so nothing from an
    inspection is ever interpolated into a message.
    """
    if not isinstance(compose_services, dict) or not compose_services:
        raise AnsibleFilterError(
            "Compose capability service policy must be a nonempty mapping"
        )
    if not isinstance(inspections, list) or not inspections:
        raise AnsibleFilterError(
            "runtime capability inspection must contain managed containers"
        )
    if (
        not isinstance(expected_services, list)
        or not expected_services
        or any(not isinstance(service, str) for service in expected_services)
        or len(set(expected_services)) != len(expected_services)
        or any(service not in compose_services for service in expected_services)
    ):
        raise AnsibleFilterError("expected capability service selection is invalid")

    errors = []
    seen = set()
    expected = set(expected_services)
    for inspection in inspections:
        if not isinstance(inspection, dict):
            raise AnsibleFilterError(
                "runtime capability inspection entry must be a mapping"
            )
        service = (
            inspection.get("Config", {}).get("Labels", {}).get("com.docker.compose.service")
        )
        if not isinstance(service, str) or service not in expected or service in seen:
            raise AnsibleFilterError(
                "runtime capability inspection has an unknown or duplicate service"
            )
        seen.add(service)
        spec = compose_services[service]
        if not isinstance(spec, dict):
            raise AnsibleFilterError(f"{service}: Compose capability policy is invalid")
        declared_drop = _normalize(spec.get("cap_drop"), f"{service}: cap_drop")
        declared_add = _normalize(spec.get("cap_add"), f"{service}: cap_add")
        host_config = inspection.get("HostConfig", {})
        if not isinstance(host_config, dict):
            raise AnsibleFilterError(f"{service}: runtime inspection has no HostConfig")
        applied_drop = _normalize(host_config.get("CapDrop"), f"{service}: applied CapDrop")
        applied_add = _normalize(host_config.get("CapAdd"), f"{service}: applied CapAdd")
        if applied_drop != declared_drop:
            errors.append(
                f"{service}: applied dropped capabilities are {_render(applied_drop)}, "
                f"declared {_render(declared_drop)}"
            )
        if applied_add != declared_add:
            errors.append(
                f"{service}: applied added capabilities are {_render(applied_add)}, "
                f"declared {_render(declared_add)}"
            )
    for service in expected - seen:
        errors.append(f"{service}: no running container found")
    return sorted(errors)


class FilterModule:
    """Expose the applied container capability verification filter."""

    def filters(self):
        return {
            "platform_container_capability_runtime_errors": (
                platform_container_capability_runtime_errors
            ),
        }
