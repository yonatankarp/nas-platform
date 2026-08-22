#!/usr/bin/env python3
"""Contract tests for the portable vault credential shape filter.

Every rejection case here corresponds to a condition the "Validate credential
shapes without disclosing credential material" `assert` task in
`roles/vault_contract/tasks/main.yml` carried before the rules moved into
`filter_plugins/vault_credential_schema.py`. The port was checked by running both
implementations over this same case set and requiring identical verdicts; these
tests are what keeps the rules from drifting afterwards.

Several tests exist specifically to pin fidelity rather than strictness, because
the tempting mistake in this port is to tighten a rule while moving it:

* `| length > 0` accepted a whitespace-only value, so whitespace is still
  accepted. Rejecting it would be a new rule, not a migrated one.
* `is match` anchors at the start only, so every pattern needing a full match
  carries its own `$`. A pattern that lost that `$` would accept a valid prefix
  followed by anything, which is exactly how a truncated bcrypt hash or a token
  with trailing junk would get through.
* `LEGACY_ACCEPTED` carries the non-string values the original conditions let
  through, measured by running the role's old and new tasks over the same
  documents. They are latent gaps, not endorsements. They are pinned because a
  refactor that changes what deploys stops being reviewable as a refactor, and
  because the next reader's instinct will be to tighten them; that belongs in its
  own change, with its own reasoning about what it breaks.
"""

from pathlib import Path
import sys
import unittest

REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPOSITORY_ROOT / "filter_plugins"))

from vault_credential_schema import (  # noqa: E402
    BCRYPT_HASH,
    CONTAINS,
    CREDENTIAL_RULES,
    DATABASE_IDENTIFIER,
    DISTINCT_KEYS,
    EMAIL,
    EXACT,
    JELLYFIN_ADMIN_USERNAME,
    NONEMPTY,
    NOT_PLACEHOLDER,
    NTFY_TOKEN,
    OPENSUBTITLES_PASSWORD_PLACEHOLDERS,
    OPENSUBTITLES_USERNAME_PLACEHOLDERS,
    OPENSSH_PRIVATE_KEY_MARKER,
    PATTERN,
    SSH_ED25519_PUBLIC_KEY,
    UUID,
    vault_credential_errors,
)

ROLE_TASKS = REPOSITORY_ROOT / "roles" / "vault_contract" / "tasks" / "main.yml"

HASH = "$2b$10$" + "A" * 53
UUID_VALUE = "00000000-0000-4000-a000-000000000000"
AGENT_KEY = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIA=="
HUB_KEY = f"-----{OPENSSH_PRIVATE_KEY_MARKER}-----\nAAAA\n"

# One accepted value per pattern, and one rejected value that differs from it
# only after the point the pattern's `$` anchors. Together they are the anchoring
# guard: without the `$` the second value is accepted.
PATTERN_SAMPLES = {
    BCRYPT_HASH: (HASH, HASH + "x"),
    DATABASE_IDENTIFIER: ("platform_db", "platform_db;drop"),
    EMAIL: ("person@example.invalid", "person@example.invalid with words"),
    NTFY_TOKEN: ("tk_" + "a" * 29, "tk_" + "a" * 29 + "x"),
    SSH_ED25519_PUBLIC_KEY: (AGENT_KEY, AGENT_KEY + " comment"),
    UUID: (UUID_VALUE, UUID_VALUE + "-extra"),
}

# The non-string values the original conditions accepted, and the ones they
# rejected. Both halves were measured by driving the role's old and new tasks over
# the same vault documents; see the module docstring for why the accepted half is
# preserved rather than fixed.
LEGACY_ACCEPTED = (
    ("vault_tinymediamanager_password", ["sentinel"]),
    ("vault_tinymediamanager_password", {"sentinel": 1}),
    ("vault_paperless_mail_rule_name", ["sentinel"]),
    ("vault_paperless_mail_rule_name", {"sentinel": 1}),
    ("vault_immich_db_name", True),
    ("vault_immich_db_name", None),
    ("vault_paperless_db_username", True),
    ("vault_paperless_db_username", None),
    ("vault_immich_admin_email", ["person@example.invalid"]),
    ("vault_beszel_hub_private_key", [HUB_KEY]),
    ("vault_beszel_hub_private_key", {"id_ed25519": HUB_KEY}),
)
LEGACY_REJECTED = (
    ("vault_tinymediamanager_password", 42),
    ("vault_tinymediamanager_password", True),
    ("vault_tinymediamanager_password", None),
    ("vault_tinymediamanager_password", []),
    ("vault_tinymediamanager_password", {}),
    ("vault_immich_db_name", ["sentinel"]),
    ("vault_immich_db_name", {"sentinel": 1}),
    ("vault_immich_db_name", 42),
    ("vault_immich_admin_email", True),
    ("vault_immich_admin_email", None),
    ("vault_immich_admin_email", 42),
    ("vault_ntfy_dozzle_token", True),
    ("vault_ntfy_dozzle_token", None),
    ("vault_ntfy_dozzle_token", ["tk_" + "a" * 29]),
    ("vault_dozzle_admin_password_hash", True),
    ("vault_beszel_agent_key", True),
    ("vault_beszel_universal_token", None),
    ("vault_jellyfin_admin_username", True),
    ("vault_beszel_hub_private_key", True),
    ("vault_beszel_hub_private_key", None),
)

# A value that satisfies the pattern's character classes but not its shape, so a
# rejection cannot be explained by the anchoring guard alone.
MALFORMED = {
    BCRYPT_HASH: "$2b$10$" + "A" * 52,
    DATABASE_IDENTIFIER: "9platform",
    EMAIL: "person.example.invalid",
    NTFY_TOKEN: "tk_" + "A" * 29,
    SSH_ED25519_PUBLIC_KEY: "ssh-rsa AAAAC3NzaC1lZDI1NTE5AAAAIA==",
    UUID: "00000000-0000-9000-a000-000000000000",
}


def _valid_value(key, rules):
    """Build the accepted value for one credential from its own rules."""
    if key in DISTINCT_KEYS:
        # The three publisher tokens have to differ from each other, so they are
        # keyed off their position rather than off the shared pattern sample.
        return "tk_" + "abcdefghijklmnopqrstuvwxyz012"[:28] + str(
            DISTINCT_KEYS.index(key))
    for kind, argument in rules:
        if kind == PATTERN:
            return PATTERN_SAMPLES[argument][0]
        if kind == EXACT:
            return argument
        if kind == CONTAINS:
            return HUB_KEY
    return "operator-supplied-value"


VALID = {key: _valid_value(key, rules) for key, rules in CREDENTIAL_RULES.items()}


def _rejected_value(key, rules):
    """Build a value the credential's own rules reject, for the loops below."""
    for kind, argument in rules:
        if kind == PATTERN:
            return PATTERN_SAMPLES[argument][1]
        if kind == EXACT:
            return "someone-else"
        if kind == CONTAINS:
            return "not-a-private-key"
        if kind == NOT_PLACEHOLDER:
            return argument[0]
    return ""


def candidate(**overrides):
    updated = dict(VALID)
    updated.update(overrides)
    return updated


def errors_for(**overrides):
    return vault_credential_errors(candidate(**overrides))


def keys_named(errors):
    return {error.split(":", 1)[0] for error in errors}


class VaultCredentialSchemaTest(unittest.TestCase):
    def test_the_valid_credential_set_is_accepted(self):
        self.assertEqual(vault_credential_errors(VALID), [])

    def test_a_non_mapping_candidate_is_rejected(self):
        for value in (None, [], "", 0, "vault_immich_db_name"):
            with self.subTest(repr(value)):
                self.assertEqual(vault_credential_errors(value),
                                 ["vault credentials: must be a mapping"])

    def test_every_credential_rejects_an_empty_string(self):
        for key in CREDENTIAL_RULES:
            with self.subTest(key):
                self.assertIn(key, keys_named(errors_for(**{key: ""})))

    def test_the_legacy_non_string_verdicts_are_preserved(self):
        # Deliberate, not aspirational: see the module docstring. Changing either
        # half of this test changes what the platform deploys.
        for key, value in LEGACY_ACCEPTED:
            with self.subTest(f"accepted {key}={value!r}"):
                self.assertEqual(errors_for(**{key: value}), [])
        for key, value in LEGACY_REJECTED:
            with self.subTest(f"rejected {key}={value!r}"):
                self.assertIn(key, keys_named(errors_for(**{key: value})))

    def test_a_credential_with_no_length_is_named(self):
        # `| length > 0` raised for these, which failed the assert without saying
        # which credential raised. The rule reports the same verdict by name.
        for value in (None, 42, True):
            with self.subTest(repr(value)):
                self.assertIn(
                    "vault_tinymediamanager_password: has no length to measure",
                    errors_for(vault_tinymediamanager_password=value))

    def test_every_credential_rejects_a_value_its_own_rules_reject(self):
        for key, rules in CREDENTIAL_RULES.items():
            with self.subTest(key):
                errors = errors_for(**{key: _rejected_value(key, rules)})
                self.assertIn(key, keys_named(errors))

    def test_a_missing_credential_is_reported_by_name(self):
        for key in CREDENTIAL_RULES:
            with self.subTest(key):
                incomplete = dict(VALID)
                del incomplete[key]
                self.assertIn(f"vault credentials: missing {key}",
                              vault_credential_errors(incomplete))

    def test_an_unexpected_credential_is_reported_by_name(self):
        # Not reachable through the role, whose mapping is a literal, but it is
        # what makes a rule table and a call site that disagree an error.
        self.assertIn("vault credentials: unexpected vault_retired_credential",
                      errors_for(vault_retired_credential="value"))

    def test_a_non_string_key_is_reported_without_raising(self):
        extra = dict(VALID)
        extra[42] = "value"
        self.assertIn("vault credentials: unexpected 42",
                      vault_credential_errors(extra))

    def test_whitespace_is_accepted_where_the_role_accepted_it(self):
        # `| length > 0` passed for a whitespace-only value. Rejecting it here
        # would reject a vault the role deploys today.
        for key, rules in CREDENTIAL_RULES.items():
            if [kind for kind, _ in rules] != [NONEMPTY]:
                continue
            with self.subTest(key):
                self.assertEqual(errors_for(**{key: "   "}), [])

    def test_patterns_anchor_at_the_end(self):
        for key, rules in CREDENTIAL_RULES.items():
            for kind, argument in rules:
                if kind != PATTERN:
                    continue
                accepted, extended = PATTERN_SAMPLES[argument]
                with self.subTest(key):
                    self.assertEqual(errors_for(**{key: accepted}), [])
                    self.assertIn(f"{key}: does not match the required format",
                                  errors_for(**{key: extended}))

    def test_patterns_reject_a_malformed_value(self):
        for key, rules in CREDENTIAL_RULES.items():
            for kind, argument in rules:
                if kind != PATTERN:
                    continue
                with self.subTest(key):
                    self.assertIn(f"{key}: does not match the required format",
                                  errors_for(**{key: MALFORMED[argument]}))

    def test_the_jellyfin_administrator_username_is_pinned(self):
        for wrong in ("yonatan", "YONATAN", f" {JELLYFIN_ADMIN_USERNAME}",
                      f"{JELLYFIN_ADMIN_USERNAME} ", "admin"):
            with self.subTest(wrong):
                self.assertIn(
                    "vault_jellyfin_admin_username: must be the pinned "
                    "administrator username",
                    errors_for(vault_jellyfin_admin_username=wrong))

    def test_the_documented_opensubtitles_placeholders_are_rejected(self):
        cases = (("vault_jellyfin_opensubtitles_username",
                  OPENSUBTITLES_USERNAME_PLACEHOLDERS),
                 ("vault_jellyfin_opensubtitles_password",
                  OPENSUBTITLES_PASSWORD_PLACEHOLDERS))
        for key, placeholders in cases:
            for placeholder in placeholders:
                with self.subTest(f"{key}={placeholder}"):
                    self.assertIn(f"{key}: is still the documented placeholder",
                                  errors_for(**{key: placeholder}))

    def test_an_operator_supplied_opensubtitles_value_is_accepted(self):
        self.assertEqual(
            errors_for(vault_jellyfin_opensubtitles_username="real-account",
                       vault_jellyfin_opensubtitles_password="real-password"),
            [])

    def test_the_hub_private_key_must_carry_the_openssh_marker(self):
        self.assertIn("vault_beszel_hub_private_key: is missing the required "
                      "key marker",
                      errors_for(vault_beszel_hub_private_key="-----BEGIN "
                                                              "RSA KEY-----"))

    def test_the_publisher_tokens_must_all_differ(self):
        shared = VALID["vault_ntfy_dozzle_token"]
        for key in DISTINCT_KEYS[1:]:
            with self.subTest(key):
                errors = errors_for(**{key: shared})
                self.assertTrue(any("must all differ" in error
                                    for error in errors),
                                f"{key} was allowed to duplicate a token")

    def test_distinct_publisher_tokens_are_accepted(self):
        self.assertEqual(len({VALID[key] for key in DISTINCT_KEYS}),
                         len(DISTINCT_KEYS))
        self.assertEqual(vault_credential_errors(VALID), [])

    def test_no_message_carries_a_value_or_a_comparand(self):
        # Every error is printed by a `fail_msg`, which `no_log` does not
        # suppress. The sentinel stands in for a credential; the literals stand
        # in for the comparands, which are equally not for printing.
        sentinel = "sentinel-must-not-be-disclosed"
        comparands = ((JELLYFIN_ADMIN_USERNAME,) +
                      OPENSUBTITLES_USERNAME_PLACEHOLDERS +
                      OPENSUBTITLES_PASSWORD_PLACEHOLDERS +
                      (OPENSSH_PRIVATE_KEY_MARKER,))
        for key, rules in CREDENTIAL_RULES.items():
            for value in (sentinel, [sentinel], {sentinel: sentinel},
                          _rejected_value(key, rules)):
                with self.subTest(f"{key}={type(value).__name__}"):
                    joined = " ".join(errors_for(**{key: value}))
                    self.assertNotIn(sentinel, joined)
                    for comparand in comparands:
                        self.assertNotIn(comparand, joined)

    def test_every_message_starts_with_a_known_field(self):
        known = set(CREDENTIAL_RULES) | {"vault credentials"}
        for key, rules in CREDENTIAL_RULES.items():
            with self.subTest(key):
                errors = errors_for(**{key: _rejected_value(key, rules)})
                self.assertTrue(errors, f"{key} produced no diagnostic")
                self.assertTrue(keys_named(errors) <= known,
                                f"{key} named something unknown: {errors}")

    def test_the_role_submits_every_credential_the_table_covers(self):
        # The mapping in the role is what states the key set under validation, so
        # a rule with nothing submitting to it would never run.
        tasks = ROLE_TASKS.read_text()
        for key in CREDENTIAL_RULES:
            with self.subTest(key):
                self.assertIn(f"'{key}': {key}", tasks)


if __name__ == "__main__":
    unittest.main(verbosity=2)
