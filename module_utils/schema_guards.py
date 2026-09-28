"""Type predicates and labelled guards shared by the filter plugins.

Only type primitives live here; domain rules and message wording stay with the
caller, which supplies the label. The `is_*` predicates match Ansible's Jinja
tests (`is integer` rejects booleans). Loaded by path; controller-only.
"""

from ansible.errors import AnsibleFilterError


def is_string(value):
    return isinstance(value, str)


def is_boolean(value):
    return isinstance(value, bool)


def is_integer(value):
    return isinstance(value, int) and not isinstance(value, bool)


def is_mapping(value):
    return isinstance(value, dict)


def is_list(value):
    return isinstance(value, list)


def is_sequence(value):
    return isinstance(value, (list, tuple))


def mapping(value, label):
    if not is_mapping(value):
        raise AnsibleFilterError(f"{label} must be a mapping")
    return value


def sequence(value, label, *, noun="a sequence"):
    """Return a plain list, so a tuple from the templar cannot leak onward."""
    if not is_sequence(value):
        raise AnsibleFilterError(f"{label} must be {noun}")
    return list(value)


def string(value, label):
    if not is_string(value):
        raise AnsibleFilterError(f"{label} must be a string")
    return value


def integer(value, label):
    if not is_integer(value):
        raise AnsibleFilterError(f"{label} must be an integer")
    return value


def boolean(value, label):
    if not is_boolean(value):
        raise AnsibleFilterError(f"{label} must be a boolean")
    return value
