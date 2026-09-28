"""Prowlarr and Servarr relationship bodies and projections.

Each relationship has a `body` filter (what is sent), a `masked_fields` filter
(secrets the API returns as asterisks) and a `projection` filter (the owned
fields only, so drift outside them is ignored). All projections share
`_owned_projection`, driven by a `_Relationship` descriptor.
"""

from __future__ import annotations

import runpy
from copy import deepcopy
from pathlib import Path
from types import SimpleNamespace
from typing import Any, NamedTuple

from ansible.errors import AnsibleFilterError


# module_utils/ is run by file path, never via sys.path: tests/policy_test.rb
# says why, and fails any filter plugin that touches it.
_MODULE_UTILS = Path(__file__).resolve().parents[1] / "module_utils"
_SCHEMA = SimpleNamespace(**runpy.run_path(str(_MODULE_UTILS / "acquisition_schema.py")))

MASKED_VALUE = _SCHEMA.MASKED_VALUE
_mapping = _SCHEMA.mapping
_fields = _SCHEMA.fields
_string = _SCHEMA.coerce_string
_boolean = _SCHEMA.coerce_boolean
_integer = _SCHEMA.coerce_integer
_sorted_integers = _SCHEMA.sorted_integers
_with_native_arguments = _SCHEMA.with_native_arguments


def _normalized_like(name: str, value: Any, desired: Any) -> Any:
    if isinstance(desired, bool):
        return _boolean(value)
    if isinstance(desired, int):
        return _integer(value)
    if isinstance(desired, list):
        if not isinstance(value, list):
            raise AnsibleFilterError(f"relationship field {name!r} must be a list")
        # Prowlarr category IDs are explicitly unordered; every other list is
        # API-contract data whose order and nested structure are significant.
        if name == "categories":
            return _sorted_integers(value)
        return deepcopy(value)
    return _string(value)


class _Relationship(NamedTuple):
    """What this platform owns in one Prowlarr or Servarr relationship.

    `secret_fields` are projected only when unmasked. `declaration_label` is set
    only by the indexer, whose owned fields are whatever the declaration names.
    """

    label: str
    masked_label: str
    masked: Any
    attributes: tuple[tuple[str, Any], ...]
    readable_fields: tuple[tuple[str, Any], ...] = ()
    secret_fields: tuple[tuple[str, Any], ...] = ()
    declaration_label: str | None = None


def _declared_field_projection(
    spec: _Relationship,
    current_fields: dict[str, Any],
    desired_fields: dict[str, Any],
    masked_names: set[str],
) -> dict[str, Any]:
    """Project the fields a declaration names, normalized like their desired."""
    projection = {}
    for name, desired in desired_fields.items():
        if name in masked_names:
            continue
        if name not in current_fields:
            raise AnsibleFilterError(
                f"{spec.label} field {name!r} is missing from readable state"
            )
        projection[name] = _normalized_like(name, current_fields[name], desired)
    return projection


def _owned_projection(
    value: Any,
    spec: _Relationship,
    masked_fields: Any,
    declaration: Any = None,
) -> dict[str, Any]:
    """Reduce a readback to the fields this platform owns, minus the masked ones.

    Guard order is contract: tests/acquisition_servarr_filter_test.py pins it.
    """
    value = _mapping(value, spec.label)
    if spec.declaration_label is not None:
        declaration = _mapping(declaration, spec.declaration_label)
    current_fields = _fields(value.get("fields", []))
    desired_fields = (
        {} if spec.declaration_label is None else _fields(declaration.get("fields", []))
    )
    if masked_fields is None:
        masked_fields = (
            spec.masked(value)
            if spec.declaration_label is None
            else spec.masked(value, declaration)
        )
    if not isinstance(masked_fields, (list, tuple)):
        raise AnsibleFilterError(f"masked {spec.masked_label} fields must be a sequence")
    masked_names = set(masked_fields)
    projection = {name: coerce(value.get(name)) for name, coerce in spec.attributes}
    # `tags` is the one owned attribute a Servarr API omits rather than returning
    # empty, and it is the last attribute of all three projections. An explicit
    # null is still refused: that is a type that changed, which is drift.
    projection["tags"] = _sorted_integers(value.get("tags", []))
    if spec.declaration_label is not None:
        projection["fields"] = _declared_field_projection(
            spec, current_fields, desired_fields, masked_names
        )
        return projection
    fields = {
        name: coerce(current_fields.get(name)) for name, coerce in spec.readable_fields
    }
    for name, coerce in spec.secret_fields:
        if name not in masked_names:
            fields[name] = coerce(current_fields.get(name))
    projection["fields"] = fields
    return projection


def acquisition_application_body(
    declaration: Any, prowlarr_url: Any, sync_level: Any
) -> dict[str, Any]:
    declaration = _mapping(declaration, "Prowlarr application declaration")
    implementation = _string(declaration.get("implementation"))
    return {
        "name": _string(declaration.get("name")),
        "enable": True,
        "syncLevel": _string(sync_level),
        "implementation": implementation,
        "implementationName": _string(
            declaration.get("implementation_name", implementation)
        ),
        "configContract": _string(declaration.get("config_contract")),
        "tags": _sorted_integers(declaration.get("tags", [])),
        "fields": [
            {"name": "prowlarrUrl", "value": _string(prowlarr_url)},
            {"name": "baseUrl", "value": _string(declaration.get("base_url"))},
            {"name": "username", "value": ""},
            {"name": "password", "value": ""},
            {"name": "apiKey", "value": declaration.get("api_key")},
            {
                "name": "syncCategories",
                "value": _sorted_integers(declaration.get("sync_categories", [])),
            },
        ],
    }


def acquisition_application_masked_fields(value: Any) -> list[str]:
    value = _mapping(value, "Prowlarr application")
    fields = _fields(value.get("fields", []))
    return [
        name
        for name in ["apiKey"]
        if isinstance(fields.get(name), str) and MASKED_VALUE.fullmatch(fields[name])
    ]


_APPLICATION = _Relationship(
    label="Prowlarr application",
    masked_label="Prowlarr application",
    masked=acquisition_application_masked_fields,
    attributes=(
        ("name", _string), ("enable", _boolean), ("syncLevel", _string),
        ("implementation", _string), ("implementationName", _string),
        ("configContract", _string),
    ),
    readable_fields=(
        ("prowlarrUrl", _string), ("baseUrl", _string), ("username", _string),
        ("password", _string), ("syncCategories", _sorted_integers),
    ),
    secret_fields=(("apiKey", _string),),
)


def acquisition_application_projection(
    value: Any, masked_fields: Any = None
) -> dict[str, Any]:
    return _owned_projection(value, _APPLICATION, masked_fields)


def acquisition_servarr_client_body(
    instance: Any,
    name: Any,
    host: Any,
    port: Any,
    api_key: Any,
    username: Any,
    password: Any,
) -> dict[str, Any]:
    instance = _mapping(instance, "Servarr instance")
    category_key = "movieCategory" if instance.get("name") == "radarr" else "tvCategory"
    return {
        "name": _string(name),
        "enable": True,
        "protocol": "usenet",
        "priority": 1,
        "removeCompletedDownloads": True,
        "removeFailedDownloads": True,
        "implementation": "Sabnzbd",
        "implementationName": "SABnzbd",
        "configContract": "SabnzbdSettings",
        "tags": _sorted_integers(instance.get("tags", [])),
        "fields": [
            {"name": "host", "value": _string(host)},
            {"name": "port", "value": _integer(port)},
            {"name": "useSsl", "value": False},
            {"name": "urlBase", "value": ""},
            {"name": "apiKey", "value": api_key},
            {"name": "username", "value": username},
            {"name": "password", "value": password},
            {"name": category_key, "value": _string(instance.get("category"))},
        ],
    }


def acquisition_servarr_client_masked_fields(value: Any) -> list[str]:
    value = _mapping(value, "Servarr SABnzbd client")
    fields = _fields(value.get("fields", []))
    return [
        name
        for name in ["apiKey", "username", "password"]
        if isinstance(fields.get(name), str) and MASKED_VALUE.fullmatch(fields[name])
    ]


_SERVARR_CLIENT = _Relationship(
    label="Servarr SABnzbd client",
    masked_label="Servarr client",
    masked=acquisition_servarr_client_masked_fields,
    attributes=(
        ("name", _string), ("enable", _boolean), ("protocol", _string),
        ("priority", _integer), ("removeCompletedDownloads", _boolean),
        ("removeFailedDownloads", _boolean), ("implementation", _string),
        ("implementationName", _string), ("configContract", _string),
    ),
    readable_fields=(
        ("host", _string), ("port", _integer), ("useSsl", _boolean),
        ("urlBase", _string), ("movieCategory", _string), ("tvCategory", _string),
    ),
    secret_fields=(("apiKey", _string), ("username", _string), ("password", _string)),
)


def acquisition_servarr_client_projection(
    value: Any, masked_fields: Any = None
) -> dict[str, Any]:
    return _owned_projection(value, _SERVARR_CLIENT, masked_fields)


def acquisition_servarr_client_url_matches(
    collection: Any, host: Any, port: Any
) -> list[dict[str, Any]]:
    if not isinstance(collection, list):
        return []
    expected_host = _string(host)
    expected_port = _integer(port)
    matches = []
    for client in collection:
        client = _mapping(client, "Servarr download client")
        fields = _fields(client.get("fields", []))
        if "host" not in fields or "port" not in fields:
            continue
        if (
            _string(fields.get("host")) == expected_host
            and _integer(fields.get("port")) == expected_port
        ):
            matches.append(client)
    return matches


def acquisition_indexer_body(declaration: Any) -> dict[str, Any]:
    declaration = _mapping(declaration, "Prowlarr indexer declaration")
    implementation = _string(declaration.get("implementation"))
    fields = declaration.get("fields", [])
    _fields(fields)
    return {
        "name": _string(declaration.get("name")),
        "enable": _boolean(declaration.get("enable", True)),
        "priority": _integer(declaration.get("priority", 25)),
        # Prowlarr requires AppProfileId > 0 and does not default it (400);
        # 1 is the "Standard" profile it creates on first start.
        "appProfileId": _integer(declaration.get("app_profile_id", 1)),
        # Prowlarr refuses a Usenet indexer without redirect and does not
        # default it; only Usenet indexers are declared here.
        "redirect": _boolean(declaration.get("redirect", True)),
        "implementation": implementation,
        "implementationName": _string(
            declaration.get("implementation_name", implementation)
        ),
        "configContract": _string(declaration.get("config_contract")),
        "tags": _sorted_integers(declaration.get("tags", [])),
        "fields": deepcopy(fields),
    }


def acquisition_indexer_masked_fields(value: Any, declaration: Any) -> list[str]:
    value = _mapping(value, "Prowlarr indexer")
    declaration = _mapping(declaration, "Prowlarr indexer declaration")
    current_fields = _fields(value.get("fields", []))
    desired_fields = _fields(declaration.get("fields", []))
    return sorted(
        name
        for name in desired_fields
        if isinstance(current_fields.get(name), str)
        and MASKED_VALUE.fullmatch(current_fields[name])
    )


_INDEXER = _Relationship(
    label="Prowlarr indexer",
    masked_label="Prowlarr indexer",
    masked=acquisition_indexer_masked_fields,
    attributes=(
        ("name", _string), ("enable", _boolean), ("priority", _integer),
        ("appProfileId", _integer), ("redirect", _boolean),
        ("implementation", _string), ("implementationName", _string),
        ("configContract", _string),
    ),
    declaration_label="Prowlarr indexer declaration",
)


def acquisition_indexer_projection(
    value: Any, declaration: Any, masked_fields: Any = None
) -> dict[str, Any]:
    return _owned_projection(value, _INDEXER, masked_fields, declaration)


def acquisition_merge_owned_fields(
    current: Any, desired: Any, extra_owned_names: Any = None
) -> list[dict[str, Any]]:
    current = [] if current is None else current
    desired = [] if desired is None else desired
    _fields(current)
    desired_by_name = _fields(desired)
    extra_owned_names = [] if extra_owned_names is None else extra_owned_names
    if not isinstance(extra_owned_names, (list, tuple)):
        raise AnsibleFilterError("extra owned field names must be a sequence")
    owned_names = set(desired_by_name).union(_string(name) for name in extra_owned_names)
    merged = [deepcopy(field) for field in current if field["name"] not in owned_names]
    merged.extend(deepcopy(desired))
    return merged


class FilterModule:
    """Expose the Prowlarr and Servarr relationship filters to Ansible."""

    def filters(self) -> dict[str, Any]:
        return {
            name: _with_native_arguments(function)
            for name, function in self._relationship_filters().items()
        }

    def _relationship_filters(self) -> dict[str, Any]:
        return {
            "acquisition_application_body": acquisition_application_body,
            "acquisition_application_masked_fields": acquisition_application_masked_fields,
            "acquisition_application_projection": acquisition_application_projection,
            "acquisition_servarr_client_body": acquisition_servarr_client_body,
            "acquisition_servarr_client_masked_fields":
                acquisition_servarr_client_masked_fields,
            "acquisition_servarr_client_projection": acquisition_servarr_client_projection,
            "acquisition_servarr_client_url_matches":
                acquisition_servarr_client_url_matches,
            "acquisition_indexer_body": acquisition_indexer_body,
            "acquisition_indexer_masked_fields": acquisition_indexer_masked_fields,
            "acquisition_indexer_projection": acquisition_indexer_projection,
            "acquisition_merge_owned_fields": acquisition_merge_owned_fields,
        }
