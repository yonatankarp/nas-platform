"""The one identity-ambiguity decision the HTTP-driven managed-user roles share.

The managed identity must select at most one listed user, and no other listed
user may collide with it under trim-and-lowercase folding -- otherwise a repair
could land on the wrong record. Everything else (identifier regexes, match
resolution, completeness, authentication, repair, phase gates) differs per
service and deliberately stays in the roles (#143).

Returned strings name only the API attribute and a count, never an identity or
listing value, so callers may print them from a `fail_msg` under `no_log`.
"""

import runpy
from pathlib import Path
from types import SimpleNamespace


# module_utils/ is run by file path, never via sys.path: tests/policy_test.rb
# says why, and fails any filter plugin that touches it.
_MODULE_UTILS = Path(__file__).resolve().parents[1] / "module_utils"
_GUARDS = SimpleNamespace(**runpy.run_path(str(_MODULE_UTILS / "schema_guards.py")))


def _normalize(value):
    """Jinja's `trim | lower`, which is `str.strip()` then `str.lower()`.

    Must agree with `vault_managed_user_schema._normalized_identities`; a test
    pins the two together.
    """
    return value.strip().lower()


def managed_user_ambiguity_errors(listing, attribute, identity, matches):
    """Return every ambiguity violation for one managed identity, as text.

    An empty list means exactly one listed user answers to this identity, or
    none does and the role may create it.
    """
    attribute = _GUARDS.string(attribute, "managed user identity attribute")
    identity = _GUARDS.string(identity, f"managed user {attribute}")
    listing = _GUARDS.sequence(listing, "managed user listing", noun="a list")
    matches = _GUARDS.sequence(
        matches, f"resolved {attribute} matches", noun="a list"
    )

    errors = []
    if len(matches) > 1:
        errors.append(
            f"{attribute}: {len(matches)} listed users match this managed "
            "identity, and at most one may"
        )

    unreadable = []
    normalized = 0
    for index, entry in enumerate(listing):
        if not _GUARDS.is_mapping(entry):
            unreadable.append(f"listed user {index}: must be a mapping")
            continue
        value = entry.get(attribute)
        if not _GUARDS.is_string(value):
            # Jinja's `trim` renders a missing or null attribute as the literal
            # "None", which folds to "none" and can collide with a real
            # identity. Refusing the listing is the only safe reading.
            unreadable.append(
                f"listed user {index}: {attribute} must be a string"
            )
            continue
        if _normalize(value) == _normalize(identity):
            normalized += 1

    # A listing this module cannot read is reported as itself; the collision
    # count derived from it would be an understatement, so it is not reported.
    if unreadable:
        return errors + unreadable
    if normalized != len(matches):
        errors.append(
            f"{attribute}: {normalized} listed users normalize to this managed "
            f"identity but {len(matches)} match it, so a repair could land on "
            "the wrong record"
        )

    return errors


class FilterModule:
    """Expose the shared managed-user ambiguity decision to Ansible."""

    def filters(self):
        return {"managed_user_ambiguity_errors": managed_user_ambiguity_errors}
