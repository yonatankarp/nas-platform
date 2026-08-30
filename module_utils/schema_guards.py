"""Type predicates and labelled guards shared by the filter plugins.

Seven filter plugins each carried their own copy of the same few checks. Two of
them — `immich_preference_schema` and `vault_managed_user_schema` — held a
byte-identical four-predicate block, and the remaining five spelled the same
idea as `_mapping`, `_sequence`, `_require_integer`, `_require_sequence`,
`_require_mapping` and friends. A predicate that exists in seven places drifts
in one of them without anything noticing, which is why they live here instead.

Two rules keep this file honest:

* **Only primitives live here.** Every domain rule — a pattern, an enum, a
  default, a wording that names the structure being validated — stays in the
  module that owns it. A guard here knows a type and a label, nothing else.
* **Messages are the caller's.** The guards raise `AnsibleFilterError` with
  `"<label> must be a <noun>"` and the label is supplied by the caller, so the
  message a play sees is still written by the module that knows what the value
  is. `noun` exists because the same list check is reported as "a list" in one
  module and "a sequence" in another, and neither wording is worth changing.
  It carries its own article, so a guard reads `noun="a list"`.

The `is_*` predicates match Ansible's own Jinja tests, verified on ansible-core
2.21.3: `is integer` rejects booleans, `is boolean` rejects integers, and `is
string` rejects None. `is_sequence` accepts a tuple because a value that reached
a filter through the templating engine can arrive as one; `is_list` does not,
and is what a module reaches for when a tuple was never a legal input.

Filter plugins cannot import this by name — see the loading comment each of them
carries — so it is loaded by path. It imports `ansible.errors`, which is
controller-only, and is therefore not usable from `library/` modules that run on
a target.
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


def mapping(value, label, *, noun="a mapping"):
    if not is_mapping(value):
        raise AnsibleFilterError(f"{label} must be {noun}")
    return value


def sequence(value, label, *, noun="a sequence"):
    """Return a plain list, so a tuple from the templar cannot leak onward."""
    if not is_sequence(value):
        raise AnsibleFilterError(f"{label} must be {noun}")
    return list(value)


def string(value, label, *, noun="a string"):
    if not is_string(value):
        raise AnsibleFilterError(f"{label} must be {noun}")
    return value


def integer(value, label, *, noun="an integer"):
    if not is_integer(value):
        raise AnsibleFilterError(f"{label} must be {noun}")
    return value


def boolean(value, label, *, noun="a boolean"):
    if not is_boolean(value):
        raise AnsibleFilterError(f"{label} must be {noun}")
    return value
