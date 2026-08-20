#!/usr/bin/env python3
"""Behavior tests for container CPU policy filters."""

import importlib.util
import pathlib

from ansible.errors import AnsibleFilterError


ROOT = pathlib.Path(__file__).resolve().parents[1]
PLUGIN_PATH = ROOT / "filter_plugins" / "container_cpu.py"


def load_plugin():
    spec = importlib.util.spec_from_file_location("container_cpu", PLUGIN_PATH)
    if spec is None or spec.loader is None:
        raise AssertionError("container CPU filter cannot be imported")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def require_rejected(function, *arguments):
    try:
        function(*arguments)
    except AnsibleFilterError:
        return
    raise AssertionError(f"accepted invalid CPU policy: {arguments!r}")


plugin = load_plugin()
derive = plugin.platform_container_cpuset

assert derive(4, 3, True) == "0-2"
assert derive(1, 0, False) == "0"
assert derive(6, 0, False) == "0-5"
assert derive(8, 3, True) == "0-2"

for arguments in [
    (True, 3, True),
    (4, False, True),
    (4, 3, "yes"),
    (0, 0, False),
    (4, -1, False),
    (4, 5, False),
    (4, 4, True),
    (4, 0, True),
]:
    require_rejected(derive, *arguments)

verify_runtime = plugin.platform_container_cpu_runtime_errors
compose_services = {
    "server": {"cpuset": "0-2", "cpus": 3.0},
    "worker": {"cpuset": "0-2", "cpus": 1.5},
}
inspections = [
    {
        "Config": {"Labels": {"com.docker.compose.service": "server"}},
        "HostConfig": {"CpusetCpus": "0-2", "NanoCpus": 3_000_000_000},
    },
    {
        "Config": {"Labels": {"com.docker.compose.service": "worker"}},
        "HostConfig": {"CpusetCpus": "0-2", "NanoCpus": 1_500_000_000},
    },
]
assert verify_runtime(compose_services, inspections, "0-2") == []

drifted = [dict(inspections[0]), dict(inspections[1])]
drifted[1] = {
    "Config": inspections[1]["Config"],
    "HostConfig": {"CpusetCpus": "0-3", "NanoCpus": 0},
}
errors = verify_runtime(compose_services, drifted, "0-2")
assert errors == [
    "worker: effective CPU quota is 0, expected 1500000000 nanocpus",
    "worker: effective CPU set is 0-3, expected 0-2",
]

require_rejected(verify_runtime, [], inspections, "0-2")
require_rejected(verify_runtime, compose_services, [], "0-2")
require_rejected(verify_runtime, compose_services, inspections, "")

print("Container CPU-set derivation behavior passed")
