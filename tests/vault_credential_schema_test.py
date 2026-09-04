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
  carries its own end anchor. API keys use `\\Z` because `$` also matches just
  before a terminal newline; losing an end anchor would accept a valid prefix
  followed by junk.
* `LEGACY_ACCEPTED` carries the non-string values the original conditions let
  through, measured by running the role's old and new tasks over the same
  documents. They are latent gaps, not endorsements. They are pinned because a
  refactor that changes what deploys stops being reviewable as a refactor, and
  because the next reader's instinct will be to tighten them; that belongs in its
  own change, with its own reasoning about what it breaks.
"""

from pathlib import Path
import json
import re
import subprocess
import sys
import tempfile
import unittest

REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPOSITORY_ROOT / "filter_plugins"))

from vault_credential_schema import (  # noqa: E402
    BCRYPT_HASH,
    CONTAINS,
    CREDENTIAL_RULES,
    DATABASE_IDENTIFIER,
    DISTINCT_KEY_GROUPS,
    EMAIL,
    EXACT,
    HEX_32,
    JELLYFIN_ADMIN_USERNAME,
    NONEMPTY,
    NOT_PLACEHOLDER,
    NTFY_TOKEN,
    OPTIONAL_KEY_GROUPS,
    OPENSUBTITLES_PASSWORD_PLACEHOLDERS,
    OPENSUBTITLES_USERNAME_PLACEHOLDERS,
    OPENSSH_PRIVATE_KEY_MARKER,
    PATTERN,
    SEARCH,
    SSH_ED25519_PUBLIC_KEY,
    UUID,
    vault_credential_errors,
)

ROLE_TASKS = REPOSITORY_ROOT / "roles" / "vault_contract" / "tasks" / "main.yml"
SECRET_GENERATOR = REPOSITORY_ROOT / "generate-secrets.yml"
VAULT_TEMPLATE = REPOSITORY_ROOT / "templates" / "vault-plain.yml.j2"

HASH = "$2b$10$" + "A" * 53
UUID_VALUE = "00000000-0000-4000-a000-000000000000"
AGENT_KEY = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIA=="
HUB_KEY = f"-----{OPENSSH_PRIVATE_KEY_MARKER}-----\nAAAA\n"

# One accepted value per pattern, and one rejected value that differs from it
# only after the point the pattern's end anchor. Together they are the anchoring
# guard: without that anchor the second value is accepted.
PATTERN_SAMPLES = {
    BCRYPT_HASH.pattern: (HASH, HASH + "x"),
    DATABASE_IDENTIFIER.pattern: ("platform_db", "platform_db;drop"),
    EMAIL.pattern: ("person@example.invalid", "person@example.invalid with words"),
    NTFY_TOKEN.pattern: ("tk_" + "a" * 29, "tk_" + "a" * 29 + "x"),
    SSH_ED25519_PUBLIC_KEY.pattern: (AGENT_KEY, AGENT_KEY + " comment"),
    UUID.pattern: (UUID_VALUE, UUID_VALUE + "-extra"),
    HEX_32.pattern: ("0" * 32, "0" * 32 + "x"),
}

# The non-string values the original conditions accepted, and the ones they
# rejected. Both halves were measured by driving the role's old and new tasks over
# the same vault documents; see the module docstring for why the accepted half is
# preserved rather than fixed.
LEGACY_ACCEPTED = (
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
    BCRYPT_HASH.pattern: "$2b$10$" + "A" * 52,
    DATABASE_IDENTIFIER.pattern: "9platform",
    EMAIL.pattern: "person.example.invalid",
    NTFY_TOKEN.pattern: "tk_" + "A" * 29,
    SSH_ED25519_PUBLIC_KEY.pattern: "ssh-rsa AAAAC3NzaC1lZDI1NTE5AAAAIA==",
    UUID.pattern: "00000000-0000-9000-a000-000000000000",
    HEX_32.pattern: "A" * 32,
}

FOUNDATION_KEYS = (
    "vault_arr_radarr_api_key",
    "vault_arr_radarr_admin_username",
    "vault_arr_radarr_admin_password",
    "vault_arr_sonarr_api_key",
    "vault_arr_sonarr_admin_username",
    "vault_arr_sonarr_admin_password",
    "vault_arr_prowlarr_api_key",
    "vault_arr_prowlarr_admin_username",
    "vault_arr_prowlarr_admin_password",
    "vault_arr_bazarr_api_key",
    "vault_arr_bazarr_admin_username",
    "vault_arr_bazarr_admin_password",
    "vault_downloaders_sabnzbd_api_key",
    "vault_downloaders_sabnzbd_admin_username",
    "vault_downloaders_sabnzbd_admin_password",
)
FOUNDATION_API_KEYS = FOUNDATION_KEYS[0::3]
FOUNDATION_USERNAMES = FOUNDATION_KEYS[1::3]
FOUNDATION_PASSWORDS = FOUNDATION_KEYS[2::3]
NTFY_DISTINCT_KEYS = DISTINCT_KEY_GROUPS[0]

# Bazarr's settings form is the only place a vault API key is cast with `int()`,
# and `acquisition_bazarr_connection_body` submits exactly these two. The other
# API keys never reach that cast, so requiring a letter of them would refuse a
# vault that deploys.
BAZARR_SUBMITTED_API_KEYS = ("vault_arr_radarr_api_key", "vault_arr_sonarr_api_key")
ALL_DIGIT_KEY = "1" * 32


def _valid_value(key, rules):
    """Build the accepted value for one credential from its own rules."""
    if key in FOUNDATION_API_KEYS:
        # Leading "a" rather than a bare index: the two keys this platform
        # submits to Bazarr must carry at least one a-f character, and an index
        # rendered as 32 hex digits carries none.
        return "a" + format(FOUNDATION_API_KEYS.index(key), "031x")
    if key in FOUNDATION_PASSWORDS:
        return f"foundation-password-{FOUNDATION_PASSWORDS.index(key)}"
    if key in NTFY_DISTINCT_KEYS:
        # The four publisher tokens have to differ from each other, so they are
        # keyed off their position rather than off the shared pattern sample.
        return "tk_" + "abcdefghijklmnopqrstuvwxyz012"[:28] + str(
            NTFY_DISTINCT_KEYS.index(key))
    for kind, argument in rules:
        if kind == PATTERN:
            return PATTERN_SAMPLES[argument.pattern][0]
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
            return PATTERN_SAMPLES[argument.pattern][1]
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


def run_ansible_playbook(document):
    with tempfile.TemporaryDirectory(prefix="vault-credential-schema-") as directory:
        directory = Path(directory)
        if callable(document):
            document = document(directory)
        playbook = directory / "playbook.yml"
        playbook.write_text(json.dumps(document))
        return subprocess.run(
            ["ansible-playbook", "-i", "localhost,", "-c", "local", str(playbook)],
            cwd=REPOSITORY_ROOT,
            capture_output=True,
            text=True,
            check=False,
        )


class VaultCredentialSchemaTest(unittest.TestCase):
    def test_foundation_credentials_are_present_in_the_exact_contract_order(self):
        for key in FOUNDATION_KEYS:
            with self.subTest(key):
                self.assertIn(key, CREDENTIAL_RULES)
        actual = tuple(key for key in CREDENTIAL_RULES if key in FOUNDATION_KEYS)
        self.assertEqual(actual, FOUNDATION_KEYS)

    def test_distinct_credential_groups_are_exact(self):
        self.assertEqual(
            DISTINCT_KEY_GROUPS,
            (NTFY_DISTINCT_KEYS, FOUNDATION_API_KEYS, FOUNDATION_PASSWORDS),
        )

    def test_foundation_api_keys_are_exactly_lowercase_hex_32(self):
        if not all(key in CREDENTIAL_RULES for key in FOUNDATION_API_KEYS):
            self.skipTest("foundation API rules are not implemented")
        for key in FOUNDATION_API_KEYS:
            for malformed in ("a" * 31, "A" * 32, "g" * 32):
                with self.subTest(f"{key}={malformed[:4]}"):
                    self.assertIn(key, keys_named(errors_for(**{key: malformed})))

    def test_foundation_api_keys_reject_a_terminal_newline(self):
        malformed = "a" * 32 + "\n"
        for key in FOUNDATION_API_KEYS:
            with self.subTest(key):
                self.assertIn(key, keys_named(errors_for(**{key: malformed})))

    def test_generator_api_patterns_reject_a_terminal_newline_under_ansible(self):
        source = SECRET_GENERATOR.read_text()
        patterns = re.findall(
            r"(?:arr_(?:radarr|sonarr|prowlarr|bazarr)|downloaders_sabnzbd)_api_key "
            r"is match\('([^']+)'\)",
            source,
        )
        self.assertEqual(len(patterns), 5)
        result = run_ansible_playbook([
            {
                "name": "Reject a terminal newline with each generated API-key pattern",
                "hosts": "localhost",
                "gather_facts": False,
                "vars": {
                    "malformed_api_key": "a" * 32 + "\n",
                    "foundation_api_patterns": patterns,
                },
                "tasks": [{
                    "ansible.builtin.assert": {
                        "that": ["malformed_api_key is not match(item)"],
                        "quiet": True,
                    },
                    "loop": "{{ foundation_api_patterns }}",
                    "no_log": True,
                }],
            }
        ])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_rendered_foundation_api_keys_remain_yaml_strings(self):
        template_lines = [
            line for line in VAULT_TEMPLATE.read_text().splitlines()
            if re.match(
                r"vault_(?:arr_(?:radarr|sonarr|prowlarr|bazarr)|"
                r"downloaders_sabnzbd)_api_key:",
                line,
            )
        ]
        self.assertEqual(len(template_lines), 5)
        variables = {
            key.removeprefix("vault_"): str(index) * 32
            for index, key in enumerate(FOUNDATION_API_KEYS)
        }

        def rendering_playbook(directory):
            source = directory / "foundation.yml.j2"
            rendered = directory / "foundation.yml"
            source.write_text("\n".join(template_lines) + "\n")
            assertions = []
            for key in FOUNDATION_API_KEYS:
                variable = key.removeprefix("vault_")
                assertions.extend([
                    f"rendered_foundation.{key} is string",
                    f"rendered_foundation.{key} == {variable}",
                ])
            return [{
                "name": "Render and parse foundation API keys",
                "hosts": "localhost",
                "gather_facts": False,
                "vars": variables,
                "tasks": [
                    {
                        "ansible.builtin.template": {
                            "src": str(source),
                            "dest": str(rendered),
                            "mode": "0600",
                        },
                        "no_log": True,
                    },
                    {
                        "ansible.builtin.set_fact": {
                            "rendered_foundation":
                                f"{{{{ lookup('file', '{rendered}') | from_yaml }}}}",
                        },
                        "no_log": True,
                    },
                    {
                        "ansible.builtin.assert": {
                            "that": assertions,
                            "quiet": True,
                        },
                        "no_log": True,
                    },
                ],
            }]

        result = run_ansible_playbook(rendering_playbook)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_foundation_usernames_and_passwords_have_only_the_nonempty_rule(self):
        keys = FOUNDATION_USERNAMES + FOUNDATION_PASSWORDS
        if not all(key in CREDENTIAL_RULES for key in keys):
            self.skipTest("foundation nonempty rules are not implemented")
        for key in keys:
            with self.subTest(key):
                self.assertEqual(CREDENTIAL_RULES[key], ((NONEMPTY, None),))
                self.assertEqual(errors_for(**{key: "x"}), [])

    def test_foundation_api_keys_must_all_differ(self):
        if not all(key in CREDENTIAL_RULES for key in FOUNDATION_API_KEYS):
            self.skipTest("foundation API rules are not implemented")
        shared = VALID[FOUNDATION_API_KEYS[0]]
        for key in FOUNDATION_API_KEYS[1:]:
            with self.subTest(key):
                errors = errors_for(**{key: shared})
                self.assertTrue(any("must all differ" in error for error in errors))

    def test_foundation_admin_passwords_must_all_differ(self):
        if not all(key in CREDENTIAL_RULES for key in FOUNDATION_PASSWORDS):
            self.skipTest("foundation password rules are not implemented")
        shared = VALID[FOUNDATION_PASSWORDS[0]]
        for key in FOUNDATION_PASSWORDS[1:]:
            with self.subTest(key):
                errors = errors_for(**{key: shared})
                self.assertTrue(any("must all differ" in error for error in errors))

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
                accepted, extended = PATTERN_SAMPLES[argument.pattern]
                if key in FOUNDATION_API_KEYS:
                    accepted = VALID[key]
                    extended = accepted + "x"
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
                                  errors_for(**{key: MALFORMED[argument.pattern]}))

    def test_only_the_bazarr_submitted_api_keys_require_a_hex_letter(self):
        # Pinned rather than derived: widening the rule to a key Bazarr never
        # sees would refuse a vault that deploys today, so it has to be a
        # deliberate edit here as well as in the table.
        carrying = tuple(key for key, rules in CREDENTIAL_RULES.items()
                         if any(kind == SEARCH for kind, _ in rules))
        self.assertEqual(carrying, BAZARR_SUBMITTED_API_KEYS)

    def test_the_bazarr_submitted_api_keys_reject_an_all_digit_value(self):
        for key in BAZARR_SUBMITTED_API_KEYS:
            with self.subTest(key):
                errors = errors_for(**{key: ALL_DIGIT_KEY})
                self.assertIn(key, keys_named(errors))
                self.assertTrue(
                    any(error.startswith(f"{key}: must contain at least one a-f")
                        for error in errors),
                    errors,
                )

    def test_the_other_api_keys_accept_an_all_digit_value(self):
        for key in FOUNDATION_API_KEYS:
            if key in BAZARR_SUBMITTED_API_KEYS:
                continue
            with self.subTest(key):
                self.assertEqual(errors_for(**{key: ALL_DIGIT_KEY}), [])
        self.assertEqual(errors_for(vault_bindery_api_key=ALL_DIGIT_KEY), [])

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
        for key in NTFY_DISTINCT_KEYS[1:]:
            with self.subTest(key):
                errors = errors_for(**{key: shared})
                self.assertTrue(any("must all differ" in error
                                    for error in errors),
                                f"{key} was allowed to duplicate a token")

    def test_distinct_publisher_tokens_are_accepted(self):
        self.assertEqual(len({VALID[key] for key in NTFY_DISTINCT_KEYS}),
                         len(NTFY_DISTINCT_KEYS))
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

    def test_every_optional_group_key_has_rules_of_its_own(self):
        # A key in a group but not in the table would have nothing suppressed,
        # and a group is only meaningful as a set of rules to switch off.
        for key_group in OPTIONAL_KEY_GROUPS:
            for key in key_group:
                with self.subTest(key):
                    self.assertIn(key, CREDENTIAL_RULES)

    def test_an_entirely_undeclared_optional_group_is_accepted(self):
        # The state that broke a production converge: the operator owns no
        # Usenet subscription, so all six provider keys are the empty strings
        # inventory/group_vars/all/main.yml declares.
        for key_group in OPTIONAL_KEY_GROUPS:
            with self.subTest(key_group):
                self.assertEqual(
                    errors_for(**{key: "" for key in key_group}), [])

    def test_a_partly_declared_optional_group_is_reported_field_by_field(self):
        # One declared value means a provider is being declared, so every other
        # field of the group is named. Suppression is all-or-nothing precisely so
        # that a forgotten field cannot ride in behind a declared one.
        for key_group in OPTIONAL_KEY_GROUPS:
            for declared in key_group:
                with self.subTest(declared):
                    blank = {key: "" for key in key_group}
                    blank[declared] = VALID[declared]
                    named = keys_named(errors_for(**blank))
                    self.assertEqual(named, set(key_group) - {declared})

    def test_a_fully_declared_optional_group_is_held_to_every_rule(self):
        # Suppression must not survive a declaration: each field's own rule has
        # to fire again once the group is declared.
        for key_group in OPTIONAL_KEY_GROUPS:
            for key in key_group:
                with self.subTest(key):
                    rejected = _rejected_value(key, CREDENTIAL_RULES[key])
                    self.assertIn(key, keys_named(errors_for(**{key: rejected})))

    def test_an_optional_group_key_with_no_length_is_still_declared(self):
        # `none` has no length to measure, so it must not read as a declaration
        # of nothing; NONEMPTY reports it instead of the group going quiet.
        for key_group in OPTIONAL_KEY_GROUPS:
            with self.subTest(key_group):
                blank = {key: "" for key in key_group}
                blank[key_group[0]] = None
                self.assertTrue(errors_for(**blank))

    def test_the_role_submits_every_credential_the_table_covers(self):
        # The mapping in the role is what states the key set under validation, so
        # a rule with nothing submitting to it would never run.
        tasks = ROLE_TASKS.read_text()
        for key in CREDENTIAL_RULES:
            with self.subTest(key):
                self.assertIn(f"'{key}': {key}", tasks)


if __name__ == "__main__":
    unittest.main(verbosity=2)
