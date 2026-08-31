#!/usr/bin/env python3
"""Contract tests for the Jellyfin encoding schema filter.

Every rejection here corresponds to one of the forty-five field-type conditions
`roles/jellyfin/tasks/main.yml` repeated for the effective policy and for each of
the two pinned profiles, before they moved into
`filter_plugins/jellyfin_encoding_schema.py`.

`test_the_declaration_cannot_replace_this_filter` is the one that decides whether
the filter has to exist at all. `meta/argument_specs.yml` declares
`jellyfin_encoding_policy` with typed suboptions, and it is tempting to conclude
the conditions are therefore redundant. They are not:
`ArgumentSpecValidator` coerces `1` to `True` and reports nothing, and the
value-equality tamper-pin that follows in the same assert cannot see the
difference either, because Python compares `1 == True` as true. That test asserts
the coercion directly, so a future reader does not have to take the claim on
trust — and `tests/media_probes_jellyfin_settings.rb` plants exactly that
regression end to end.

The table is checked against `roles/jellyfin/defaults/main.yml` rather than
restated, so a profile that gains a key the filter does not know about fails here
instead of being written to Jellyfin unvalidated.
"""

import copy
from pathlib import Path
import sys
import unittest

import yaml
from ansible.module_utils.common.arg_spec import ArgumentSpecValidator

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "filter_plugins"))

from jellyfin_encoding_schema import (  # noqa: E402
    BOOLEAN,
    FIELDS,
    REQUIRED_PROFILES,
    STRING,
    STRING_LIST,
    jellyfin_encoding_errors,
)

DEFAULTS = yaml.safe_load((ROOT / "roles" / "jellyfin" / "defaults" / "main.yml").read_text())
PROFILES = DEFAULTS["jellyfin_encoding_profiles"]
# jellyfin_encoding_policy in defaults/main.yml is a template that selects one of
# these by platform_kind; on a Mac host and in the integration lane it is the Mac
# profile, which is what the role hands this filter.
POLICY = PROFILES["mac"]

WRONG = {
    BOOLEAN: 1,
    STRING: None,
    STRING_LIST: "h264",
}


def with_profile(name, field, value):
    profiles = copy.deepcopy(PROFILES)
    profiles[name][field] = value
    return profiles


class JellyfinEncodingSchemaTest(unittest.TestCase):
    def test_accepts_the_shipped_profiles_and_every_selection(self):
        for name in REQUIRED_PROFILES:
            with self.subTest(policy=name):
                self.assertEqual(jellyfin_encoding_errors(PROFILES, PROFILES[name]), [])

    def test_refuses_profiles_that_are_not_a_mapping(self):
        for value in (None, [], "nas", 5):
            with self.subTest(value=type(value).__name__):
                self.assertEqual(
                    jellyfin_encoding_errors(value, POLICY),
                    ["jellyfin_encoding_profiles: must be a mapping"])

    def test_refuses_a_missing_platform_profile_by_name(self):
        for name in REQUIRED_PROFILES:
            profiles = copy.deepcopy(PROFILES)
            del profiles[name]
            with self.subTest(profile=name):
                self.assertEqual(
                    jellyfin_encoding_errors(profiles, POLICY),
                    [f"jellyfin_encoding_profiles.{name}: is missing"])

    def test_refuses_a_profile_that_is_not_a_mapping(self):
        profiles = copy.deepcopy(PROFILES)
        profiles["nas"] = "qsv"
        self.assertEqual(jellyfin_encoding_errors(profiles, POLICY),
                         ["jellyfin_encoding_profiles.nas: must be a mapping"])

    def test_refuses_a_policy_that_is_not_a_mapping(self):
        self.assertEqual(jellyfin_encoding_errors(PROFILES, ["qsv"]),
                         ["jellyfin_encoding_policy: must be a mapping"])

    def test_refuses_a_missing_field_by_path(self):
        for name in REQUIRED_PROFILES:
            for field in FIELDS:
                profiles = copy.deepcopy(PROFILES)
                del profiles[name][field]
                with self.subTest(profile=name, field=field):
                    self.assertEqual(
                        jellyfin_encoding_errors(profiles, POLICY),
                        [f"jellyfin_encoding_profiles.{name}.{field}: is missing"])

    def test_refuses_a_mistyped_field_by_path(self):
        for name in REQUIRED_PROFILES:
            for field, kind in FIELDS.items():
                profiles = with_profile(name, field, WRONG[kind])
                path = f"jellyfin_encoding_profiles.{name}.{field}"
                with self.subTest(profile=name, field=field, kind=kind):
                    found = jellyfin_encoding_errors(profiles, POLICY)
                    self.assertEqual(len(found), 1, found)
                    self.assertTrue(found[0].startswith(f"{path}: "), found)

    def test_refuses_a_mistyped_effective_policy_by_path(self):
        for field, kind in FIELDS.items():
            policy = copy.deepcopy(POLICY)
            policy[field] = WRONG[kind]
            with self.subTest(field=field, kind=kind):
                found = jellyfin_encoding_errors(PROFILES, policy)
                self.assertEqual(len(found), 1, found)
                self.assertTrue(
                    found[0].startswith(f"jellyfin_encoding_policy.{field}: "), found)

    def test_reports_the_type_a_field_must_have(self):
        self.assertEqual(
            jellyfin_encoding_errors(with_profile("nas", "EnableHardwareEncoding", 1), POLICY),
            ["jellyfin_encoding_profiles.nas.EnableHardwareEncoding: must be a boolean"])
        self.assertEqual(
            jellyfin_encoding_errors(with_profile("nas", "QsvDevice", 128), POLICY),
            ["jellyfin_encoding_profiles.nas.QsvDevice: must be a string"])
        self.assertEqual(
            jellyfin_encoding_errors(
                with_profile("nas", "HardwareDecodingCodecs", "h264,hevc"), POLICY),
            ["jellyfin_encoding_profiles.nas.HardwareDecodingCodecs: must be a list"])

    def test_names_the_offending_codec_by_position(self):
        profiles = with_profile("nas", "HardwareDecodingCodecs", ["h264", 265, "vp9"])
        self.assertEqual(
            jellyfin_encoding_errors(profiles, POLICY),
            ["jellyfin_encoding_profiles.nas.HardwareDecodingCodecs[1]: must be a string"])

    def test_refuses_a_numeric_boolean_a_value_comparison_cannot_see(self):
        """`1 == True` in Python, so the tamper-pin alone would accept this."""
        self.assertEqual(with_profile("mac", "EnableHardwareEncoding", 0)["mac"],
                         PROFILES["mac"])
        self.assertTrue(
            jellyfin_encoding_errors(with_profile("mac", "EnableHardwareEncoding", 0), POLICY))

    def test_the_declaration_cannot_replace_this_filter(self):
        """argument_specs coerces a numeric boolean; the filter refuses it."""
        spec = yaml.safe_load(
            (ROOT / "roles" / "jellyfin" / "meta" / "argument_specs.yml").read_text()
        )["argument_specs"]["main"]["options"]["jellyfin_encoding_policy"]
        policy = copy.deepcopy(POLICY)
        policy["EnableHardwareEncoding"] = 1
        result = ArgumentSpecValidator({"jellyfin_encoding_policy": spec}).validate(
            {"jellyfin_encoding_policy": policy})
        self.assertEqual(list(result.error_messages), [])
        self.assertEqual(jellyfin_encoding_errors(PROFILES, policy),
                         ["jellyfin_encoding_policy.EnableHardwareEncoding: must be a boolean"])

    def test_accepts_a_key_the_platform_does_not_declare(self):
        """Extra keys were never enumerated; the value pins in the task are."""
        profiles = with_profile("nas", "EnableAudioVbr", True)
        self.assertEqual(jellyfin_encoding_errors(profiles, POLICY), [])

    def test_reports_every_violation_rather_than_the_first(self):
        profiles = copy.deepcopy(PROFILES)
        profiles["nas"]["EnableHardwareEncoding"] = 1
        del profiles["mac"]["QsvDevice"]
        policy = copy.deepcopy(POLICY)
        policy["HardwareDecodingCodecs"] = [None]
        self.assertEqual(jellyfin_encoding_errors(profiles, policy), [
            "jellyfin_encoding_profiles.nas.EnableHardwareEncoding: must be a boolean",
            "jellyfin_encoding_profiles.mac.QsvDevice: is missing",
            "jellyfin_encoding_policy.HardwareDecodingCodecs[0]: must be a string",
        ])

    def test_never_discloses_a_value(self):
        sentinel = "jellyfin-encoding-sentinel"
        profiles = with_profile("nas", "EnableHardwareEncoding", sentinel)
        profiles["nas"][sentinel] = sentinel
        found = jellyfin_encoding_errors(profiles, POLICY)
        self.assertTrue(found)
        self.assertNotIn(sentinel, " ".join(found))

    def test_the_table_covers_exactly_what_the_role_ships(self):
        self.assertEqual(sorted(REQUIRED_PROFILES), sorted(PROFILES))
        for name in REQUIRED_PROFILES:
            self.assertEqual(sorted(PROFILES[name]), sorted(FIELDS), name)


if __name__ == "__main__":
    unittest.main(verbosity=2)
