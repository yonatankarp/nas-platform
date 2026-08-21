"""Schema validation for the Immich managed-user preference structures.

`roles/vault_contract` previously expressed this as 71 Jinja conditions across
two `assert` tasks: one validating the four preference collections and their
cross-references, one looping every profile and override through a 55-condition
field schema. Both ran under `no_log` with a generic `fail_msg`, so a single
mistyped field reported only that something in the Immich preferences was wrong.

This module keeps the same rules as a declarative table and reports which field
failed, by path. It follows `vault_managed_user_schema` in never putting a value
in a message, and adds one rule that module does not need: **no key is named
either**. The preference collections are keyed by managed-user email, and a
profile name can be attacker-chosen through the vault, so a path is built from
the key's position rather than its text. `tests/managed_users_vault_test.rb`
enforces this by asserting the rejected value never appears in the output.

Semantics are matched to Ansible's Jinja tests, verified on ansible-core 2.21.2:
`is integer` rejects booleans, `is boolean` rejects integers, and `is string`
rejects None. Every preference field is optional, because the original conditions
read `field | default(<literal>)` before testing; `default` substitutes only for
an undefined key, so a key present and null was rejected then and is rejected
here. A non-string compared against an enum also failed, since `5 in ['asc',
'desc']` is false rather than an error, which is why `_field` reports the type
before the membership.
"""

BOOLEAN = "boolean"
POSITIVE_INTEGER = "positive_integer"
STRING = "string"
ENUM = "enum"

AVATAR_COLORS = ("primary", "pink", "red", "yellow", "blue", "green", "purple",
                 "orange", "gray", "amber")
ASSET_ORDERS = ("asc", "desc")

# Every scope is optional, and so is every field within it. The allowed sets here
# are literals from the Immich API, not vault data, so naming them in an error is
# safe; a set derived from vault data never is.
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


def _is_string(value):
    return isinstance(value, str)


def _is_boolean(value):
    return isinstance(value, bool)


def _is_integer(value):
    return isinstance(value, int) and not isinstance(value, bool)


def _is_mapping(value):
    return isinstance(value, dict)


def _normalize(value):
    return value.strip().lower()


def _unsupported(errors, path, value, allowed, noun):
    """Report unsupported keys by count, because a key can carry a value."""
    unknown = [key for key in value if key not in allowed]
    if unknown:
        errors.append(f"{path}: contains {len(unknown)} unsupported {noun}"
                      f"{'' if len(unknown) == 1 else 's'}")


def _field(errors, path, value, kind, allowed):
    if kind is BOOLEAN:
        if not _is_boolean(value):
            errors.append(f"{path}: must be a boolean")
    elif kind is POSITIVE_INTEGER:
        if not _is_integer(value):
            errors.append(f"{path}: must be an integer")
        elif value <= 0:
            errors.append(f"{path}: must be greater than zero")
    elif kind is STRING:
        if not _is_string(value):
            errors.append(f"{path}: must be a string")
    elif kind is ENUM:
        if not _is_string(value):
            errors.append(f"{path}: must be a string")
        elif value not in allowed:
            errors.append(f"{path}: must be one of {', '.join(allowed)}")


def _preferences(errors, path, value):
    """Validate one preference mapping, whether it is a profile or an override."""
    if not _is_mapping(value):
        errors.append(f"{path}: must be a mapping")
        return
    _unsupported(errors, path, value, SCOPES, "field")
    for scope, fields in SCOPES.items():
        if scope not in value:
            continue
        scoped = value[scope]
        scope_path = f"{path}.{scope}"
        if not _is_mapping(scoped):
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
    if not _is_mapping(value):
        errors.append(f"{label}: must be a mapping")
        return
    for index, (key, item) in enumerate(value.items()):
        if not _is_string(key):
            errors.append(f"{label}[{index}]: key must be a string")
        if string_values and not _is_string(item):
            errors.append(f"{label}[{index}]: must be a string")


def _selector_keys(errors, label, value, managed_emails):
    """Require selector keys to be unique and to name a managed user."""
    keys = [key for key in value if _is_string(key)]
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
    declared = _is_mapping(profiles)

    if not _is_string(profile_default):
        errors.append("profile_default: must be a string")
    elif not declared or profile_default not in profiles:
        # Neither the rejected name nor the declared names are reported: a
        # profile name reaches this through the vault.
        errors.append("profile_default: is not a declared profile")

    normalized_emails = {_normalize(email) for email in (managed_emails or [])
                         if _is_string(email)}

    if _is_mapping(profile_by_email):
        _selector_keys(errors, "profile_by_email", profile_by_email,
                       normalized_emails)
        for index, selected in enumerate(profile_by_email.values()):
            if _is_string(selected) and not (declared and selected in profiles):
                errors.append(f"profile_by_email[{index}]: "
                              f"is not a declared profile")

    if _is_mapping(overrides):
        _selector_keys(errors, "overrides", overrides, normalized_emails)

    for label, collection in (("profiles", profiles), ("overrides", overrides)):
        if not _is_mapping(collection):
            continue
        for index, preferences in enumerate(collection.values()):
            _preferences(errors, f"{label}[{index}]", preferences)

    return errors


class FilterModule:
    """Expose the Immich preference schema validator to Ansible."""

    def filters(self):
        return {"immich_preference_errors": immich_preference_errors}
