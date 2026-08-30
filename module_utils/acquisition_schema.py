"""Validation and coercion primitives shared by the acquisition filters.

The media-acquisition filters cover three unrelated domains — Prowlarr/Servarr
relationship bodies, Bazarr settings and Configarr profile materialization — and
lived in one 2,281-line module because they share these few functions and
nothing else. They are here so the three domains can be three files.

Two kinds of primitive live here, and the difference matters at every call site:

* **Guards** (`mapping`, `sequence`, `strict_boolean`, `strict_integer`,
  `required_string`, `number`, `safe_setting_value`) refuse a value that is not
  already the right shape. They are what a projection of live API state is built
  from, because a Servarr field that changed type is drift, not something to
  coerce away.
* **Coercions** (`coerce_string`, `coerce_boolean`, `coerce_integer`,
  `sorted_integers`) accept the documented spellings an API returns — "true"
  for a boolean, "25" for an integer — and normalize them. They are what a
  comparison between a declaration and a readback is built from.

`native` and `with_native_arguments` are neither: they exist because Ansible
hands a filter templated proxies rather than plain containers, and every element
access on one re-enters the templating engine. Every filter this platform
exposes is wrapped, and `tests/acquisition_filter_native_arguments_test.py`
fails if one is added that is not.

Loaded by path from `filter_plugins/`, which cannot import `module_utils/` by
name. It imports `ansible.errors`, so it is controller-only.
"""

from __future__ import annotations

import functools
import importlib.util
import re
from pathlib import Path
from typing import Any

from ansible.errors import AnsibleFilterError


# module_utils/ is not a package on the import path, so its own siblings are
# reached the same way filter_plugins/ reaches it: by file path, with no
# sys.path mutation.
_GUARDS_SPEC = importlib.util.spec_from_file_location(
    "nas_platform_schema_guards", Path(__file__).resolve().parent / "schema_guards.py"
)
_GUARDS = importlib.util.module_from_spec(_GUARDS_SPEC)
_GUARDS_SPEC.loader.exec_module(_GUARDS)

mapping = _GUARDS.mapping
sequence = _GUARDS.sequence
strict_boolean = _GUARDS.boolean
strict_integer = _GUARDS.integer


MASKED_VALUE = re.compile(r"^\*+$")


def fields(value: Any) -> dict[str, Any]:
    if value is None:
        return {}
    if not isinstance(value, list):
        raise AnsibleFilterError("relationship fields must be a sequence")

    result: dict[str, Any] = {}
    for field in value:
        field = mapping(field, "relationship field")
        name = field.get("name")
        if not isinstance(name, str) or not name:
            raise AnsibleFilterError("relationship field names must be non-empty strings")
        if name in result:
            raise AnsibleFilterError(f"relationship field {name!r} is duplicated")
        result[name] = field.get("value")
    return result


def coerce_string(value: Any) -> str:
    return "" if value is None else str(value)


def coerce_boolean(value: Any) -> bool:
    if isinstance(value, bool):
        return value
    if isinstance(value, str):
        normalized = value.strip().lower()
        if normalized in {"true", "false"}:
            return normalized == "true"
    raise AnsibleFilterError("relationship boolean values must be true or false")


def coerce_integer(value: Any) -> int:
    if isinstance(value, bool):
        raise AnsibleFilterError("relationship integer values cannot be booleans")
    if isinstance(value, int):
        return value
    if isinstance(value, str) and re.fullmatch(r"-?\d+", value.strip()):
        return int(value.strip())
    raise AnsibleFilterError("relationship integer values must be canonical integers")


def sorted_integers(value: Any) -> list[int]:
    if not isinstance(value, (list, tuple)):
        raise AnsibleFilterError("relationship integer lists must be sequences")
    return sorted(coerce_integer(item) for item in value)


def required_string(value: Any, label: str, *, allow_empty: bool = False) -> str:
    _GUARDS.string(value, label)
    if not allow_empty and not value:
        raise AnsibleFilterError(f"{label} must be non-empty")
    if "\x00" in value or "\r" in value or "\n" in value:
        raise AnsibleFilterError(f"{label} contains unsafe control characters")
    return value


def number(value: Any, label: str) -> int | float:
    if (
        isinstance(value, bool)
        or not isinstance(value, (int, float))
        or (
            isinstance(value, float)
            and (value != value or value in {float("inf"), float("-inf")})
        )
    ):
        raise AnsibleFilterError(f"{label} must be a number")
    return value


def nullable_number(value: Any, label: str) -> int | float | None:
    return None if value is None else number(value, label)


def nullable_string(value: Any, label: str) -> str | None:
    return None if value is None else required_string(value, label)


def safe_setting_value(value: Any, label: str) -> Any:
    if isinstance(value, str):
        return required_string(value, label, allow_empty=True)
    if isinstance(value, (bool, int, float)) and not (
        isinstance(value, float) and (value != value or value in {float("inf"), float("-inf")})
    ):
        return value
    if isinstance(value, (list, tuple)):
        result = []
        for index, item in enumerate(value):
            if isinstance(item, (list, tuple, dict)) or item is None:
                raise AnsibleFilterError(f"{label}[{index}] is not a safe scalar")
            result.append(safe_setting_value(item, f"{label}[{index}]"))
        return result
    raise AnsibleFilterError(f"{label} must be a safe scalar or scalar list")


def native(value: Any) -> Any:
    """Return plain containers for values that arrived from a play.

    Ansible hands a filter its arguments as templated proxies rather than plain
    containers, and every element access on one re-enters the templating engine.
    That is invisible against a fixture and ruinous against a real play: these
    filters measured 0.05-2.5ms called directly and 1.3-96s called through
    Jinja on the same data, a factor of about thirty thousand, in proportion to
    how much of the structure each one walks. Converting once on the way in
    pays that cost a single time instead of once per access, and every filter
    below then traverses ordinary dicts and lists.

    A round trip through to_json/from_json inside the template does not work:
    Ansible re-wraps the intermediate result before the next filter sees it, so
    the conversion has to happen here.
    """
    if isinstance(value, dict):
        return {native(key): native(item) for key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return [native(item) for item in value]
    if isinstance(value, bool) or value is None:
        return value
    if isinstance(value, str):
        return str(value)
    if isinstance(value, int):
        return int(value)
    if isinstance(value, float):
        return float(value)
    return value


def with_native_arguments(function: Any) -> Any:
    """Convert a filter's arguments before its body traverses them."""

    @functools.wraps(function)
    def wrapper(*args: Any, **kwargs: Any) -> Any:
        return function(
            *(native(argument) for argument in args),
            **{name: native(value) for name, value in kwargs.items()},
        )

    return wrapper
