"""Strict parsers for existing managed-user configuration state."""

import re
import yaml

from ansible.errors import AnsibleFilterError


class _ManagedUsersLoader(yaml.SafeLoader):
    """Safe loader that rejects duplicate semantic mapping keys."""


def _construct_unique_mapping(loader, node, deep=False):
    loader.flatten_mapping(node)
    mapping = {}
    for key_node, value_node in node.value:
        key = loader.construct_object(key_node, deep=deep)
        try:
            duplicate = key in mapping
        except TypeError as error:
            raise AnsibleFilterError(
                "Managed-user YAML contains an invalid mapping key"
            ) from error
        if duplicate:
            raise AnsibleFilterError(
                "Managed-user YAML contains duplicate mapping keys"
            )
        mapping[key] = loader.construct_object(value_node, deep=deep)
    return mapping


_ManagedUsersLoader.add_constructor(
    yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG,
    _construct_unique_mapping,
)


def managed_users_yaml(value):
    """Parse one alias-free Dozzle users mapping and preserve arbitrary values."""
    if not isinstance(value, str) or not value.strip():
        raise AnsibleFilterError("Managed-user YAML must be nonempty text")

    try:
        tokens = yaml.scan(value)
        if any(isinstance(token, (yaml.tokens.AnchorToken, yaml.tokens.AliasToken)) for token in tokens):
            raise AnsibleFilterError(
                "Managed-user YAML anchors and aliases are forbidden"
            )
        documents = list(yaml.load_all(value, Loader=_ManagedUsersLoader))
    except AnsibleFilterError:
        raise
    except yaml.YAMLError:
        raise AnsibleFilterError("Managed-user YAML is malformed") from None

    if len(documents) != 1:
        raise AnsibleFilterError(
            "Managed-user YAML must contain exactly one document"
        )
    document = documents[0]
    if not isinstance(document, dict):
        raise AnsibleFilterError("Managed-user YAML root must be a mapping")

    users = document.get("users", {})
    if not isinstance(users, dict):
        raise AnsibleFilterError("Managed-user YAML users must be a mapping")
    if any(not isinstance(username, str) for username in users):
        raise AnsibleFilterError(
            "Managed-user YAML user identities must be strings"
        )
    normalized = [username.strip().lower() for username in users]
    if len(set(normalized)) != len(normalized):
        raise AnsibleFilterError(
            "Managed-user YAML contains duplicate normalized user identities"
        )
    return document


_ENV_KEY = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
_NTFY_USERNAME = re.compile(r"^[-_.+@A-Za-z0-9]+$")
_NTFY_USER_HEADER = re.compile(
    r"^user (?P<username>\*|[-_.+@A-Za-z0-9]+) "
    r"\(role: (?P<role>anonymous|user|admin), tier: (?P<tier>.+)\)$"
)
_NTFY_PERMISSION_LINES = tuple(
    re.compile(pattern)
    for pattern in (
        r"^- read-write access to all topics \(admin role\)$",
        r"^- (?:read-write|read-only|write-only|no) access to topic "
        r"[-_*A-Za-z0-9]{1,64}(?: \(server config\))?$",
        r"^- no topic-specific permissions$",
        r"^- (?:read-write|read-only|write-only) access to all \(other\) topics "
        r"\(server config\)$",
        r"^- no access to any \(other\) topics \(server config\)$",
    )
)


def managed_user_env(value):
    """Parse an authored runtime env file without shell evaluation."""
    if not isinstance(value, str):
        raise AnsibleFilterError("Managed-user environment must be text")
    environment = {}
    for raw_line in value.splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            raise AnsibleFilterError(
                "Managed-user environment contains a malformed line"
            )
        key, entry_value = line.split("=", 1)
        if not _ENV_KEY.fullmatch(key):
            raise AnsibleFilterError(
                "Managed-user environment contains an invalid key"
            )
        if key in environment:
            raise AnsibleFilterError(
                "Managed-user environment contains a duplicate key"
            )
        environment[key] = entry_value
    return environment


def ntfy_auth_users(value):
    """Parse Compose-escaped ntfy auth-users entries by normalized identity."""
    if not isinstance(value, str):
        raise AnsibleFilterError("ntfy auth-users state must be text")
    users = {}
    if not value:
        return users
    for raw_entry in value.split(","):
        fields = raw_entry.split(":")
        if len(fields) != 3:
            raise AnsibleFilterError("ntfy auth-users state is malformed")
        username, password_hash, role = fields
        if not _NTFY_USERNAME.fullmatch(username) or role not in ("user", "admin"):
            raise AnsibleFilterError("ntfy auth-users state is malformed")
        normalized = username.strip().lower()
        if normalized in users:
            raise AnsibleFilterError(
                "ntfy auth-users state contains duplicate normalized identities"
            )
        users[normalized] = {
            "username": username,
            "password_hash": password_hash.replace("$$", "$"),
            "role": role,
        }
    return users


def ntfy_user_list(value):
    """Parse the exact user headers emitted by ntfy v2.27 `user list`."""
    if not isinstance(value, str) or not value.strip():
        raise AnsibleFilterError("ntfy user list output must be nonempty text")
    users = {}
    awaiting_permission = False
    for line in value.splitlines():
        if line.startswith("- "):
            if not awaiting_permission and not users:
                raise AnsibleFilterError("ntfy user list output format is unsupported")
            if not any(pattern.fullmatch(line) for pattern in _NTFY_PERMISSION_LINES):
                raise AnsibleFilterError("ntfy user list output format is unsupported")
            awaiting_permission = False
            continue
        if awaiting_permission:
            raise AnsibleFilterError("ntfy user list output is incomplete")
        match = _NTFY_USER_HEADER.fullmatch(line)
        if not match:
            raise AnsibleFilterError("ntfy user list output format is unsupported")
        username = match.group("username")
        normalized = username.lower()
        if normalized in users:
            raise AnsibleFilterError(
                "ntfy user list output contains duplicate normalized identities"
            )
        tier = match.group("tier")
        provisioned = tier.endswith(", server config")
        if provisioned:
            tier = tier.removesuffix(", server config")
        if not tier:
            raise AnsibleFilterError("ntfy user list output format is unsupported")
        users[normalized] = {
            "username": username,
            "role": match.group("role"),
            "provisioned": provisioned,
        }
        awaiting_permission = True
    if awaiting_permission:
        raise AnsibleFilterError("ntfy user list output is incomplete")
    if "*" not in users:
        raise AnsibleFilterError("ntfy user list output is incomplete")
    return users


class FilterModule:
    """Expose strict existing-state parsers to managed-user roles."""

    def filters(self):
        return {
            "managed_users_yaml": managed_users_yaml,
            "managed_user_env": managed_user_env,
            "ntfy_auth_users": ntfy_auth_users,
            "ntfy_user_list": ntfy_user_list,
        }
