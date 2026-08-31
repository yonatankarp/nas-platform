"""Strict type validation for the Jellyfin encoding profiles and policy.

`roles/jellyfin/tasks/main.yml` spelled this out as forty-five Jinja conditions
inside one assert: the same thirteen-field table repeated for
`jellyfin_encoding_policy`, for `jellyfin_encoding_profiles.nas` and for
`jellyfin_encoding_profiles.mac`. Forty-five conditions under one `fail_msg`
naming four unrelated causes reported nothing about which field was wrong.

**This is not something `meta/argument_specs.yml` can express, and the
declaration there does not replace it.** `jellyfin_encoding_policy` is declared
with typed suboptions, but `ArgumentSpecValidator` *coerces*: `type: bool` turns
`1` into `True` and reports no error, and `elements: str` turns `1` into `"1"`.
The value-equality tamper-pin that follows in the same assert cannot catch that
either, because Python compares `1 == True` as true. Only a strict predicate
rejects a numeric boolean, which is exactly the regression
`tests/media_probes_jellyfin_settings.rb` plants as "numeric NAS hardware
boolean". The guards below use `is_boolean`, which rejects `1`, so the
declaration and this filter are complementary rather than redundant: the
declaration refuses a malformed shape at role entry and names the option, this
refuses a mistyped field and names the path.

Extra keys are accepted, deliberately. The original conditions never enumerated
a profile's keys; the value-equality assertions that remain in the task pin the
two shipped profiles exactly, so a key added here would have to be added there
too. Field names and the two profile names are literals from this repository and
from Jellyfin's own configuration API, never vault data, so a path is safe to
print; no value is ever put in a message.
"""

import importlib.util
from pathlib import Path


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


BOOLEAN = "boolean"
STRING = "string"
STRING_LIST = "string_list"

# Every key Jellyfin's encoding configuration carries under this platform's
# control, with the type the role posts it as. All of them are required: the
# conditions this replaces read the field unguarded, so an absent key was
# Undefined and already a rejection.
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

# The platforms a profile has to exist for, independent of which one this host
# selects: the task pins both, so a Mac run still refuses a broken NAS profile.
REQUIRED_PROFILES = ("nas", "mac")

PROFILES_LABEL = "jellyfin_encoding_profiles"
POLICY_LABEL = "jellyfin_encoding_policy"


def _field(errors, path, value, kind):
    if kind is BOOLEAN:
        if not _GUARDS.is_boolean(value):
            errors.append(f"{path}: must be a boolean")
    elif kind is STRING:
        if not _GUARDS.is_string(value):
            errors.append(f"{path}: must be a string")
    elif kind is STRING_LIST:
        if not _GUARDS.is_list(value):
            errors.append(f"{path}: must be a list")
            return
        for index, element in enumerate(value):
            if not _GUARDS.is_string(element):
                errors.append(f"{path}[{index}]: must be a string")


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
