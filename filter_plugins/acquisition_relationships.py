"""Normalize the operator-owned media acquisition relationships."""

from __future__ import annotations

import re
from copy import deepcopy
from typing import Any

from ansible.errors import AnsibleFilterError


MASKED_VALUE = re.compile(r"^\*+$")


def _mapping(value: Any, label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise AnsibleFilterError(f"{label} must be a mapping")
    return value


def _fields(value: Any) -> dict[str, Any]:
    if value is None:
        return {}
    if not isinstance(value, list):
        raise AnsibleFilterError("relationship fields must be a sequence")

    result: dict[str, Any] = {}
    for field in value:
        field = _mapping(field, "relationship field")
        name = field.get("name")
        if not isinstance(name, str) or not name:
            raise AnsibleFilterError("relationship field names must be non-empty strings")
        if name in result:
            raise AnsibleFilterError(f"relationship field {name!r} is duplicated")
        result[name] = field.get("value")
    return result


def _string(value: Any) -> str:
    return "" if value is None else str(value)


def _boolean(value: Any) -> bool:
    if isinstance(value, str):
        return value.strip().lower() in {"1", "true", "yes", "on"}
    return bool(value)


def _integer(value: Any) -> int:
    try:
        return int(value)
    except (TypeError, ValueError):
        return 0


def _sorted_integers(value: Any) -> list[int]:
    if not isinstance(value, (list, tuple)):
        return []
    return sorted(_integer(item) for item in value)


def _sorted_like(value: Any, desired: list[Any]) -> list[Any]:
    if not isinstance(value, (list, tuple)):
        return []
    if desired and isinstance(desired[0], bool):
        return sorted((_boolean(item) for item in value), key=str)
    if desired and isinstance(desired[0], int):
        return sorted(_integer(item) for item in value)
    return sorted((_string(item) for item in value), key=str)


def _normalized_like(value: Any, desired: Any) -> Any:
    if isinstance(desired, bool):
        return _boolean(value)
    if isinstance(desired, int):
        return _integer(value)
    if isinstance(desired, list):
        return _sorted_like(value, desired)
    return _string(value)


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


def acquisition_application_projection(
    value: Any, masked_fields: Any = None
) -> dict[str, Any]:
    value = _mapping(value, "Prowlarr application")
    fields = _fields(value.get("fields", []))
    if masked_fields is None:
        masked_fields = acquisition_application_masked_fields(value)
    if not isinstance(masked_fields, (list, tuple)):
        raise AnsibleFilterError("masked Prowlarr application fields must be a sequence")
    masked_names = set(masked_fields)
    projection = {
        "name": _string(value.get("name")),
        "enable": _boolean(value.get("enable")),
        "syncLevel": _string(value.get("syncLevel")),
        "implementation": _string(value.get("implementation")),
        "implementationName": _string(value.get("implementationName")),
        "configContract": _string(value.get("configContract")),
        "tags": _sorted_integers(value.get("tags", [])),
        "fields": {
            "prowlarrUrl": _string(fields.get("prowlarrUrl")),
            "baseUrl": _string(fields.get("baseUrl")),
            "username": _string(fields.get("username")),
            "password": _string(fields.get("password")),
            "syncCategories": _sorted_integers(fields.get("syncCategories", [])),
        },
    }
    if "apiKey" not in masked_names:
        projection["fields"]["apiKey"] = _string(fields.get("apiKey"))
    return projection


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


def acquisition_servarr_client_projection(
    value: Any, masked_fields: Any = None
) -> dict[str, Any]:
    value = _mapping(value, "Servarr SABnzbd client")
    fields = _fields(value.get("fields", []))
    if masked_fields is None:
        masked_fields = acquisition_servarr_client_masked_fields(value)
    if not isinstance(masked_fields, (list, tuple)):
        raise AnsibleFilterError("masked Servarr client fields must be a sequence")
    masked_names = set(masked_fields)
    projection = {
        "name": _string(value.get("name")),
        "enable": _boolean(value.get("enable")),
        "protocol": _string(value.get("protocol")),
        "priority": _integer(value.get("priority")),
        "removeCompletedDownloads": _boolean(value.get("removeCompletedDownloads")),
        "removeFailedDownloads": _boolean(value.get("removeFailedDownloads")),
        "implementation": _string(value.get("implementation")),
        "implementationName": _string(value.get("implementationName")),
        "configContract": _string(value.get("configContract")),
        "tags": _sorted_integers(value.get("tags", [])),
        "fields": {
            "host": _string(fields.get("host")),
            "port": _integer(fields.get("port")),
            "useSsl": _boolean(fields.get("useSsl")),
            "urlBase": _string(fields.get("urlBase")),
            "movieCategory": _string(fields.get("movieCategory")),
            "tvCategory": _string(fields.get("tvCategory")),
        },
    }
    for name in ["apiKey", "username", "password"]:
        if name not in masked_names:
            projection["fields"][name] = _string(fields.get(name))
    return projection


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


def acquisition_indexer_projection(
    value: Any, declaration: Any, masked_fields: Any = None
) -> dict[str, Any]:
    value = _mapping(value, "Prowlarr indexer")
    declaration = _mapping(declaration, "Prowlarr indexer declaration")
    current_fields = _fields(value.get("fields", []))
    desired_fields = _fields(declaration.get("fields", []))
    if masked_fields is None:
        masked_fields = acquisition_indexer_masked_fields(value, declaration)
    if not isinstance(masked_fields, (list, tuple)):
        raise AnsibleFilterError("masked Prowlarr indexer fields must be a sequence")
    masked_names = set(masked_fields)
    readable_fields = {}
    for name, desired in desired_fields.items():
        if name in masked_names:
            continue
        if name not in current_fields:
            continue
        current = current_fields[name]
        readable_fields[name] = _normalized_like(current, desired)
    return {
        "name": _string(value.get("name")),
        "enable": _boolean(value.get("enable")),
        "priority": _integer(value.get("priority")),
        "implementation": _string(value.get("implementation")),
        "implementationName": _string(value.get("implementationName")),
        "configContract": _string(value.get("configContract")),
        "tags": _sorted_integers(value.get("tags", [])),
        "fields": readable_fields,
    }


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
    """Expose relationship normalization filters to Ansible."""

    def filters(self) -> dict[str, Any]:
        return {
            "acquisition_application_body": acquisition_application_body,
            "acquisition_application_masked_fields": acquisition_application_masked_fields,
            "acquisition_application_projection": acquisition_application_projection,
            "acquisition_servarr_client_body": acquisition_servarr_client_body,
            "acquisition_servarr_client_masked_fields": acquisition_servarr_client_masked_fields,
            "acquisition_servarr_client_projection": acquisition_servarr_client_projection,
            "acquisition_servarr_client_url_matches": acquisition_servarr_client_url_matches,
            "acquisition_indexer_body": acquisition_indexer_body,
            "acquisition_indexer_masked_fields": acquisition_indexer_masked_fields,
            "acquisition_indexer_projection": acquisition_indexer_projection,
            "acquisition_merge_owned_fields": acquisition_merge_owned_fields,
        }
