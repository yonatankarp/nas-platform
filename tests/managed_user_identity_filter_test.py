#!/usr/bin/env python3
"""Contract tests for the shared managed-user ambiguity decision.

filter_plugins/managed_user_identity.py must refuse a case-folded collision,
accept Immich's already-folded match list, and return nothing identifying.
"""

from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "filter_plugins"))

from ansible.errors import AnsibleFilterError  # noqa: E402

import vault_managed_user_schema  # noqa: E402

from managed_user_identity import (  # noqa: E402
    _normalize,
    managed_user_ambiguity_errors,
)

SECRET = "managed.person@example.com"


def listing(*emails, attribute="email"):
    return [{attribute: email, "id": str(index)}
            for index, email in enumerate(emails)]


def exact(entries, attribute, identity):
    """What the five roles that do not index build with `selectattr`."""
    return [entry for entry in entries if entry.get(attribute) == identity]


def folded(entries, attribute, identity):
    """What Immich's normalised index produces for the same inputs."""
    return [entry for entry in entries
            if str(entry.get(attribute)).strip().lower()
            == identity.strip().lower()]


class ManagedUserAmbiguityTest(unittest.TestCase):
    def test_accepts_a_single_exact_match(self):
        entries = listing("other@example.com", SECRET)
        self.assertEqual(
            managed_user_ambiguity_errors(
                entries, "email", SECRET, exact(entries, "email", SECRET)),
            [])

    def test_accepts_an_absent_identity_so_the_role_may_create_it(self):
        entries = listing("other@example.com")
        self.assertEqual(
            managed_user_ambiguity_errors(entries, "email", SECRET, []), [])

    def test_refuses_a_duplicate_match(self):
        entries = listing(SECRET, SECRET)
        found = managed_user_ambiguity_errors(
            entries, "email", SECRET, exact(entries, "email", SECRET))
        self.assertTrue(found)
        self.assertIn("at most one may", " ".join(found))

    def test_refuses_a_case_folded_collision(self):
        """The condition an exact-match selector cannot see on its own."""
        entries = listing(SECRET, SECRET.upper())
        matches = exact(entries, "email", SECRET)
        self.assertEqual(len(matches), 1, "the selector saw only one user")
        found = managed_user_ambiguity_errors(entries, "email", SECRET, matches)
        self.assertTrue(found, "a case-folded collision was accepted")
        self.assertIn("wrong record", " ".join(found))

    def test_refuses_a_whitespace_padded_collision(self):
        entries = listing(SECRET, f"  {SECRET} ")
        matches = exact(entries, "email", SECRET)
        found = managed_user_ambiguity_errors(entries, "email", SECRET, matches)
        self.assertTrue(found, "a padded collision was accepted")

    def test_accepts_a_normalized_match_list(self):
        """Immich indexes by folded email; both variants are one bucket."""
        entries = listing(SECRET, SECRET.upper())
        self.assertEqual(
            managed_user_ambiguity_errors(
                entries, "email", SECRET, folded(entries, "email", SECRET)),
            ["email: 2 listed users match this managed identity, "
             "and at most one may"])
        single = listing(SECRET.upper())
        self.assertEqual(
            managed_user_ambiguity_errors(
                single, "email", SECRET, folded(single, "email", SECRET)),
            [], "an exact-equality rule would refuse what Immich accepts")

    def test_reads_the_attribute_each_service_names(self):
        for attribute in ("email", "username", "Name"):
            with self.subTest(attribute=attribute):
                entries = listing("managed", attribute=attribute)
                self.assertEqual(
                    managed_user_ambiguity_errors(
                        entries, attribute, "managed",
                        exact(entries, attribute, "managed")),
                    [])
                # The same listing read under a different attribute name has no
                # readable identity at all, which must be refused rather than
                # silently matching nothing.
                self.assertTrue(managed_user_ambiguity_errors(
                    entries, "nonesuch", "managed", []))

    def test_refuses_a_listing_entry_without_a_readable_identity(self):
        for broken in (None, 42, True, ["a"], {"nested": 1}):
            with self.subTest(value=broken):
                entries = [{"email": SECRET}, {"email": broken}]
                found = managed_user_ambiguity_errors(
                    entries, "email", SECRET, exact(entries, "email", SECRET))
                self.assertTrue(found, "an unreadable listing was accepted")
                self.assertIn("must be a string", " ".join(found))

    def test_refuses_a_listing_entry_that_is_not_a_mapping(self):
        found = managed_user_ambiguity_errors(
            [{"email": SECRET}, "not-a-user"], "email", SECRET,
            [{"email": SECRET}])
        self.assertTrue(found)
        self.assertIn("must be a mapping", " ".join(found))

    def test_an_unreadable_listing_still_reports_a_duplicate_match(self):
        found = managed_user_ambiguity_errors(
            [{"email": None}], "email", SECRET,
            [{"email": SECRET}, {"email": SECRET}])
        joined = " ".join(found)
        self.assertIn("at most one may", joined)
        self.assertIn("must be a string", joined)
        self.assertNotIn("wrong record", joined,
                         "a count derived from an unreadable listing was used")

    def test_folds_identities_the_way_the_vault_schema_already_does(self):
        """Folds identities exactly as vault_managed_user_schema does, non-ASCII included."""
        for value in ("MÜNCHEN@example.com", "İstanbul@example.com",
                      " Ünïcode.Person@example.com\t", "STRASSE@example.com"):
            with self.subTest(value=value):
                self.assertEqual(
                    _normalize(value),
                    vault_managed_user_schema._normalized_identities(
                        [{"email": value}], "email")[0])

    def test_folds_a_non_ascii_case_collision(self):
        identity = "münchen@example.com"
        entries = listing(identity, identity.upper())
        matches = exact(entries, "email", identity)
        self.assertEqual(len(matches), 1)
        self.assertTrue(managed_user_ambiguity_errors(
            entries, "email", identity, matches))

    def test_refuses_inputs_that_are_not_the_shapes_the_roles_pass(self):
        for arguments in (
            ({"not": "a list"}, "email", SECRET, []),
            ([], 7, SECRET, []),
            ([], "email", None, []),
            ([], "email", SECRET, {"not": "a list"}),
        ):
            with self.subTest(arguments=arguments):
                with self.assertRaises(AnsibleFilterError):
                    managed_user_ambiguity_errors(*arguments)

    def test_accepts_a_tuple_from_the_templar(self):
        entries = ({"email": SECRET},)
        self.assertEqual(
            managed_user_ambiguity_errors(
                entries, "email", SECRET, ({"email": SECRET},)),
            [])

    def test_no_error_carries_an_identity_or_a_listed_value(self):
        cases = (
            (listing(SECRET, SECRET), exact(listing(SECRET, SECRET),
                                            "email", SECRET)),
            (listing(SECRET, SECRET.upper()),
             exact(listing(SECRET, SECRET.upper()), "email", SECRET)),
            ([{"email": SECRET}, {"email": None}], [{"email": SECRET}]),
            ([{"email": SECRET}, SECRET], [{"email": SECRET}]),
        )
        for entries, matches in cases:
            with self.subTest(entries=len(entries)):
                found = managed_user_ambiguity_errors(
                    entries, "email", SECRET, matches)
                self.assertTrue(found)
                joined = " ".join(found)
                self.assertNotIn(SECRET, joined)
                self.assertNotIn(SECRET.lower(), joined.lower())
                self.assertNotIn("example.com", joined)


if __name__ == "__main__":
    unittest.main(verbosity=2)
