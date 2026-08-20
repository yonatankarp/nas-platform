#!/usr/bin/env python3
"""Contract tests for the managed-user vault schema filter.

Every rejection case here corresponds to a condition the eleven `assert` tasks in
`roles/vault_contract/tasks/main.yml` carried before the schema moved into
`filter_plugins/vault_managed_user_schema.py`. The port was checked by running
both implementations over this same case set and requiring identical verdicts;
these tests are what keeps the rules from drifting afterwards.
"""

import copy
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "filter_plugins"))

from vault_managed_user_schema import vault_managed_user_errors  # noqa: E402

HASH = "$2b$10$" + "A" * 53
TOKEN = "tk_" + "a" * 29
RESERVED = ["tk_" + "c" * 29, "tk_" + "d" * 29]

VALID = {
    "audiobookshelf": [{
        "username": "reader", "password": "pw", "type": "user", "is_active": True,
        "permissions": {"flags": {"download": True, "update": False},
                        "librariesAccessible": ["Books"],
                        "itemTagsSelected": ["tag"]},
    }],
    "beszel": [{"email": "b@example.invalid", "password": "pw", "role": "user",
                "verified": True}],
    "dozzle": [{"username": "viewer", "password": "pw", "password_hash": HASH,
                "email": "", "name": "Viewer", "filter": "", "roles": "user"}],
    "immich": [{"email": "i@example.invalid", "password": "pw", "name": "I",
                "quota_size": 0}],
    "jellyfin": [{"username": "watcher", "password": "pw",
                  "policy": {"EnableMediaPlayback": True, "IsDisabled": False}}],
    "komga": [{"email": "k@example.invalid", "password": "pw",
               "roles": ["PAGE_STREAMING"]}],
    "ntfy": [{"username": "phone", "password": "pw", "password_hash": HASH,
              "role": "user",
              "access": [{"topic": "nas-critical", "permission": "read-only"}],
              "tokens": [TOKEN]}],
    "paperless_ngx": [{"username": "scanner", "password": "pw",
                       "email": "p@example.invalid", "is_active": True,
                       "is_staff": False, "is_superuser": False,
                       "groups": ["Scanners"]}],
}

REJECTED = {
    "audiobookshelf missing key": lambda v: v["audiobookshelf"][0].pop("type"),
    "audiobookshelf extra key": lambda v: v["audiobookshelf"][0].update(extra=1),
    "audiobookshelf unsupported type": lambda v: v["audiobookshelf"][0].update(type="root"),
    "audiobookshelf blank username": lambda v: v["audiobookshelf"][0].update(username="   "),
    "audiobookshelf empty password": lambda v: v["audiobookshelf"][0].update(password=""),
    "audiobookshelf inactive": lambda v: v["audiobookshelf"][0].update(is_active=False),
    "audiobookshelf is_active not boolean": lambda v: v["audiobookshelf"][0].update(is_active="true"),
    "audiobookshelf unknown flag": lambda v: v["audiobookshelf"][0]["permissions"]["flags"].update(bogus=True),
    "audiobookshelf flag not boolean": lambda v: v["audiobookshelf"][0]["permissions"]["flags"].update(download="yes"),
    "audiobookshelf libraries duplicated": lambda v: v["audiobookshelf"][0]["permissions"].update(librariesAccessible=["a", "a"]),
    "audiobookshelf library empty": lambda v: v["audiobookshelf"][0]["permissions"].update(librariesAccessible=[""]),
    "audiobookshelf libraries not a list": lambda v: v["audiobookshelf"][0]["permissions"].update(librariesAccessible="a"),
    "audiobookshelf tag not a string": lambda v: v["audiobookshelf"][0]["permissions"].update(itemTagsSelected=[1]),
    "beszel malformed email": lambda v: v["beszel"][0].update(email="nope"),
    "beszel unverified": lambda v: v["beszel"][0].update(verified=False),
    "beszel unsupported role": lambda v: v["beszel"][0].update(role="owner"),
    "dozzle malformed hash": lambda v: v["dozzle"][0].update(password_hash="$2b$10$short"),
    "dozzle malformed email": lambda v: v["dozzle"][0].update(email="nope"),
    "dozzle empty name": lambda v: v["dozzle"][0].update(name=""),
    "dozzle unsupported roles": lambda v: v["dozzle"][0].update(roles="root"),
    "dozzle filter not a string": lambda v: v["dozzle"][0].update(filter=1),
    "immich negative quota": lambda v: v["immich"][0].update(quota_size=-1),
    "immich boolean quota": lambda v: v["immich"][0].update(quota_size=True),
    "immich string quota": lambda v: v["immich"][0].update(quota_size="0"),
    "immich no users": lambda v: v.update(immich=[]),
    "jellyfin unsupported policy field": lambda v: v["jellyfin"][0]["policy"].update(Bogus=True),
    "jellyfin credential policy field": lambda v: v["jellyfin"][0]["policy"].update(password=True),
    "jellyfin cased credential policy field": lambda v: v["jellyfin"][0]["policy"].update(Access_Token=True),
    "jellyfin disabled account": lambda v: v["jellyfin"][0]["policy"].update(IsDisabled=True),
    "jellyfin empty policy": lambda v: v["jellyfin"][0].update(policy={}),
    "jellyfin policy value not boolean": lambda v: v["jellyfin"][0]["policy"].update(EnableMediaPlayback="yes"),
    "komga unsupported role": lambda v: v["komga"][0].update(roles=["SUPER"]),
    "komga no roles": lambda v: v["komga"][0].update(roles=[]),
    "komga duplicated roles": lambda v: v["komga"][0].update(roles=["ADMIN", "ADMIN"]),
    "ntfy malformed username": lambda v: v["ntfy"][0].update(username="has space"),
    "ntfy elevated role": lambda v: v["ntfy"][0].update(role="admin"),
    "ntfy malformed token": lambda v: v["ntfy"][0].update(tokens=["tk_SHORT"]),
    "ntfy duplicated token": lambda v: v["ntfy"][0].update(tokens=[TOKEN, TOKEN]),
    "ntfy reuses a service token": lambda v: v["ntfy"][0].update(tokens=[RESERVED[0]]),
    "ntfy malformed topic": lambda v: v["ntfy"][0]["access"][0].update(topic="bad topic!"),
    "ntfy unsupported permission": lambda v: v["ntfy"][0]["access"][0].update(permission="rw"),
    "ntfy access extra key": lambda v: v["ntfy"][0]["access"][0].update(extra=1),
    "ntfy access not a list": lambda v: v["ntfy"][0].update(access="x"),
    "paperless inactive": lambda v: v["paperless_ngx"][0].update(is_active=False),
    "paperless is_staff not boolean": lambda v: v["paperless_ngx"][0].update(is_staff="no"),
    "paperless malformed email": lambda v: v["paperless_ngx"][0].update(email="nope"),
    "paperless empty group": lambda v: v["paperless_ngx"][0].update(groups=[""]),
    "paperless duplicated groups": lambda v: v["paperless_ngx"][0].update(groups=["A", "A"]),
    "missing service key": lambda v: v.pop("komga"),
    "unexpected service key": lambda v: v.update(plex=[]),
    "service value not a list": lambda v: v.update(komga={}),
}


class VaultManagedUserSchemaTest(unittest.TestCase):
    def test_the_valid_contract_is_accepted(self):
        self.assertEqual(vault_managed_user_errors(VALID, RESERVED), [])

    def test_every_violation_is_rejected(self):
        for label, mutate in REJECTED.items():
            with self.subTest(label):
                candidate = copy.deepcopy(VALID)
                mutate(candidate)
                errors = vault_managed_user_errors(candidate, RESERVED)
                self.assertTrue(errors, f"{label} was accepted")

    def test_no_error_message_carries_a_value(self):
        secrets = ["pw", HASH, TOKEN, "reader", "b@example.invalid", "Books"]
        for label, mutate in REJECTED.items():
            with self.subTest(label):
                candidate = copy.deepcopy(VALID)
                mutate(candidate)
                joined = " ".join(vault_managed_user_errors(candidate, RESERVED))
                for secret in secrets:
                    self.assertNotIn(secret, joined,
                                     f"{label} disclosed {secret!r}")

    def test_errors_name_the_offending_field_path(self):
        candidate = copy.deepcopy(VALID)
        candidate["audiobookshelf"][0]["permissions"]["flags"]["download"] = "yes"
        errors = vault_managed_user_errors(candidate, RESERVED)
        self.assertEqual(errors, ["audiobookshelf[0].permissions.flags.download: "
                                  "must be a boolean"])

    def test_every_field_of_every_service_has_a_type_guard(self):
        """Exhaustive replacement for the per-field source-text assertions.

        For each service and each field, substitute a value of an incompatible
        type and require rejection. This is generated from the valid fixture, so
        a field added to a schema without a type guard fails here rather than
        needing a new assertion written by hand.
        """
        wrong = {str: 12345, bool: "not-a-bool", int: "not-an-int",
                 list: "not-a-list", dict: "not-a-mapping"}
        checked = 0
        for service, entries in VALID.items():
            for field, value in entries[0].items():
                kind = type(value)
                self.assertIn(kind, wrong, f"{service}.{field}: unhandled kind {kind}")
                with self.subTest(f"{service}.{field}"):
                    candidate = copy.deepcopy(VALID)
                    candidate[service][0][field] = wrong[kind]
                    errors = vault_managed_user_errors(candidate, RESERVED)
                    self.assertTrue(errors, f"{service}.{field} accepted a {kind.__name__} "
                                            f"replaced by an incompatible type")
                    self.assertTrue(any(f"{service}[0].{field}" in error for error in errors),
                                    f"{service}.{field} rejection did not name the field: {errors}")
                checked += 1
        self.assertGreaterEqual(checked, 32, "fewer fields checked than the schema declares")

    def test_nested_permission_and_access_fields_have_type_guards(self):
        nested = [
            ("audiobookshelf", ["permissions", "flags"], "not-a-mapping"),
            ("audiobookshelf", ["permissions", "librariesAccessible"], "not-a-list"),
            ("audiobookshelf", ["permissions", "itemTagsSelected"], "not-a-list"),
            ("ntfy", ["access", 0, "topic"], 12345),
            ("ntfy", ["access", 0, "permission"], 12345),
        ]
        for service, path, replacement in nested:
            with self.subTest(f"{service}.{'.'.join(map(str, path))}"):
                candidate = copy.deepcopy(VALID)
                target = candidate[service][0]
                for step in path[:-1]:
                    target = target[step]
                target[path[-1]] = replacement
                self.assertTrue(vault_managed_user_errors(candidate, RESERVED))

    def test_a_non_mapping_root_is_rejected(self):
        self.assertTrue(vault_managed_user_errors([], RESERVED))


if __name__ == "__main__":
    unittest.main(verbosity=2)
