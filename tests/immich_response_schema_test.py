#!/usr/bin/env python3
"""Contract tests for the Immich preference response schema filter.

Every rejection case here corresponds to a condition the two duplicated
36-condition `assert` tasks in `roles/immich/tasks/managed_users.yml` carried
before the schema moved into `filter_plugins/immich_response_schema.py`.

Two properties matter more than the rest, because getting either wrong turns a
guard into decoration:

* **An unknown key is accepted.** The condition this replaces required the twelve
  known scopes to be present and said nothing about the rest. A schema that
  refused a new Immich preference field would fail a converged deployment the
  day Immich shipped one, so `test_accepts_fields_immich_may_add` is a
  regression test against copying `immich_preference_schema`'s `_unsupported`.
* **A missing key is refused.** The conditions read the field unguarded, so an
  absent key was Undefined and already a rejection. Its sibling module treats
  every field as optional, and inheriting that would validate nothing.

The redaction tests exist because the calling task loops over `uri` results whose
`item` is a vault managed-user record, under `no_log`, and prints this list from
its `fail_msg`.
"""

import copy
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "filter_plugins"))

from immich_response_schema import (  # noqa: E402
    BOOLEAN,
    ENUM,
    INTEGER,
    SCOPES,
    STRING,
    immich_preference_response_errors,
)

# What Immich v3 returns from GET /admin/users/<id>/preferences, restricted to
# the scopes this platform reconciles. The role compares against this document
# before it PATCHes anything.
RESPONSE = {
    "albums": {"defaultAssetOrder": "desc"},
    "cast": {"gCastEnabled": False},
    "download": {"archiveSize": 4294967296, "includeEmbeddedVideos": False},
    "emailNotifications": {"enabled": True, "albumInvite": True, "albumUpdate": True},
    "folders": {"enabled": False, "sidebarWeb": False},
    "memories": {"enabled": True, "duration": 5},
    "people": {"enabled": True, "sidebarWeb": False, "minimumFaces": 3},
    "purchase": {"showSupportBadge": True,
                 "hideBuyButtonUntil": "2022-02-12T00:00:00.000Z"},
    "ratings": {"enabled": False},
    "recentlyAdded": {"sidebarWeb": False},
    "sharedLinks": {"enabled": True, "sidebarWeb": False},
    "tags": {"enabled": False, "sidebarWeb": False},
}

# One rejected value per kind, chosen so the rejection cannot be explained by
# anything except the type: an integer that equals a boolean, a boolean that
# equals an integer, and a name outside the enum.
WRONG = {
    BOOLEAN: 1,
    INTEGER: True,
    STRING: None,
    ENUM: "sideways",
}


def mutated(scope, field, value):
    document = copy.deepcopy(RESPONSE)
    document[scope][field] = value
    return document


class ImmichResponseSchemaTest(unittest.TestCase):
    def test_accepts_the_documented_response(self):
        self.assertEqual(immich_preference_response_errors(RESPONSE), [])

    def test_accepts_fields_immich_may_add(self):
        """A new scope or a new field in a known scope must not fail a run."""
        document = copy.deepcopy(RESPONSE)
        document["somethingNew"] = {"enabled": True}
        document["albums"]["defaultAssetSort"] = "fileCreatedAt"
        document["download"]["includeSidecars"] = True
        self.assertEqual(immich_preference_response_errors(document), [])

    def test_refuses_a_response_that_is_not_a_mapping(self):
        for value in (None, [], "preferences", 5, True):
            with self.subTest(value=type(value).__name__):
                self.assertEqual(immich_preference_response_errors(value),
                                 ["preferences: must be a mapping"])

    def test_refuses_a_missing_scope_by_name(self):
        for scope in SCOPES:
            document = copy.deepcopy(RESPONSE)
            del document[scope]
            with self.subTest(scope=scope):
                self.assertEqual(immich_preference_response_errors(document),
                                 [f"preferences.{scope}: is missing"])

    def test_refuses_a_scope_that_is_not_a_mapping(self):
        for scope in SCOPES:
            with self.subTest(scope=scope):
                document = copy.deepcopy(RESPONSE)
                document[scope] = "unsupported"
                self.assertEqual(immich_preference_response_errors(document),
                                 [f"preferences.{scope}: must be a mapping"])

    def test_refuses_a_missing_field_by_path(self):
        for scope, fields in SCOPES.items():
            for field in fields:
                document = copy.deepcopy(RESPONSE)
                del document[scope][field]
                with self.subTest(scope=scope, field=field):
                    self.assertEqual(
                        immich_preference_response_errors(document),
                        [f"preferences.{scope}.{field}: is missing"])

    def test_refuses_a_mistyped_field_by_path(self):
        for scope, fields in SCOPES.items():
            for field, (kind, _allowed) in fields.items():
                document = mutated(scope, field, WRONG[kind])
                path = f"preferences.{scope}.{field}"
                with self.subTest(scope=scope, field=field, kind=kind):
                    found = immich_preference_response_errors(document)
                    self.assertEqual(len(found), 1, found)
                    self.assertTrue(found[0].startswith(f"{path}: "), found)

    def test_reports_the_type_a_field_must_have(self):
        expectations = {
            ("cast", "gCastEnabled"): "preferences.cast.gCastEnabled: must be a boolean",
            ("download", "archiveSize"):
                "preferences.download.archiveSize: must be an integer",
            ("purchase", "hideBuyButtonUntil"):
                "preferences.purchase.hideBuyButtonUntil: must be a string",
            ("albums", "defaultAssetOrder"):
                "preferences.albums.defaultAssetOrder: must be one of asc, desc",
        }
        for (scope, field), message in expectations.items():
            kind = SCOPES[scope][field][0]
            with self.subTest(scope=scope, field=field):
                self.assertEqual(
                    immich_preference_response_errors(mutated(scope, field, WRONG[kind])),
                    [message])

    def test_refuses_a_non_string_asset_order_without_erroring(self):
        """`42 in ['asc', 'desc']` was false, not an error; so is this."""
        self.assertEqual(
            immich_preference_response_errors(mutated("albums", "defaultAssetOrder", 42)),
            ["preferences.albums.defaultAssetOrder: must be one of asc, desc"])

    def test_accepts_a_boolean_that_is_not_the_shipped_value(self):
        """The schema is a type contract; the desired value is reconciled later."""
        self.assertEqual(
            immich_preference_response_errors(mutated("cast", "gCastEnabled", True)), [])

    def test_reports_every_violation_rather_than_the_first(self):
        document = copy.deepcopy(RESPONSE)
        document["cast"]["gCastEnabled"] = 1
        del document["ratings"]["enabled"]
        document["tags"] = []
        self.assertEqual(immich_preference_response_errors(document), [
            "preferences.cast.gCastEnabled: must be a boolean",
            "preferences.ratings.enabled: is missing",
            "preferences.tags: must be a mapping",
        ])

    def test_never_discloses_a_value_or_an_unknown_key(self):
        secret = "managed-user-sentinel"
        documents = [
            mutated("purchase", "hideBuyButtonUntil", secret.encode()),
            mutated("albums", "defaultAssetOrder", secret),
            mutated("download", "archiveSize", secret),
        ]
        extra = copy.deepcopy(RESPONSE)
        extra[secret] = {secret: secret}
        extra["cast"] = secret
        documents.append(extra)
        for document in documents:
            with self.subTest(document=sorted(document)):
                found = immich_preference_response_errors(document)
                self.assertTrue(found, "a malformed response was accepted")
                self.assertNotIn(secret, " ".join(found))

    def test_the_table_is_the_schema_the_role_required(self):
        self.assertEqual(sorted(SCOPES), sorted([
            "albums", "cast", "download", "emailNotifications", "folders",
            "memories", "people", "purchase", "ratings", "recentlyAdded",
            "sharedLinks", "tags",
        ]))
        self.assertEqual(sorted(RESPONSE), sorted(SCOPES))
        for scope, fields in SCOPES.items():
            self.assertEqual(sorted(RESPONSE[scope]), sorted(fields), scope)

    def test_the_response_schema_is_not_the_declared_preference_schema(self):
        """Merging the two modules would break one of them; pin the difference."""
        import immich_preference_schema as declared

        self.assertNotIn("avatar", SCOPES)
        self.assertIn("avatar", declared.SCOPES)
        # Declared preferences are optional and reject unknown keys; responses
        # are required and accept them.
        self.assertEqual(declared.immich_preference_errors(
            {"standard": {}}, {}, {}, "standard", []), [])
        self.assertTrue(immich_preference_response_errors({}))


if __name__ == "__main__":
    unittest.main(verbosity=2)
