"""Strict type validation for the Jellyfin encoding profiles and policy.

argument_specs coerces (1 -> True, 1 -> "1"), so only a strict predicate rejects a
numeric boolean; the two are complementary. Extra keys are accepted: the task pins the
shipped profiles by value. Paths name only repository literals, never a value.
"""

import runpy
from pathlib import Path
from types import SimpleNamespace

from ansible.errors import AnsibleFilterError


# module_utils/ is run by file path, never via sys.path: tests/policy_test.rb
# says why, and fails any filter plugin that touches it.
_MODULE_UTILS = Path(__file__).resolve().parents[1] / "module_utils"
_GUARDS = SimpleNamespace(**runpy.run_path(str(_MODULE_UTILS / "schema_guards.py")))


BOOLEAN = "boolean"
STRING = "string"
STRING_LIST = "string_list"

# Every key this platform writes, at the type the role posts it; all required.
FIELDS = {
    "HardwareAccelerationType": STRING,
    # Empty on the Mac profile, so a string and not a path.
    "QsvDevice": STRING,
    "HardwareDecodingCodecs": STRING_LIST,
    "EnableDecodingColorDepth10Hevc": BOOLEAN,
    "EnableDecodingColorDepth10Vp9": BOOLEAN,
    "EnableHardwareEncoding": BOOLEAN,
    "AllowHevcEncoding": BOOLEAN,
    "AllowAv1Encoding": BOOLEAN,
    "EnableIntelLowPowerH264HwEncoder": BOOLEAN,
    "EnableIntelLowPowerHevcHwEncoder": BOOLEAN,
    "EnableVppTonemapping": BOOLEAN,
    "EnableTonemapping": BOOLEAN,
}

# Both platforms are checked, so a Mac run still refuses a broken NAS profile.
REQUIRED_PROFILES = ("nas", "mac")

PROFILES_LABEL = "jellyfin_encoding_profiles"
POLICY_LABEL = "jellyfin_encoding_policy"


def _field(errors, path, value, kind):
    # `==` not `is`, and an unknown kind raises rather than validating nothing (#648).
    if kind == BOOLEAN:
        if not _GUARDS.is_boolean(value):
            errors.append(f"{path}: must be a boolean")
    elif kind == STRING:
        if not _GUARDS.is_string(value):
            errors.append(f"{path}: must be a string")
    elif kind == STRING_LIST:
        if not _GUARDS.is_list(value):
            errors.append(f"{path}: must be a list")
            return
        for index, element in enumerate(value):
            if not _GUARDS.is_string(element):
                errors.append(f"{path}[{index}]: must be a string")
    else:
        # Safe to name: every kind here is a literal from FIELDS.
        raise AnsibleFilterError(f"{path}: unknown field kind {kind!r}")


def _encoding(errors, label, value):
    """Validate one encoding mapping, whether it is a profile or the policy."""
    if not _GUARDS.is_mapping(value):
        errors.append(f"{label}: must be a mapping")
        return
    for field, kind in FIELDS.items():
        path = f"{label}.{field}"
        if field not in value:
            errors.append(f"{path}: is missing")
            continue
        _field(errors, path, value[field], kind)


def jellyfin_encoding_errors(profiles, policy):
    """Return every Jellyfin encoding type violation, as field paths.

    Never includes a value, so the result is safe to print from a `fail_msg`. An
    empty list means both pinned profiles and the effective policy carry every
    field this platform writes, at the exact type it writes it. Which profile the
    policy has to equal is a value question, asserted separately in the task.
    """
    errors = []
    if not _GUARDS.is_mapping(profiles):
        errors.append(f"{PROFILES_LABEL}: must be a mapping")
    else:
        for name in REQUIRED_PROFILES:
            label = f"{PROFILES_LABEL}.{name}"
            if name not in profiles:
                errors.append(f"{label}: is missing")
                continue
            _encoding(errors, label, profiles[name])

    _encoding(errors, POLICY_LABEL, policy)
    return errors


class FilterModule:
    """Expose the Jellyfin encoding schema validator to Ansible."""

    def filters(self):
        return {"jellyfin_encoding_errors": jellyfin_encoding_errors}
