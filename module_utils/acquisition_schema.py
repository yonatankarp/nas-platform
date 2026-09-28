"""Validation and coercion primitives shared by the acquisition filters.

* **Guards** (`mapping`, `sequence`, `strict_boolean`, ...) refuse a value not
  already the right shape: a live API field that changed type is drift.
* **Coercions** (`coerce_string`, `coerce_boolean`, ...) accept the documented
  spellings an API returns and normalize them, for declaration/readback compares.

Loaded by path from `filter_plugins/`; imports `ansible.errors`, so controller-only.
"""

from __future__ import annotations

import functools
import re
import runpy
from pathlib import Path
from types import SimpleNamespace
from typing import Any

from ansible.errors import AnsibleFilterError


# module_utils/ is not on the import path, so a sibling is run by file path,
# never via sys.path (tests/policy_test.rb says why).
_MODULE_UTILS = Path(__file__).resolve().parent
_GUARDS = SimpleNamespace(**runpy.run_path(str(_MODULE_UTILS / "schema_guards.py")))

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

    Ansible passes templated proxies, and every element access re-enters the
    templating engine (measured ~30,000x slower); converting once here avoids that.
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
