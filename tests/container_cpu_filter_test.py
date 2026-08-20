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

print("Container CPU-set derivation behavior passed")
