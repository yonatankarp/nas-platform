"""Schema validation for the managed-user structures carried in the vault.

`roles/vault_contract` previously expressed this as 127 Jinja conditions spread
over eleven `assert` tasks. Each condition could only report that *something* in
a 26-condition assert was wrong, because the values are credential material and
the tasks run under `no_log`.

This module keeps the same rules as a declarative table and reports which field
failed, by path, without ever putting a value in the message. `no_log` on an
`assert` does not suppress `fail_msg`, so naming the field is what turns
"audiobookshelf managed user has invalid field" into
"audiobookshelf[2].permissions.flags.download: must be a boolean".

Semantics are matched to Ansible's Jinja tests, verified on ansible-core 2.21.3:
`is integer` rejects booleans, `is boolean` rejects integers, `is string` rejects
None and ints, and `is match` anchors at the start only, so patterns needing a
full match carry their own `$`.
"""

import importlib.util
import re
from pathlib import Path


# Filter plugins cannot import module_utils/ by name, and putting the repository
# root on sys.path to reach it would shadow site-packages with library/, roles/,
# services/ and tests/ for the whole Ansible process. Loading the file by path
# shares the guards with no global side effect. tests/policy_test.rb executes
# every filter plugin and fails if one of them touches sys.path.
_GUARDS_SPEC = importlib.util.spec_from_file_location(
    "nas_platform_schema_guards",
    Path(__file__).resolve().parents[1] / "module_utils" / "schema_guards.py",
)
_GUARDS = importlib.util.module_from_spec(_GUARDS_SPEC)
_GUARDS_SPEC.loader.exec_module(_GUARDS)


BCRYPT_HASH = re.compile(r"^\$2[aby]\$[0-9]{2}\$[./A-Za-z0-9]{53}")
EMAIL = re.compile(r"^[^@ ]+@[^@ ]+$")
NTFY_USERNAME = re.compile(r"^[-_.+@A-Za-z0-9]+$")
NTFY_TOKEN = re.compile(r"^tk_[a-z0-9]{29}$")
NTFY_TOPIC = re.compile(r"^[-_A-Za-z0-9]{1,64}$")
NONEMPTY = re.compile(r".+")

SERVICES = ("audiobookshelf", "beszel", "dozzle", "immich", "jellyfin",
            "komga", "ntfy", "paperless_ngx")
NONEMPTY_SERVICES = ("immich",)

# Which field carries the identity a service uniques on. The role previously
# spelled out one uniqueness condition per service, and each one repeated the
# same trim-and-lower normalization.
IDENTITY_FIELDS = {
    "audiobookshelf": "username",
    "beszel": "email",
    "dozzle": "username",
    "immich": "email",
    "jellyfin": "username",
    "komga": "email",
    "ntfy": "username",
    "paperless_ngx": "username",
}

AUDIOBOOKSHELF_FLAGS = ("download", "update", "delete", "upload", "createEreader",
                        "accessAllLibraries", "accessAllTags", "accessExplicitContent",
                        "selectedTagsNotAccessible")
KOMGA_ROLES = ("ADMIN", "FILE_DOWNLOAD", "PAGE_STREAMING", "KOBO_SYNC", "KOREADER_SYNC")
JELLYFIN_POLICY_FIELDS = (
    "IsAdministrator", "IsHidden", "EnableCollectionManagement",
    "EnableSubtitleManagement", "EnableLyricManagement", "IsDisabled",
    "EnableUserPreferenceAccess", "EnableRemoteControlOfOtherUsers",
    "EnableSharedDeviceControl", "EnableRemoteAccess", "EnableLiveTvManagement",
    "EnableLiveTvAccess", "EnableMediaPlayback", "EnableAudioPlaybackTranscoding",
    "EnableVideoPlaybackTranscoding", "EnablePlaybackRemuxing",
    "ForceRemoteSourceTranscoding", "EnableContentDeletion",
    "EnableContentDownloading", "EnableSyncTranscoding", "EnableMediaConversion",
    "EnableAllDevices", "EnableAllChannels", "EnableAllFolders", "EnablePublicSharing",
)
JELLYFIN_FORBIDDEN_POLICY_FIELDS = (
    "password", "passwordhash", "password_hash", "passwordconfirm",
    "password_confirmation", "token", "access_token", "secret", "credential",
    "api_key", "apikey",
)
NTFY_PERMISSIONS = ("read-only", "write-only", "read-write", "deny")


def string(errors, path, value, *, pattern=None, trimmed_nonempty=False,
           nonempty=False, allowed=None, empty_or_pattern=None):
    """Validate one string field, appending a path-qualified error per failure."""
    if not _GUARDS.is_string(value):
        errors.append(f"{path}: must be a string")
        return
    if trimmed_nonempty and not value.strip():
        errors.append(f"{path}: must not be blank")
    if nonempty and not value:
        errors.append(f"{path}: must not be empty")
    if pattern is not None and not pattern.match(value):
        errors.append(f"{path}: does not match the required format")
    if empty_or_pattern is not None and value and not empty_or_pattern.match(value):
        errors.append(f"{path}: must be empty or match the required format")
    if allowed is not None and value not in allowed:
        errors.append(f"{path}: must be one of {', '.join(allowed)}")


def string_list(errors, path, value, *, unique=False, nonempty_items=False,
                allowed=None, item_pattern=None, nonempty=False):
    if not _GUARDS.is_list(value):
        errors.append(f"{path}: must be a list")
        return
    if nonempty and not value:
        errors.append(f"{path}: must not be empty")
    if any(not _GUARDS.is_string(item) for item in value):
        errors.append(f"{path}: every entry must be a string")
        return
    if nonempty_items and any(not item for item in value):
        errors.append(f"{path}: entries must not be empty")
    if unique and len(set(value)) != len(value):
        errors.append(f"{path}: entries must be unique")
    if allowed is not None:
        unknown = [item for item in value if item not in allowed]
        if unknown:
            errors.append(f"{path}: contains {len(unknown)} unsupported entr"
                          f"{'y' if len(unknown) == 1 else 'ies'}")
    if item_pattern is not None and any(not item_pattern.match(item) for item in value):
        errors.append(f"{path}: entries do not match the required format")


def exact_keys(errors, path, value, expected):
    if not _GUARDS.is_mapping(value):
        errors.append(f"{path}: must be a mapping")
        return False
    actual = sorted(value.keys(), key=str)
    if actual != sorted(expected):
        missing = [key for key in expected if key not in value]
        extra = [key for key in value if key not in expected]
        if missing:
            errors.append(f"{path}: missing {', '.join(map(str, missing))}")
        if extra:
            errors.append(f"{path}: unexpected {', '.join(map(str, extra))}")
        if not missing and not extra:
            errors.append(f"{path}: key set is invalid")
        return False
    return True


def boolean_flags(errors, path, value, allowed):
    if not _GUARDS.is_mapping(value):
        errors.append(f"{path}: must be a mapping")
        return
    if any(not _GUARDS.is_string(key) for key in value):
        errors.append(f"{path}: every key must be a string")
        return
    unknown = [key for key in value if key not in allowed]
    if unknown:
        errors.append(f"{path}: contains {len(unknown)} unsupported flag"
                      f"{'' if len(unknown) == 1 else 's'}")
    for key, flag in value.items():
        if not _GUARDS.is_boolean(flag):
            errors.append(f"{path}.{key}: must be a boolean")


def _audiobookshelf(errors, path, entry):
    if not exact_keys(errors, path, entry,
                      ["username", "password", "type", "is_active", "permissions"]):
        return
    string(errors, f"{path}.username", entry["username"], trimmed_nonempty=True)
    string(errors, f"{path}.password", entry["password"], nonempty=True)
    string(errors, f"{path}.type", entry["type"], allowed=("admin", "user", "guest"))
    if not _GUARDS.is_boolean(entry["is_active"]):
        errors.append(f"{path}.is_active: must be a boolean")
    elif not entry["is_active"]:
        errors.append(f"{path}.is_active: must be true")
    permissions = entry["permissions"]
    if not exact_keys(errors, f"{path}.permissions", permissions,
                      ["flags", "librariesAccessible", "itemTagsSelected"]):
        return
    boolean_flags(errors, f"{path}.permissions.flags", permissions["flags"],
                  AUDIOBOOKSHELF_FLAGS)
    for field in ("librariesAccessible", "itemTagsSelected"):
        string_list(errors, f"{path}.permissions.{field}", permissions[field],
                    unique=True, nonempty_items=True)


def _beszel(errors, path, entry):
    if not exact_keys(errors, path, entry, ["email", "password", "role", "verified"]):
        return
    string(errors, f"{path}.email", entry["email"], pattern=EMAIL)
    string(errors, f"{path}.password", entry["password"], nonempty=True)
    string(errors, f"{path}.role", entry["role"], allowed=("user", "admin"))
    if not _GUARDS.is_boolean(entry["verified"]):
        errors.append(f"{path}.verified: must be a boolean")
    elif entry["verified"] is not True:
        errors.append(f"{path}.verified: must be true")


def _dozzle(errors, path, entry):
    if not exact_keys(errors, path, entry, ["username", "password", "password_hash",
                                            "email", "name", "filter", "roles"]):
        return
    string(errors, f"{path}.username", entry["username"], trimmed_nonempty=True)
    string(errors, f"{path}.password", entry["password"], nonempty=True)
    string(errors, f"{path}.password_hash", entry["password_hash"], pattern=BCRYPT_HASH)
    string(errors, f"{path}.email", entry["email"], empty_or_pattern=EMAIL)
    string(errors, f"{path}.name", entry["name"], nonempty=True)
    string(errors, f"{path}.filter", entry["filter"])
    string(errors, f"{path}.roles", entry["roles"], allowed=("none", "user", "admin"))


def _immich(errors, path, entry):
    if not exact_keys(errors, path, entry, ["email", "password", "name", "quota_size"]):
        return
    string(errors, f"{path}.email", entry["email"], pattern=EMAIL)
    string(errors, f"{path}.password", entry["password"], nonempty=True)
    string(errors, f"{path}.name", entry["name"], nonempty=True)
    # null is Immich's own representation of an unlimited quota, and the only
    # value that expresses one. The server skips the check entirely when
    # quotaSizeInBytes is null; 0 is the opposite of unlimited and rejects every
    # upload of a non-empty file.
    if entry["quota_size"] is not None:
        if not _GUARDS.is_integer(entry["quota_size"]):
            errors.append(f"{path}.quota_size: must be an integer or null")
        elif entry["quota_size"] < 0:
            errors.append(f"{path}.quota_size: must not be negative")
        elif entry["quota_size"] == 0:
            # 0 is rejected rather than merely documented because its only
            # effect is to refuse every upload of a non-empty file, and it does
            # so silently -- the client reports a failure, the server logs
            # "Quota has been exceeded!", and nothing names the quota. Failing
            # the run is the loud version of a state nobody wants.
            errors.append(
                f"{path}.quota_size: must not be 0, which rejects every upload "
                "of a non-empty file; use null for no limit"
            )


def _jellyfin(errors, path, entry):
    if not exact_keys(errors, path, entry, ["username", "password", "policy"]):
        return
    string(errors, f"{path}.username", entry["username"], trimmed_nonempty=True)
    string(errors, f"{path}.password", entry["password"], nonempty=True)
    policy = entry["policy"]
    if not _GUARDS.is_mapping(policy):
        errors.append(f"{path}.policy: must be a mapping")
        return
    if any(not _GUARDS.is_string(key) for key in policy):
        errors.append(f"{path}.policy: every key must be a string")
        return
    if not policy:
        errors.append(f"{path}.policy: must not be empty")
    unknown = [key for key in policy if key not in JELLYFIN_POLICY_FIELDS]
    if unknown:
        errors.append(f"{path}.policy: contains {len(unknown)} unsupported field"
                      f"{'' if len(unknown) == 1 else 's'}")
    for key, flag in policy.items():
        if not _GUARDS.is_boolean(flag):
            errors.append(f"{path}.policy.{key}: must be a boolean")
    if policy.get("IsDisabled", False) is not False:
        errors.append(f"{path}.policy.IsDisabled: must be false")
    # Defence in depth only: no forbidden name currently appears in
    # JELLYFIN_POLICY_FIELDS, so the unsupported-field rule above already rejects
    # every one of them. This fires only if the supported list ever grows a
    # credential-ish key, which is exactly when it matters. The original role
    # carried the same redundancy.
    forbidden = [key for key in policy
                 if key.lower() in JELLYFIN_FORBIDDEN_POLICY_FIELDS]
    if forbidden:
        errors.append(f"{path}.policy: must not carry credential fields")


def _komga(errors, path, entry):
    if not exact_keys(errors, path, entry, ["email", "password", "roles"]):
        return
    string(errors, f"{path}.email", entry["email"], pattern=EMAIL)
    string(errors, f"{path}.password", entry["password"], nonempty=True)
    string_list(errors, f"{path}.roles", entry["roles"], unique=True, nonempty=True,
                allowed=KOMGA_ROLES)


def _ntfy(errors, path, entry):
    if not exact_keys(errors, path, entry, ["username", "password", "password_hash",
                                            "role", "access", "tokens"]):
        return
    string(errors, f"{path}.username", entry["username"], pattern=NTFY_USERNAME)
    string(errors, f"{path}.password", entry["password"], nonempty=True)
    string(errors, f"{path}.password_hash", entry["password_hash"], pattern=BCRYPT_HASH)
    string(errors, f"{path}.role", entry["role"], allowed=("user",))
    if not _GUARDS.is_list(entry["access"]):
        errors.append(f"{path}.access: must be a list")
    else:
        for index, access in enumerate(entry["access"]):
            access_path = f"{path}.access[{index}]"
            if not exact_keys(errors, access_path, access, ["topic", "permission"]):
                continue
            string(errors, f"{access_path}.topic", access["topic"], pattern=NTFY_TOPIC)
            string(errors, f"{access_path}.permission", access["permission"],
                   allowed=NTFY_PERMISSIONS)
    string_list(errors, f"{path}.tokens", entry["tokens"], unique=True,
                item_pattern=NTFY_TOKEN)


def _paperless_ngx(errors, path, entry):
    if not exact_keys(errors, path, entry, ["username", "password", "email", "is_active",
                                            "is_staff", "is_superuser", "groups"]):
        return
    string(errors, f"{path}.username", entry["username"], trimmed_nonempty=True)
    string(errors, f"{path}.password", entry["password"], nonempty=True)
    string(errors, f"{path}.email", entry["email"], pattern=EMAIL)
    if not _GUARDS.is_boolean(entry["is_active"]):
        errors.append(f"{path}.is_active: must be a boolean")
    elif not entry["is_active"]:
        errors.append(f"{path}.is_active: must be true")
    for field in ("is_staff", "is_superuser"):
        if not _GUARDS.is_boolean(entry[field]):
            errors.append(f"{path}.{field}: must be a boolean")
    string_list(errors, f"{path}.groups", entry["groups"], unique=True,
                item_pattern=NONEMPTY)


ENTRY_VALIDATORS = {
    "audiobookshelf": _audiobookshelf,
    "beszel": _beszel,
    "dozzle": _dozzle,
    "immich": _immich,
    "jellyfin": _jellyfin,
    "komga": _komga,
    "ntfy": _ntfy,
    "paperless_ngx": _paperless_ngx,
}


def vault_managed_user_errors(value, reserved_ntfy_tokens=None,
                              reserved_identities=None):
    """Return every schema violation in `vault_managed_users`, as field paths.

    Never includes a value, so the result is safe to print from a `fail_msg`.
    An empty list means the structure satisfies the contract.

    `reserved_identities` maps a service to the identities a managed user may not
    claim: the service administrator, plus any name the platform owns itself.
    """
    errors = []
    if not _GUARDS.is_mapping(value):
        return ["vault_managed_users: must be a mapping"]
    if sorted(map(str, value.keys())) != sorted(SERVICES):
        missing = [name for name in SERVICES if name not in value]
        extra = [name for name in value if name not in SERVICES]
        if missing:
            errors.append(f"vault_managed_users: missing {', '.join(missing)}")
        if extra:
            errors.append(f"vault_managed_users: unexpected "
                          f"{', '.join(map(str, extra))}")
        if not missing and not extra:
            errors.append("vault_managed_users: service key set is invalid")
        return errors

    for service in SERVICES:
        entries = value[service]
        if not _GUARDS.is_list(entries):
            errors.append(f"vault_managed_users.{service}: must be a list")
            continue
        if service in NONEMPTY_SERVICES and not entries:
            errors.append(f"vault_managed_users.{service}: must not be empty")
        validate = ENTRY_VALIDATORS[service]
        for index, entry in enumerate(entries):
            validate(errors, f"{service}[{index}]", entry)

    errors.extend(_ntfy_token_ownership(value, reserved_ntfy_tokens))
    errors.extend(_identity_ownership(value, reserved_identities))
    return errors


def _normalized_identities(entries, field):
    return [entry[field].strip().lower() for entry in entries
            if _GUARDS.is_mapping(entry) and _GUARDS.is_string(entry.get(field))]


def _identity_ownership(value, reserved_identities):
    """Require identities to be unique per service and not platform-owned.

    Normalization is trim-and-lower, matching the `map('trim') | map('lower')`
    chain the role used. Neither the duplicate nor the reserved identity is
    named: both are credential material.
    """
    errors = []
    reserved_identities = reserved_identities or {}
    for service, field in IDENTITY_FIELDS.items():
        entries = value.get(service)
        if not _GUARDS.is_list(entries):
            continue
        identities = _normalized_identities(entries, field)
        if len(set(identities)) != len(identities):
            errors.append(f"vault_managed_users.{service}: {field} must be "
                          f"unique after normalization")
        reserved = {name.strip().lower()
                    for name in reserved_identities.get(service, [])
                    if _GUARDS.is_string(name)}
        claimed = reserved & set(identities)
        if claimed:
            errors.append(f"vault_managed_users.{service}: {len(claimed)} "
                          f"{field} value{'' if len(claimed) == 1 else 's'} "
                          f"reuse a platform-owned identity")
    return errors


def _ntfy_token_ownership(value, reserved_ntfy_tokens):
    entries = value.get("ntfy")
    if not _GUARDS.is_list(entries):
        return []
    tokens = []
    for entry in entries:
        if _GUARDS.is_mapping(entry) and _GUARDS.is_list(entry.get("tokens")):
            tokens.extend(entry["tokens"])
    errors = []
    if len(set(map(str, tokens))) != len(tokens):
        errors.append("vault_managed_users.ntfy: tokens must be unique across users")
    reserved = set(map(str, reserved_ntfy_tokens or []))
    if reserved & set(map(str, tokens)):
        errors.append("vault_managed_users.ntfy: tokens must not reuse a "
                      "service-owned token")
    return errors


class FilterModule:
    """Expose the managed-user vault schema validator to Ansible."""

    def filters(self):
        return {"vault_managed_user_errors": vault_managed_user_errors}
