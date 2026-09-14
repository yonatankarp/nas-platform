"""Strict parsers for existing managed-user configuration state."""

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


class FilterModule:
    """Expose strict existing-state parsers to managed-user roles."""

    def filters(self):
        return {
            "managed_users_yaml": managed_users_yaml,
        }
