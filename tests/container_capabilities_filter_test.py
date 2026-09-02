#!/usr/bin/env python3
"""Behavior tests for the applied container capability verification filter."""

import importlib.util
import pathlib

from ansible.errors import AnsibleFilterError


ROOT = pathlib.Path(__file__).resolve().parents[1]
PLUGIN_PATH = ROOT / "filter_plugins" / "container_capabilities.py"


def load_plugin():
    spec = importlib.util.spec_from_file_location("container_capabilities", PLUGIN_PATH)
    if spec is None or spec.loader is None:
        raise AssertionError("container capability filter cannot be imported")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def require_rejected(function, *arguments):
    try:
        function(*arguments)
    except AnsibleFilterError:
        return
    raise AssertionError(f"accepted invalid capability policy: {arguments!r}")


plugin = load_plugin()
verify = plugin.platform_container_capability_runtime_errors


def inspection(service, drop=None, add=None):
    return {
        "Config": {"Labels": {"com.docker.compose.service": service}},
        "HostConfig": {"CapDrop": drop, "CapAdd": add},
    }


# A container that declares the drop and got it, beside one that declares
# nothing and got nothing. Both are converged.
compose_services = {
    "app": {"cap_drop": ["ALL"]},
    "legacy": {},
}
applied = [inspection("app", drop=["ALL"]), inspection("legacy")]
assert verify(compose_services, applied, ["app", "legacy"]) == []

# The failure this check exists for: the key is in the Compose file but the
# running container predates it, so Docker applied nothing.
stale = [inspection("app"), inspection("legacy")]
assert verify(compose_services, stale, ["app", "legacy"]) == [
    "app: applied dropped capabilities are none, declared ALL",
]

# The reverse drift, a container dropping capabilities its definition does not
# ask for. Rarer, but it means the deployed definition is not the one on disk.
undeclared = [inspection("app", drop=["ALL"]), inspection("legacy", drop=["CHOWN"])]
assert verify(compose_services, undeclared, ["app", "legacy"]) == [
    "legacy: applied dropped capabilities are CHOWN, declared none",
]

# Docker echoes back whatever spelling the Compose file used, so CAP_PERFMON and
# PERFMON are the same capability and must not read as drift. beszel/agent-intel
# declares the prefixed spelling, so this is the platform's live case.
prefixed = {"agent": {"cap_drop": ["ALL"], "cap_add": ["CAP_PERFMON"]}}
assert verify(prefixed, [inspection("agent", drop=["all"], add=["PERFMON"])], ["agent"]) == []

# An add-back that was declared and not applied, and one applied but never
# declared. Both are reported, and both name only capabilities.
add_back = {"agent": {"cap_drop": ["ALL"], "cap_add": ["PERFMON"]}}
assert verify(add_back, [inspection("agent", drop=["ALL"])], ["agent"]) == [
    "agent: applied added capabilities are none, declared PERFMON",
]
assert verify(
    {"agent": {"cap_drop": ["ALL"]}},
    [inspection("agent", drop=["ALL"], add=["SYS_ADMIN"])],
    ["agent"],
) == ["agent: applied added capabilities are SYS_ADMIN, declared none"]

# Order is not drift; a set comparison, not a list comparison.
multi = {"agent": {"cap_drop": ["CHOWN", "SETUID"]}}
assert verify(multi, [inspection("agent", drop=["SETUID", "CHOWN"])], ["agent"]) == []

# A container that should be running and is not. The CPU filter reports this
# the same way, and it is how a stack that failed to start is caught.
assert verify(compose_services, applied[:1], ["app", "legacy"]) == [
    "legacy: no running container found",
]

# Several drifting containers are all reported, sorted, rather than the first
# one found. A check that stops at the first failure hides the rest.
both = {"app": {"cap_drop": ["ALL"]}, "legacy": {"cap_drop": ["ALL"]}}
assert verify(both, [inspection("app"), inspection("legacy")], ["app", "legacy"]) == [
    "app: applied dropped capabilities are none, declared ALL",
    "legacy: applied dropped capabilities are none, declared ALL",
]

# No message may carry anything from the inspection, which holds the rendered
# .env and therefore every credential the stack has.
secret = "s3cret-token"
leaky = [
    {
        "Config": {
            "Labels": {"com.docker.compose.service": "app"},
            "Env": [f"API_KEY={secret}"],
        },
        "HostConfig": {"CapDrop": None, "Binds": [f"/run/{secret}:/x"]},
    },
]
messages = verify({"app": {"cap_drop": ["ALL"]}}, leaky, ["app"])
assert messages == ["app: applied dropped capabilities are none, declared ALL"]
assert all(secret not in message for message in messages)

# Malformed inputs must raise rather than silently return "no drift", which
# would turn a broken check into a passing one.
require_rejected(verify, {}, applied, ["app"])
require_rejected(verify, compose_services, [], ["app"])
require_rejected(verify, compose_services, applied, [])
require_rejected(verify, compose_services, applied, ["unknown"])
require_rejected(verify, compose_services, applied, ["app", "app"])
require_rejected(verify, compose_services, ["not-a-mapping"], ["app"])
require_rejected(verify, {"app": "not-a-mapping"}, [inspection("app")], ["app"])
require_rejected(verify, {"app": {"cap_drop": "ALL"}}, [inspection("app")], ["app"])
require_rejected(verify, {"app": {"cap_drop": [""]}}, [inspection("app")], ["app"])
require_rejected(verify, {"app": {"cap_drop": [7]}}, [inspection("app")], ["app"])
require_rejected(
    verify,
    {"app": {"cap_drop": ["ALL"]}},
    [{"Config": {"Labels": {"com.docker.compose.service": "app"}}, "HostConfig": "x"}],
    ["app"],
)
# An inspection whose service label is missing entirely, which is what a
# container started outside Compose would look like.
require_rejected(
    verify, compose_services, [{"Config": {"Labels": {}}, "HostConfig": {}}], ["app"]
)

print("Container capability verification behavior passed")
