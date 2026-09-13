"""Unit coverage for the vault artifact identity filter.

The filter folds the encrypted vault artifacts a run was made against into one
SHA-256. It is report identity only: no credential passes through it. What these
cases protect is the property that made the storage composition safe -- a rule
that selects its own subjects must fail loudly when it selects none, and must
produce the same answer on every machine.
"""

import hashlib
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "filter_plugins"))

from ansible.errors import AnsibleFilterError  # noqa: E402

from vault_artifact_identity import vault_artifact_identity  # noqa: E402

DIGEST_A = "a" * 64
DIGEST_B = "b" * 64


def artifact(path, checksum):
    return {"path": path, "checksum": checksum}


class VaultArtifactIdentityTest(unittest.TestCase):
    def test_single_artifact_folds_name_and_digest(self):
        expected = hashlib.sha256(f"vault.yml:{DIGEST_A}".encode("utf-8")).hexdigest()
        self.assertEqual(
            vault_artifact_identity([artifact("/x/inventory/vault.yml", DIGEST_A)]),
            expected,
        )

    def test_identity_is_64_hex_characters(self):
        value = vault_artifact_identity([artifact("/x/vault.yml", DIGEST_A)])
        self.assertEqual(len(value), 64)
        self.assertTrue(set(value).issubset(set("0123456789abcdef")))

    def test_on_disk_order_does_not_change_the_identity(self):
        # find returns the directory's order, which differs between machines.
        forward = vault_artifact_identity(
            [artifact("/x/vault_a.yml", DIGEST_A), artifact("/x/vault_b.yml", DIGEST_B)]
        )
        reverse = vault_artifact_identity(
            [artifact("/x/vault_b.yml", DIGEST_B), artifact("/x/vault_a.yml", DIGEST_A)]
        )
        self.assertEqual(forward, reverse)

    def test_names_are_part_of_the_identity(self):
        # Two artifact sets holding identical ciphertext under different service
        # names are not the same deployment, and a digest of digests alone
        # cannot say so.
        first = vault_artifact_identity([artifact("/x/vault_immich.yml", DIGEST_A)])
        second = vault_artifact_identity([artifact("/x/vault_komga.yml", DIGEST_A)])
        self.assertNotEqual(first, second)

    def test_a_changed_member_changes_the_identity(self):
        before = vault_artifact_identity(
            [artifact("/x/vault_a.yml", DIGEST_A), artifact("/x/vault_b.yml", DIGEST_B)]
        )
        after = vault_artifact_identity(
            [artifact("/x/vault_a.yml", DIGEST_A), artifact("/x/vault_b.yml", "c" * 64)]
        )
        self.assertNotEqual(before, after)

    def test_a_removed_member_changes_the_identity(self):
        both = vault_artifact_identity(
            [artifact("/x/vault_a.yml", DIGEST_A), artifact("/x/vault_b.yml", DIGEST_B)]
        )
        one = vault_artifact_identity([artifact("/x/vault_a.yml", DIGEST_A)])
        self.assertNotEqual(both, one)

    def test_empty_selection_is_refused(self):
        # The floor. An empty list has a perfectly good digest, and returning it
        # would report a successful identification of nothing.
        with self.assertRaises(AnsibleFilterError) as raised:
            vault_artifact_identity([])
        self.assertIn("no encrypted vault artifact", str(raised.exception))

    def test_missing_checksum_is_refused(self):
        # Reached when find ran without get_checksum.
        with self.assertRaises(AnsibleFilterError) as raised:
            vault_artifact_identity([{"path": "/x/vault.yml"}])
        self.assertIn("no SHA-256 checksum", str(raised.exception))

    def test_short_checksum_is_refused(self):
        with self.assertRaises(AnsibleFilterError):
            vault_artifact_identity([artifact("/x/vault.yml", "abc")])

    def test_non_hex_checksum_is_refused(self):
        with self.assertRaises(AnsibleFilterError):
            vault_artifact_identity([artifact("/x/vault.yml", "z" * 64)])

    def test_duplicate_basenames_are_refused(self):
        with self.assertRaises(AnsibleFilterError) as raised:
            vault_artifact_identity(
                [artifact("/a/vault.yml", DIGEST_A), artifact("/b/vault.yml", DIGEST_B)]
            )
        self.assertIn("distinct basenames", str(raised.exception))

    def test_non_list_is_refused(self):
        with self.assertRaises(AnsibleFilterError):
            vault_artifact_identity({"path": "/x/vault.yml", "checksum": DIGEST_A})

    def test_non_mapping_member_is_refused(self):
        with self.assertRaises(AnsibleFilterError):
            vault_artifact_identity(["/x/vault.yml"])

    def test_empty_path_is_refused(self):
        with self.assertRaises(AnsibleFilterError):
            vault_artifact_identity([artifact("", DIGEST_A)])


if __name__ == "__main__":
    unittest.main(verbosity=2)
