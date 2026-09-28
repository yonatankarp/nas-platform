#!/usr/bin/env python3
"""Prove the argument specs for filter-plugin inputs, via ArgumentSpecValidator.

Each declaration must reject real malformations and accept what the role ships.
"""

import pathlib
import sys

import yaml
from ansible.module_utils.common.arg_spec import ArgumentSpecValidator


ROOT = pathlib.Path(__file__).resolve().parents[1]

failures: list[str] = []


def check(condition, message):
    if not condition:
        failures.append(message)


def load(path):
    return yaml.safe_load((ROOT / path).read_text())


def options_of(role):
    spec = load(f"roles/{role}/meta/argument_specs.yml")
    return spec["argument_specs"]["main"]["options"]


def errors_for(role, option, value):
    """Validate one option in isolation, as its own single-option spec."""
    result = ArgumentSpecValidator({option: options_of(role)[option]}).validate(
        {option: value}
    )
    return list(result.error_messages)


def accepts(role, option, value, label):
    errors = errors_for(role, option, value)
    check(not errors, f"{role}: {label} must validate, got {errors}")


def rejects(role, option, value, label, *, naming):
    errors = errors_for(role, option, value)
    check(errors, f"{role}: {label} must be refused by {option}")
    check(
        any(naming in message for message in errors),
        f"{role}: refusal of {label} must name {naming!r}, got {errors}",
    )


arr_defaults = load("roles/arr/defaults/main.yml")
jellyfin_defaults = load("roles/jellyfin/defaults/main.yml")

# Without this the file passes vacuously once a declaration is dropped.
for role, option in [
    ("arr", "arr_servarr_instances"),
    ("arr", "arr_prowlarr_applications"),
    ("jellyfin", "jellyfin_retired_plugin_repository_urls"),
    ("jellyfin", "jellyfin_encoding_policy"),
]:
    check(
        option in options_of(role),
        f"{role}: {option} is fed to a filter and must be declared",
    )

# --- what the roles actually ship -----------------------------------------
# Defaults are read raw; their Jinja templates to strings at role entry too.
instances = arr_defaults["arr_servarr_instances"]
applications = arr_defaults["arr_prowlarr_applications"]
accepts("arr", "arr_servarr_instances", instances, "the shipped Servarr instances")
accepts(
    "arr",
    "arr_prowlarr_applications",
    applications,
    "the shipped Prowlarr applications",
)
accepts(
    "jellyfin",
    "jellyfin_retired_plugin_repository_urls",
    jellyfin_defaults["jellyfin_retired_plugin_repository_urls"],
    "the shipped retired repository URLs",
)

# jellyfin_encoding_policy selects a profile by platform_kind; both must pass.
profiles = jellyfin_defaults["jellyfin_encoding_profiles"]
check(
    isinstance(jellyfin_defaults["jellyfin_encoding_policy"], str),
    "jellyfin_encoding_policy is expected to be a template selecting a profile",
)
for name, profile in profiles.items():
    accepts(
        "jellyfin",
        "jellyfin_encoding_policy",
        profile,
        f"the {name} encoding profile",
    )

# The filter's optional fields are optional: neither declaration ships tags or
# implementation_name, and adding them must stay legal.
accepts(
    "arr",
    "arr_servarr_instances",
    [{**instances[0], "tags": [3, 9]}],
    "a Servarr instance carrying tags",
)
accepts(
    "arr",
    "arr_prowlarr_applications",
    [{**applications[0], "implementation_name": "Radarr", "tags": [2, 8]}],
    "a Prowlarr application carrying implementation_name and tags",
)

# --- what a malformed declaration now costs -------------------------------
rejects(
    "arr",
    "arr_servarr_instances",
    [{key: value for key, value in instances[0].items() if key != "category"}],
    "a Servarr instance missing category",
    naming="category",
)
rejects(
    "arr",
    "arr_servarr_instances",
    instances[0],
    "a bare mapping where the instance list belongs",
    naming="arr_servarr_instances",
)
rejects(
    "arr",
    "arr_servarr_instances",
    [{**instances[0], "root_folders": "/data/media/Movies"}],
    "a Servarr instance with a misspelled root_folder",
    naming="root_folders",
)
rejects(
    "arr",
    "arr_prowlarr_applications",
    [{key: value for key, value in applications[0].items() if key != "base_url"}],
    "a Prowlarr application missing base_url",
    naming="base_url",
)
rejects(
    "arr",
    "arr_prowlarr_applications",
    [{**applications[0], "sync_categories": ["movies"]}],
    "a Prowlarr application whose sync categories are not integers",
    naming="sync_categories",
)
rejects(
    "arr",
    "arr_prowlarr_applications",
    [{**applications[0], "syncCategories": [2000]}],
    "a Prowlarr application declared in the API's own spelling",
    naming="syncCategories",
)
rejects(
    "jellyfin",
    "jellyfin_encoding_policy",
    {**profiles["nas"], "HardwareDecodingCodec": "h264"},
    "an encoding policy with a key Jellyfin does not take",
    naming="HardwareDecodingCodec",
)
rejects(
    "jellyfin",
    "jellyfin_encoding_policy",
    [profiles["nas"]],
    "an encoding policy wrapped in a list",
    naming="jellyfin_encoding_policy",
)

if failures:
    for failure in failures:
        print(f"FAIL: {failure}", file=sys.stderr)
    raise SystemExit(f"{len(failures)} filter input argument spec failures")

print("Filter input argument specs passed")
