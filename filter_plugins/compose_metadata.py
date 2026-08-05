"""Safely parse Docker Compose YAML for deployment-manifest metadata."""

import yaml

from ansible.errors import AnsibleFilterError


class _ComposeMetadataLoader(yaml.SafeLoader):
    """Safe YAML loader that understands only Docker Compose loader tags."""


def _construct_compose_value(loader, node):
    if isinstance(node, yaml.ScalarNode):
        return loader.construct_scalar(node)
    if isinstance(node, yaml.SequenceNode):
        return loader.construct_sequence(node, deep=True)
    if isinstance(node, yaml.MappingNode):
        return loader.construct_mapping(node, deep=True)
    raise AnsibleFilterError("Compose metadata contains an unsupported YAML node")


for _compose_tag in ("!override", "!reset"):
    _ComposeMetadataLoader.add_constructor(_compose_tag, _construct_compose_value)


def platform_compose_metadata(value):
    """Load metadata without rewriting quoted values, blocks, or comments."""
    if not isinstance(value, str) or not value.strip():
        raise AnsibleFilterError("Compose metadata input must be nonempty YAML text")

    try:
        metadata = yaml.load(value, Loader=_ComposeMetadataLoader)
    except yaml.YAMLError:
        raise AnsibleFilterError(
            "Compose metadata contains invalid or unsupported YAML"
        ) from None

    if not isinstance(metadata, dict):
        raise AnsibleFilterError("Compose metadata root must be a mapping")
    return metadata


class FilterModule:
    """Expose the manifest-only Docker Compose metadata parser."""

    def filters(self):
        return {"platform_compose_metadata": platform_compose_metadata}
