"""Filters for turning controller-provided host paths into physical paths."""

import os

from ansible.errors import AnsibleFilterError


def platform_physical_path(value):
    """Resolve symlinked ancestors while allowing the final leaf to be absent."""
    if not isinstance(value, str) or not value or not os.path.isabs(value):
        raise AnsibleFilterError("platform storage paths must be nonempty absolute paths")

    if value != os.path.normpath(value) or value.startswith(os.sep * 2):
        raise AnsibleFilterError("platform storage paths must be lexically normalized")

    return os.path.realpath(value)


class FilterModule:
    """Expose platform path filters to inventory variables."""

    def filters(self):
        return {"platform_physical_path": platform_physical_path}
