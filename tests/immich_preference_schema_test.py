#!/usr/bin/env python3
"""Contract tests for the Immich managed-user preference schema filter.

Every rejection case here corresponds to a condition the two Immich `assert`
tasks in `roles/vault_contract/tasks/main.yml` carried before the schema moved
into `filter_plugins/immich_preference_schema.py`.

The redaction tests are the ones that matter most. The collections are keyed by
managed-user email and their profile names come from the vault, so a message that
echoed a key would disclose credential material through a task that runs under
`no_log` precisely to avoid that. `tests/managed_users_vault_test.rb` asserts the
same property end to end; these tests fail faster and name the field.
"""

import copy
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "filter_plugins"))

from immich_preference_schema import (  # noqa: E402
    BOOLEAN,
    ENUM,
    POSITIVE_INTEGER,
    SCOPES,
    STRING,
    immich_preference_errors,
)

EMAIL = "reader@example.invalid"
OTHER_EMAIL = "second@example.invalid"
MANAGED = [EMAIL, OTHER_EMAIL]

PROFILES = {
    "standard": {
        "albums": {"defaultAssetOrder": "desc"},
        "avatar": {"color": "primary"},
        "cast": {"gCastEnabled": False},
        "download": {"archiveSize": 4294967296, "includeEmbeddedVideos": False},
        "emailNotifications": {"enabled": False, "albumInvite": False,
                               "albumUpdate": False},
        "folders": {"enabled": False, "sidebarWeb": False},
        "memories": {"enabled": True, "duration": 5},
        "people": {"enabled": True, "sidebarWeb": False, "minimumFaces": 3},
        "purchase": {"showSupportBadge": False, "hideBuyButtonUntil": ""},
        "ratings": {"enabled": False},
        "recentlyAdded": {"sidebarWeb": True},
        "sharedLinks": {"enabled": True, "sidebarWeb": False},
        "tags": {"enabled": False, "sidebarWeb": False},
    },
    "minimal": {},
}


def errors(profiles=None, overrides=None, by_email=None, default="standard",
           managed=None):
    return immich_preference_errors(
        PROFILES if profiles is None else profiles,
        {} if overrides is None else overrides,
        {} if by_email is None else by_email,
        default,
        MANAGED if managed is None else managed,
    )


class ImmichPreferenceSchemaTest(unittest.TestCase):
    def test_the_declared_profiles_are_valid(self):
        self.assertEqual(errors(), [])

    def test_every_scope_and_field_is_optional(self):
        self.assertEqual(errors(profiles={"standard": {}}), [])
        for scope in SCOPES:
            with self.subTest(scope):
                self.assertEqual(errors(profiles={"standard": {scope: {}}}), [])

    def test_selectors_and_overrides_may_name_a_managed_user(self):
        self.assertEqual(errors(by_email={EMAIL: "minimal"}), [])
        self.assertEqual(errors(overrides={EMAIL: {"ratings": {"enabled": True}}}), [])

    def test_every_field_of_every_scope_has_a_type_guard(self):
        """Exhaustive replacement for the per-field Jinja conditions.

        Generated from `SCOPES` rather than hand-listed, so a field that loses its
        constraint fails here instead of passing unnoticed. The floor catches the
        opposite mistake: a scope or field deleted from the table.
        """
        incompatible = {
            BOOLEAN: ["x", 1, None],
            POSITIVE_INTEGER: [0, -1, True, "1", None],
            STRING: [1, True, None],
            ENUM: [1, True, None, "not-a-member"],
        }
        checked = 0
        for scope, fields in SCOPES.items():
            for field, (kind, _allowed) in fields.items():
                self.assertIn(kind, incompatible, f"{scope}.{field}: unhandled kind")
                for wrong in incompatible[kind]:
                    with self.subTest(f"{scope}.{field}={wrong!r}"):
                        profiles = copy.deepcopy(PROFILES)
                        profiles["standard"][scope] = {field: wrong}
                        found = errors(profiles=profiles)
                        self.assertTrue(found,
                                        f"{scope}.{field} accepted {wrong!r}")
                        self.assertTrue(
                            any(f"profiles[0].{scope}.{field}" in error
                                for error in found),
                            f"{scope}.{field} rejection did not name the field: "
                            f"{found}",
                        )
                checked += 1
        self.assertGreaterEqual(checked, 23,
                                "fewer fields checked than the schema declares")

    def test_a_boolean_is_not_accepted_where_an_integer_is_required(self):
        profiles = copy.deepcopy(PROFILES)
        profiles["standard"]["memories"] = {"duration": True}
        self.assertTrue(any("must be an integer" in error
                            for error in errors(profiles=profiles)))

    def test_an_integer_is_not_accepted_where_a_boolean_is_required(self):
        profiles = copy.deepcopy(PROFILES)
        profiles["standard"]["ratings"] = {"enabled": 1}
        self.assertTrue(any("must be a boolean" in error
                            for error in errors(profiles=profiles)))

    def test_unsupported_scopes_and_fields_are_rejected(self):
        self.assertTrue(errors(profiles={"standard": {"isAdmin": True}}))
        self.assertTrue(errors(profiles={"standard": {"albums": {"bogus": 1}}}))

    def test_a_scope_that_is_not_a_mapping_is_rejected(self):
        found = errors(profiles={"standard": {"albums": "desc"}})
        self.assertTrue(any("profiles[0].albums: must be a mapping" == error
                            for error in found))

    def test_a_profile_that_is_not_a_mapping_is_rejected(self):
        self.assertTrue(errors(profiles={"standard": ["desc"]}))

    def test_a_collection_that_is_not_a_mapping_is_rejected(self):
        self.assertTrue(errors(profiles=[]))
        self.assertTrue(errors(overrides=[]))
        self.assertTrue(errors(by_email=[]))

    def test_the_default_profile_must_be_declared(self):
        self.assertTrue(errors(default="absent"))
        self.assertTrue(errors(default=None))
        self.assertTrue(errors(default=7))

    def test_a_selector_must_choose_a_declared_profile(self):
        self.assertTrue(errors(by_email={EMAIL: "absent"}))

    def test_a_selector_value_must_be_a_string(self):
        self.assertTrue(errors(by_email={EMAIL: 7}))

    def test_selector_and_override_keys_must_name_a_managed_user(self):
        self.assertTrue(errors(by_email={"stranger@example.invalid": "minimal"}))
        self.assertTrue(errors(overrides={"stranger@example.invalid": {}}))

    def test_keys_are_matched_after_trimming_and_lowercasing(self):
        self.assertEqual(errors(by_email={f"  {EMAIL.upper()}  ": "minimal"}), [])
        self.assertEqual(errors(overrides={f" {EMAIL.upper()} ": {}}), [])

    def test_keys_colliding_only_after_normalization_are_rejected(self):
        self.assertTrue(errors(by_email={EMAIL: "minimal",
                                         EMAIL.upper(): "standard"}))
        self.assertTrue(errors(overrides={EMAIL: {}, f" {EMAIL} ": {}}))

    def test_a_non_string_key_is_rejected(self):
        self.assertTrue(errors(overrides={7: {}}))

    def test_no_message_discloses_a_key_or_a_value(self):
        secret_email = "disclosed-email-sentinel@example.invalid"
        secret_profile = "disclosed-profile-sentinel"
        secret_field = "disclosed-field-sentinel"
        secret_colour = "disclosed-colour-sentinel"
        cases = [
            (secret_profile, dict(default=secret_profile)),
            (secret_profile, dict(by_email={EMAIL: secret_profile})),
            (secret_email, dict(overrides={secret_email: {}})),
            (secret_email, dict(by_email={secret_email: "minimal"})),
            (secret_field,
             dict(overrides={EMAIL: {"albums": {secret_field: True}}})),
            (secret_field, dict(overrides={EMAIL: {secret_field: True}})),
            (secret_colour,
             dict(overrides={EMAIL: {"avatar": {"color": secret_colour}}})),
            (secret_profile, dict(profiles={secret_profile: {"albums": 1}},
                                  default=secret_profile)),
        ]
        for secret, kwargs in cases:
            with self.subTest(secret=secret, case=sorted(kwargs)):
                found = errors(**kwargs)
                self.assertTrue(found, f"{kwargs} was accepted")
                joined = " ".join(found)
                self.assertNotIn(secret, joined,
                                 f"the diagnostic disclosed a key or value: {joined}")

    def test_every_scope_in_the_table_is_reachable(self):
        self.assertEqual(sorted(SCOPES), sorted([
            "albums", "avatar", "cast", "download", "emailNotifications",
            "folders", "memories", "people", "purchase", "ratings",
            "recentlyAdded", "sharedLinks", "tags",
        ]))


if __name__ == "__main__":
    unittest.main(verbosity=2)
