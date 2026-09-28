"""Schema validation for the Immich managed-user preference structures.

Reports failing fields by path, never a value and never a key: collections are keyed
by email and profile names come from the vault, so paths use positions
(tests/managed_users_vault_test.rb). Jinja semantics are matched: `is integer` rejects
booleans, `is boolean` rejects integers, `is string` rejects None; null is rejected.
"""

import runpy
from pathlib import Path
from types import SimpleNamespace

from ansible.errors import AnsibleFilterError


# module_utils/ is run by file path, never via sys.path: tests/policy_test.rb
# says why, and fails any filter plugin that touches it.
_MODULE_UTILS = Path(__file__).resolve().parents[1] / "module_utils"
_GUARDS = SimpleNamespace(**runpy.run_path(str(_MODULE_UTILS / "schema_guards.py")))


BOOLEAN = "boolean"
POSITIVE_INTEGER = "positive_integer"
STRING = "string"
ENUM = "enum"

AVATAR_COLORS = ("primary", "pink", "red", "yellow", "blue", "green", "purple",
                 "orange", "gray", "amber")
ASSET_ORDERS = ("asc", "desc")

# Allowed sets are Immich API literals, so naming them in an error is safe.
SCOPES = {
    "albums": {"defaultAssetOrder": (ENUM, ASSET_ORDERS)},
    "avatar": {"color": (ENUM, AVATAR_COLORS)},
    "cast": {"gCastEnabled": (BOOLEAN, None)},
    "download": {"archiveSize": (POSITIVE_INTEGER, None),
                 "includeEmbeddedVideos": (BOOLEAN, None)},
    "emailNotifications": {"enabled": (BOOLEAN, None),
                           "albumInvite": (BOOLEAN, None),
                           "albumUpdate": (BOOLEAN, None)},
    "folders": {"enabled": (BOOLEAN, None), "sidebarWeb": (BOOLEAN, None)},
    "memories": {"enabled": (BOOLEAN, None), "duration": (POSITIVE_INTEGER, None)},
    "people": {"enabled": (BOOLEAN, None), "sidebarWeb": (BOOLEAN, None),
               "minimumFaces": (POSITIVE_INTEGER, None)},
    "purchase": {"showSupportBadge": (BOOLEAN, None),
                 "hideBuyButtonUntil": (STRING, None)},
    "ratings": {"enabled": (BOOLEAN, None)},
    "recentlyAdded": {"sidebarWeb": (BOOLEAN, None)},
    "sharedLinks": {"enabled": (BOOLEAN, None), "sidebarWeb": (BOOLEAN, None)},
    "tags": {"enabled": (BOOLEAN, None), "sidebarWeb": (BOOLEAN, None)},
}


def _normalize(value):
    return value.strip().lower()


def _unsupported(errors, path, value, allowed, noun):
    """Report unsupported keys by count, because a key can carry a value."""
    unknown = [key for key in value if key not in allowed]
    if unknown:
        errors.append(f"{path}: contains {len(unknown)} unsupported {noun}"
                      f"{'' if len(unknown) == 1 else 's'}")


def _field(errors, path, value, kind, allowed):
    # `==` not `is`, and an unknown kind raises rather than validating nothing (#648).
    if kind == BOOLEAN:
        if not _GUARDS.is_boolean(value):
            errors.append(f"{path}: must be a boolean")
    elif kind == POSITIVE_INTEGER:
        if not _GUARDS.is_integer(value):
            errors.append(f"{path}: must be an integer")
        elif value <= 0:
            errors.append(f"{path}: must be greater than zero")
    elif kind == STRING:
        if not _GUARDS.is_string(value):
            errors.append(f"{path}: must be a string")
    elif kind == ENUM:
        if not _GUARDS.is_string(value):
            errors.append(f"{path}: must be a string")
        elif value not in allowed:
            errors.append(f"{path}: must be one of {', '.join(allowed)}")
    else:
        # Safe to name: every kind here is a literal from SCOPES.
        raise AnsibleFilterError(f"{path}: unknown field kind {kind!r}")


def _preferences(errors, path, value):
    """Validate one preference mapping, whether it is a profile or an override."""
    if not _GUARDS.is_mapping(value):
        errors.append(f"{path}: must be a mapping")
        return
    _unsupported(errors, path, value, SCOPES, "field")
    for scope, fields in SCOPES.items():
        if scope not in value:
            continue
        scoped = value[scope]
        scope_path = f"{path}.{scope}"
        if not _GUARDS.is_mapping(scoped):
            errors.append(f"{scope_path}: must be a mapping")
            continue
        _unsupported(errors, scope_path, scoped, fields, "field")
        for field, (kind, allowed) in fields.items():
            if field in scoped:
                _field(errors, f"{scope_path}.{field}", scoped[field], kind, allowed)


def _collection(errors, label, value, *, string_values=False):
    """Validate one keyed collection's shape, reporting positions not keys.

    Mapping values are left to `_preferences`, which reports the same failure
    with a scoped path, so one malformed profile does not stop the others from
    being validated.
    """
    if not _GUARDS.is_mapping(value):
        errors.append(f"{label}: must be a mapping")
        return
    for index, (key, item) in enumerate(value.items()):
        if not _GUARDS.is_string(key):
            errors.append(f"{label}[{index}]: key must be a string")
        if string_values and not _GUARDS.is_string(item):
            errors.append(f"{label}[{index}]: must be a string")


def _selector_keys(errors, label, value, managed_emails):
    """Require selector keys to be unique and to name a managed user."""
    keys = [key for key in value if _GUARDS.is_string(key)]
    normalized = [_normalize(key) for key in keys]
    if len(set(normalized)) != len(normalized):
        errors.append(f"{label}: keys must be unique after normalization")
    for index, key in enumerate(keys):
        if _normalize(key) not in managed_emails:
            errors.append(f"{label}[{index}]: does not name a managed Immich user")


def immich_preference_errors(profiles, overrides=None, profile_by_email=None,
                             profile_default=None, managed_emails=None):
    """Return every Immich preference violation, as field paths.

    Never includes a key or a value, so the result is safe to print from a
    `fail_msg`. An empty list means the structure satisfies the contract.
    """
    errors = []
    overrides = {} if overrides is None else overrides
    profile_by_email = {} if profile_by_email is None else profile_by_email

    _collection(errors, "profiles", profiles)
    _collection(errors, "overrides", overrides)
    _collection(errors, "profile_by_email", profile_by_email, string_values=True)
    declared = _GUARDS.is_mapping(profiles)

    if not _GUARDS.is_string(profile_default):
        errors.append("profile_default: must be a string")
    elif not declared or profile_default not in profiles:
        # Neither the rejected name nor the declared names are reported: a
        # profile name reaches this through the vault.
        errors.append("profile_default: is not a declared profile")

    normalized_emails = {_normalize(email) for email in (managed_emails or [])
                         if _GUARDS.is_string(email)}

    if _GUARDS.is_mapping(profile_by_email):
        _selector_keys(errors, "profile_by_email", profile_by_email,
                       normalized_emails)
        for index, selected in enumerate(profile_by_email.values()):
            if _GUARDS.is_string(selected) and not (declared and selected in profiles):
                errors.append(f"profile_by_email[{index}]: "
                              f"is not a declared profile")

    if _GUARDS.is_mapping(overrides):
        _selector_keys(errors, "overrides", overrides, normalized_emails)

    for label, collection in (("profiles", profiles), ("overrides", overrides)):
        if not _GUARDS.is_mapping(collection):
            continue
        for index, preferences in enumerate(collection.values()):
            _preferences(errors, f"{label}[{index}]", preferences)

    return errors


class FilterModule:
    """Expose the Immich preference schema validator to Ansible."""

    def filters(self):
        return {"immich_preference_errors": immich_preference_errors}
