"""Normalize the operator-owned media acquisition relationships."""

from __future__ import annotations

import hashlib
import json
import re
from copy import deepcopy
from typing import Any

import yaml
from ansible.errors import AnsibleFilterError


MASKED_VALUE = re.compile(r"^\*+$")
BAZARR_ARRAY_SETTINGS = {
    "excluded_tags", "exclude", "included_codecs", "subzero_mods",
    "excluded_series_types", "enabled_providers", "enabled_integrations",
    "gemini_keys", "path_mappings", "path_mappings_movie",
    "remove_profile_tags", "language_equals", "blacklisted_languages",
    "blacklisted_providers", "movie_library", "series_library",
    "movie_library_ids", "series_library_ids",
}
BAZARR_STRING_SETTINGS = {
    "chmod", "log_include_filter", "log_exclude_filter", "password",
    "f_password", "hashed_password",
}


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
    if isinstance(value, bool):
        return value
    if isinstance(value, str):
        normalized = value.strip().lower()
        if normalized in {"true", "false"}:
            return normalized == "true"
    raise AnsibleFilterError("relationship boolean values must be true or false")


def _integer(value: Any) -> int:
    if isinstance(value, bool):
        raise AnsibleFilterError("relationship integer values cannot be booleans")
    if isinstance(value, int):
        return value
    if isinstance(value, str) and re.fullmatch(r"-?\d+", value.strip()):
        return int(value.strip())
    raise AnsibleFilterError("relationship integer values must be canonical integers")


def _sorted_integers(value: Any) -> list[int]:
    if not isinstance(value, (list, tuple)):
        raise AnsibleFilterError("relationship integer lists must be sequences")
    return sorted(_integer(item) for item in value)


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
            "syncCategories": _sorted_integers(fields.get("syncCategories")),
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
            raise AnsibleFilterError(
                f"Prowlarr indexer field {name!r} is missing from readable state"
            )
        current = current_fields[name]
        readable_fields[name] = _normalized_like(name, current, desired)
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


def _sequence(value: Any, label: str) -> list[Any]:
    if not isinstance(value, (list, tuple)):
        raise AnsibleFilterError(f"{label} must be a sequence")
    return list(value)


def _required_string(value: Any, label: str, *, allow_empty: bool = False) -> str:
    if not isinstance(value, str):
        raise AnsibleFilterError(f"{label} must be a string")
    if not allow_empty and not value:
        raise AnsibleFilterError(f"{label} must be non-empty")
    if "\x00" in value or "\r" in value or "\n" in value:
        raise AnsibleFilterError(f"{label} contains unsafe control characters")
    return value


def _number(value: Any, label: str) -> int | float:
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


def _nullable_number(value: Any, label: str) -> int | float | None:
    return None if value is None else _number(value, label)


def _nullable_string(value: Any, label: str) -> str | None:
    return None if value is None else _required_string(value, label)


def _strict_boolean(value: Any, label: str) -> bool:
    if not isinstance(value, bool):
        raise AnsibleFilterError(f"{label} must be a boolean")
    return value


def _strict_integer(value: Any, label: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise AnsibleFilterError(f"{label} must be an integer")
    return value


def _safe_setting_value(value: Any, label: str) -> Any:
    if isinstance(value, str):
        return _required_string(value, label, allow_empty=True)
    if isinstance(value, (bool, int, float)) and not (
        isinstance(value, float) and (value != value or value in {float("inf"), float("-inf")})
    ):
        return value
    if isinstance(value, (list, tuple)):
        result = []
        for index, item in enumerate(value):
            if isinstance(item, (list, tuple, dict)) or item is None:
                raise AnsibleFilterError(f"{label}[{index}] is not a safe scalar")
            result.append(_safe_setting_value(item, f"{label}[{index}]"))
        return result
    raise AnsibleFilterError(f"{label} must be a safe scalar or scalar list")


def _provider_desired_value(value: Any, label: str, setting_name: str) -> Any:
    value = _safe_setting_value(value, label)
    if isinstance(value, list):
        if setting_name not in BAZARR_ARRAY_SETTINGS:
            raise AnsibleFilterError(
                f"{label} uses a list for a non-array Bazarr setting"
            )
        return [
            str(item).lower() if isinstance(item, bool) else str(item)
            for item in value
        ]
    if isinstance(value, str) and value.strip().lower() in {"true", "false"}:
        return value.strip().lower() == "true"
    if (
        isinstance(value, str)
        and setting_name not in BAZARR_STRING_SETTINGS
        and re.fullmatch(r"[+-]?\d+", value.strip())
    ):
        return int(value.strip())
    return value


def _provider_request_value(value: Any, setting_name: str, label: str) -> Any:
    value = _safe_setting_value(value, label)
    if not isinstance(value, list):
        return value
    if setting_name not in BAZARR_ARRAY_SETTINGS:
        raise AnsibleFilterError(
            f"{label} uses a list for a non-array Bazarr setting"
        )
    if not value:
        return ["null"]
    return [str(item).lower() if isinstance(item, bool) else str(item) for item in value]


def _provider_current_value(value: Any, desired: Any, label: str) -> Any:
    if isinstance(desired, bool):
        return _boolean(value)
    if isinstance(desired, int) and not isinstance(desired, bool):
        return _integer(value)
    if isinstance(desired, float):
        return _number(value, label)
    if isinstance(desired, list):
        current = _sequence(value, label)
        if len(current) != len(desired):
            return deepcopy(current)
        return [
            _provider_current_value(item, expected, f"{label}[{index}]")
            for index, (item, expected) in enumerate(zip(current, desired))
        ]
    return _required_string(value, label, allow_empty=True)


def acquisition_bazarr_declarations(languages: Any, providers: Any) -> dict[str, Any]:
    normalized_languages = []
    for language in _sequence(languages, "Bazarr language declarations"):
        language = _required_string(language, "Bazarr language")
        if not re.fullmatch(r"[a-z0-9_-]+", language):
            raise AnsibleFilterError("Bazarr languages must use canonical lowercase values")
        normalized_languages.append(language)
    if len(normalized_languages) != len(set(normalized_languages)):
        raise AnsibleFilterError("Bazarr languages must be unique")

    provider_names = []
    provider_settings: dict[str, dict[str, Any]] = {}
    provider_bodies: dict[str, dict[str, Any]] = {}
    for provider in _sequence(providers, "Bazarr provider declarations"):
        provider = _mapping(provider, "Bazarr provider declaration")
        name = _required_string(provider.get("name"), "Bazarr provider name")
        if not re.fullmatch(r"[a-z0-9_-]+", name):
            raise AnsibleFilterError("Bazarr provider names must use canonical lowercase values")
        settings = _mapping(provider.get("settings"), f"Bazarr provider {name!r} settings")
        if not settings:
            raise AnsibleFilterError(f"Bazarr provider {name!r} settings must be non-empty")
        prefix = f"settings-{name}-"
        normalized_settings = {}
        safe_body = {}
        for key, value in settings.items():
            key = _required_string(key, f"Bazarr provider {name!r} setting key")
            if not key.startswith(prefix) or len(key) == len(prefix):
                raise AnsibleFilterError(
                    f"Bazarr provider {name!r} setting keys require the exact provider prefix"
                )
            setting_name = key[len(prefix) :]
            safe_body[key] = _provider_request_value(
                value, setting_name, f"Bazarr provider setting {key!r}"
            )
            normalized_settings[setting_name] = _provider_desired_value(
                value, f"Bazarr provider setting {key!r}", setting_name
            )
        provider_names.append(name)
        provider_settings[name] = normalized_settings
        provider_bodies[name] = safe_body
    if len(provider_names) != len(set(provider_names)):
        raise AnsibleFilterError("Bazarr provider names must be unique")

    return {
        "languages": sorted(normalized_languages),
        "provider_names": sorted(provider_names),
        "provider_settings": {
            name: provider_settings[name] for name in sorted(provider_settings)
        },
        "provider_bodies": {name: provider_bodies[name] for name in sorted(provider_bodies)},
    }


def _bazarr_path_mappings(value: Any, label: str) -> list[list[str]]:
    """Normalize Bazarr's pinned list-of-two-paths settings representation."""
    mappings = []
    for index, entry in enumerate(_sequence(value, label)):
        pair = _sequence(entry, f"{label} entry {index}")
        if len(pair) != 2:
            raise AnsibleFilterError(f"{label} entries must contain exactly two paths")
        mappings.append(
            [
                _required_string(pair[0], f"{label} entry {index} source path"),
                _required_string(pair[1], f"{label} entry {index} target path"),
            ]
        )
    return mappings


def acquisition_bazarr_owned_projections(
    settings: Any,
    language_state: Any,
    declarations: Any,
    username: Any,
    password: Any,
    radarr_api_key: Any,
    sonarr_api_key: Any,
) -> dict[str, Any]:
    settings = _mapping(settings, "Bazarr settings")
    declarations = _mapping(declarations, "normalized Bazarr declarations")
    username = _required_string(username, "Bazarr administrator username")
    password = _required_string(password, "Bazarr administrator password")
    radarr_api_key = _required_string(radarr_api_key, "Radarr API key")
    sonarr_api_key = _required_string(sonarr_api_key, "Sonarr API key")
    auth = _mapping(settings.get("auth"), "Bazarr auth settings")
    general = _mapping(settings.get("general"), "Bazarr general settings")
    radarr = _mapping(settings.get("radarr"), "Bazarr Radarr settings")
    sonarr = _mapping(settings.get("sonarr"), "Bazarr Sonarr settings")

    masked_connection_settings = []
    readable_connection_settings = {}
    desired_connection_settings = {
        "auth.password": hashlib.md5(
            password.encode("utf-8"), usedforsecurity=False
        ).hexdigest(),
        "radarr.apikey": radarr_api_key,
        "sonarr.apikey": sonarr_api_key,
    }
    for section_name, section, setting_name in [
        ("auth", auth, "password"),
        ("radarr", radarr, "apikey"),
        ("sonarr", sonarr, "apikey"),
    ]:
        value = _required_string(
            section.get(setting_name),
            f"Bazarr {section_name} {setting_name}",
            allow_empty=True,
        )
        projection_name = f"{section_name}.{setting_name}"
        if MASKED_VALUE.fullmatch(value):
            masked_connection_settings.append(projection_name)
        else:
            readable_connection_settings[projection_name] = value

    enabled_providers = []
    for name in _sequence(
        general.get("enabled_providers"), "Bazarr enabled provider state"
    ):
        enabled_providers.append(
            _required_string(name, "Bazarr enabled provider state entry")
        )
    if len(enabled_providers) != len(set(enabled_providers)):
        raise AnsibleFilterError("Bazarr enabled provider state is ambiguous")
    declared_names = declarations.get("provider_names")
    declared_names = _sequence(declared_names, "normalized Bazarr provider names")

    language_entries = _sequence(language_state, "Bazarr language state")
    language_codes = []
    current_languages = []
    for entry in language_entries:
        entry = _mapping(entry, "Bazarr language state entry")
        code = _required_string(entry.get("code2"), "Bazarr language code")
        if not re.fullmatch(r"[a-z0-9_-]+", code):
            raise AnsibleFilterError("Bazarr language state uses a non-canonical code")
        language_codes.append(code)
        if _strict_boolean(entry.get("enabled"), f"Bazarr language {code!r} enabled"):
            current_languages.append(code)
    if len(language_codes) != len(set(language_codes)):
        raise AnsibleFilterError("Bazarr language state contains duplicate identities")

    current_connection = {
        "auth": {
            # Bazarr 1.6.0 explicitly defaults auth.type to None; retain that
            # supported value as drift so the form-auth POST can repair it.
            "type": (
                None
                if auth.get("type") is None
                else _required_string(auth.get("type"), "Bazarr auth type")
            ),
            "username": _required_string(auth.get("username"), "Bazarr auth username"),
        },
        "general": {
            "use_radarr": _strict_boolean(
                general.get("use_radarr"), "Bazarr Radarr enablement"
            ),
            "use_sonarr": _strict_boolean(
                general.get("use_sonarr"), "Bazarr Sonarr enablement"
            ),
            "path_mappings": _bazarr_path_mappings(
                general.get("path_mappings"), "Bazarr series path mappings"
            ),
            "path_mappings_movie": _bazarr_path_mappings(
                general.get("path_mappings_movie"), "Bazarr movie path mappings"
            ),
            "enabled_providers": sorted(
                name for name in enabled_providers if name in declared_names
            ),
        },
        "radarr": {
            "ip": _required_string(radarr.get("ip"), "Bazarr Radarr host"),
            "port": _strict_integer(radarr.get("port"), "Bazarr Radarr port"),
            "base_url": _required_string(
                radarr.get("base_url"), "Bazarr Radarr base URL", allow_empty=True
            ),
            "ssl": _strict_boolean(radarr.get("ssl"), "Bazarr Radarr SSL flag"),
        },
        "sonarr": {
            "ip": _required_string(sonarr.get("ip"), "Bazarr Sonarr host"),
            "port": _strict_integer(sonarr.get("port"), "Bazarr Sonarr port"),
            "base_url": _required_string(
                sonarr.get("base_url"), "Bazarr Sonarr base URL", allow_empty=True
            ),
            "ssl": _strict_boolean(sonarr.get("ssl"), "Bazarr Sonarr SSL flag"),
        },
        "languages": sorted(current_languages),
        "readable_secrets": readable_connection_settings,
    }
    desired_connection = {
        "auth": {"type": "form", "username": username},
        "general": {
            "use_radarr": True,
            "use_sonarr": True,
            "path_mappings": [],
            "path_mappings_movie": [],
            "enabled_providers": sorted(declared_names),
        },
        "radarr": {"ip": "radarr", "port": 7878, "base_url": "", "ssl": False},
        "sonarr": {"ip": "sonarr", "port": 8989, "base_url": "", "ssl": False},
        "languages": declarations.get("languages"),
        "readable_secrets": {
            name: desired_connection_settings[name]
            for name in readable_connection_settings
        },
    }

    current_provider_projection = {}
    desired_provider_projection = {}
    masked_provider_settings = []
    desired_settings_by_provider = _mapping(
        declarations.get("provider_settings"), "normalized Bazarr provider settings"
    )
    for provider_name in declared_names:
        current_provider = settings.get(provider_name, {})
        current_provider = _mapping(
            current_provider, f"Bazarr provider {provider_name!r} current settings"
        )
        current_readable = {}
        desired_readable = {}
        desired_settings = _mapping(
            desired_settings_by_provider.get(provider_name),
            f"Bazarr provider {provider_name!r} desired settings",
        )
        for setting_name, current_value in current_provider.items():
            setting_name = _required_string(
                setting_name, f"Bazarr provider {provider_name!r} current setting name"
            )
            if isinstance(current_value, str) and MASKED_VALUE.fullmatch(current_value):
                masked_provider_settings.append(f"{provider_name}.{setting_name}")
                continue
            normalized_current = _safe_setting_value(
                current_value,
                f"Bazarr provider {provider_name!r} setting {setting_name!r}",
            )
            current_readable[setting_name] = normalized_current
            desired_readable[setting_name] = deepcopy(normalized_current)
        for setting_name, desired_value in desired_settings.items():
            if setting_name not in current_provider:
                desired_readable[setting_name] = deepcopy(desired_value)
                continue
            current_value = current_provider[setting_name]
            if isinstance(current_value, str) and MASKED_VALUE.fullmatch(current_value):
                continue
            current_readable[setting_name] = _provider_current_value(
                current_value,
                desired_value,
                f"Bazarr provider {provider_name!r} setting {setting_name!r}",
            )
            desired_readable[setting_name] = deepcopy(desired_value)
        current_provider_projection[provider_name] = current_readable
        desired_provider_projection[provider_name] = desired_readable

    return {
        "current": {
            "connection": current_connection,
            "providers": current_provider_projection,
        },
        "desired": {
            "connection": desired_connection,
            "providers": desired_provider_projection,
        },
        "unmanaged_enabled_providers": sorted(
            name for name in enabled_providers if name not in declared_names
        ),
        "masked_connection_settings": sorted(masked_connection_settings),
        "masked_provider_settings": sorted(masked_provider_settings),
    }


def acquisition_bazarr_connection_body(
    declarations: Any,
    username: Any,
    password: Any,
    radarr_api_key: Any,
    sonarr_api_key: Any,
    unmanaged_enabled_providers: Any = None,
) -> dict[str, Any]:
    declarations = _mapping(declarations, "normalized Bazarr declarations")
    unmanaged = _sequence(
        unmanaged_enabled_providers or [], "unmanaged Bazarr provider names"
    )
    provider_names = sorted(set(declarations.get("provider_names", [])).union(unmanaged))
    languages = declarations.get("languages", [])
    return {
        "settings-auth-type": "form",
        "settings-auth-username": _required_string(username, "Bazarr administrator username"),
        "settings-auth-password": _required_string(password, "Bazarr administrator password"),
        "settings-general-use_radarr": "true",
        "settings-general-use_sonarr": "true",
        "settings-radarr-ip": "radarr",
        "settings-radarr-port": "7878",
        "settings-radarr-base_url": "",
        "settings-radarr-ssl": "false",
        "settings-radarr-apikey": _required_string(radarr_api_key, "Radarr API key"),
        "settings-sonarr-ip": "sonarr",
        "settings-sonarr-port": "8989",
        "settings-sonarr-base_url": "",
        "settings-sonarr-ssl": "false",
        "settings-sonarr-apikey": _required_string(sonarr_api_key, "Sonarr API key"),
        "settings-general-path_mappings": ["null"],
        "settings-general-path_mappings_movie": ["null"],
        "languages-enabled": languages if languages else ["null"],
        "settings-general-enabled_providers": provider_names if provider_names else ["null"],
    }


def _unique_named(collection: Any, label: str) -> list[dict[str, Any]]:
    items = _sequence(collection, label)
    names = []
    normalized = []
    for item in items:
        item = _mapping(item, f"{label} item")
        names.append(_required_string(item.get("name"), f"{label} item name"))
        normalized.append(item)
    if len(names) != len(set(names)):
        raise AnsibleFilterError(f"{label} contains duplicate identities")
    return normalized


def _validate_unique_numeric_identities(
    collection: Any, label: str, field: str = "id"
) -> None:
    identifiers = []
    for item in _sequence(collection, label):
        item = _mapping(item, f"{label} item")
        identifiers.append(
            _strict_integer(item.get(field), f"{label} item {field}")
        )
    if len(identifiers) != len(set(identifiers)):
        raise AnsibleFilterError(f"{label} contains duplicate numeric identities")


def _quality_item_projection(item: Any, label: str) -> dict[str, Any]:
    item = _mapping(item, label)
    allowed = _strict_boolean(item.get("allowed"), f"{label} allowed")
    children = _sequence(item.get("items", []), f"{label} items")
    if isinstance(item.get("quality"), dict):
        if children:
            raise AnsibleFilterError(f"{label} quality item cannot contain child items")
        return {
            "kind": "quality",
            "name": _required_string(item["quality"].get("name"), f"{label} quality name"),
            "allowed": allowed,
        }
    name = _required_string(item.get("name"), f"{label} group name")
    if not children:
        raise AnsibleFilterError(f"{label} quality group must contain child items")
    return {
        "kind": "group",
        "name": name,
        "allowed": allowed,
        "items": [
            _quality_item_projection(child, f"{label} group {name!r} item")
            for child in children
        ],
    }


def _quality_item_identities(items: Any, label: str) -> dict[int, str]:
    identities: dict[int, str] = {}

    def collect(item: Any, item_label: str) -> None:
        item = _mapping(item, item_label)
        quality = item.get("quality")
        if isinstance(quality, dict):
            identifier = _strict_integer(quality.get("id"), f"{item_label} quality id")
            name = _required_string(quality.get("name"), f"{item_label} quality name")
        else:
            identifier = _strict_integer(item.get("id"), f"{item_label} group id")
            name = _required_string(item.get("name"), f"{item_label} group name")
        if identifier in identities:
            raise AnsibleFilterError(f"{label} contains duplicate numeric identities")
        identities[identifier] = name
        for child in _sequence(item.get("items", []), f"{item_label} items"):
            collect(child, f"{item_label} child")

    for item in _sequence(items, label):
        collect(item, f"{label} item")
    return identities


def _projected_quality_names(item: Any) -> list[str]:
    item = _mapping(item, "Configarr projected quality item")
    if item.get("kind") == "quality":
        return [_required_string(item.get("name"), "Configarr projected quality name")]
    if item.get("kind") != "group":
        raise AnsibleFilterError("Configarr projected quality item kind is invalid")
    return [
        name
        for child in _sequence(item.get("items"), "Configarr projected group items")
        for name in _projected_quality_names(child)
    ]


def _quality_definition_projection(
    item: Any, label: str, service: str
) -> dict[str, Any]:
    # Pinned API contracts:
    # https://github.com/Radarr/Radarr/blob/v6.3.0.10514/src/Radarr.Api.V3/Qualities/QualityDefinitionResource.cs
    # https://github.com/Sonarr/Sonarr/blob/v4.0.19.3007/src/Sonarr.Api.V3/Qualities/QualityDefinitionResource.cs
    item = _mapping(item, label)
    quality = _mapping(item.get("quality"), f"{label} quality")
    quality_projection = {
        "id": _strict_integer(quality.get("id"), f"{label} quality id"),
        "name": _required_string(quality.get("name"), f"{label} quality name"),
        "source": _required_string(quality.get("source"), f"{label} quality source"),
        "resolution": _strict_integer(
            quality.get("resolution"), f"{label} quality resolution"
        ),
    }
    if service == "radarr":
        quality_projection["modifier"] = _required_string(
            quality.get("modifier"), f"{label} quality modifier"
        )
    elif service != "sonarr":
        raise AnsibleFilterError("Configarr quality-definition service is invalid")
    return {
        "id": _strict_integer(item.get("id"), f"{label} id"),
        "quality": quality_projection,
        "title": _required_string(item.get("title"), f"{label} title"),
        "weight": _strict_integer(item.get("weight"), f"{label} weight"),
        "minSize": _nullable_number(item.get("minSize"), f"{label} minSize"),
        "preferredSize": _nullable_number(
            item.get("preferredSize"), f"{label} preferredSize"
        ),
        "maxSize": _nullable_number(item.get("maxSize"), f"{label} maxSize"),
    }


def _specification_projection(item: Any, label: str) -> dict[str, Any]:
    item = _mapping(item, label)
    fields = _fields(item.get("fields"))
    return {
        "name": _required_string(item.get("name"), f"{label} name"),
        "implementation": _required_string(
            item.get("implementation"), f"{label} implementation"
        ),
        "negate": _strict_boolean(item.get("negate"), f"{label} negate"),
        "required": _strict_boolean(item.get("required"), f"{label} required"),
        "fields": {
            name: _safe_setting_value(value, f"{label} field {name!r}")
            for name, value in sorted(fields.items())
        },
    }


def _configarr_result_resources(results: Any) -> dict[str, dict[str, Any]]:
    endpoints = ("qualityprofile", "qualitydefinition", "customformat", "config/naming")
    grouped = {service: {endpoint: [] for endpoint in endpoints} for service in ["radarr", "sonarr"]}
    for result in _sequence(results, "Configarr API results"):
        result = _mapping(result, "Configarr API result")
        item = _sequence(result.get("item"), "Configarr API result identity")
        if len(item) != 2:
            raise AnsibleFilterError("Configarr API result identity must have two entries")
        instance = _mapping(item[0], "Configarr API result instance")
        service = _required_string(instance.get("name"), "Configarr API service name")
        endpoint = _required_string(item[1], "Configarr API resource name")
        if service in grouped and endpoint in endpoints:
            grouped[service][endpoint].append(result.get("json"))
    resources = {"radarr": {}, "sonarr": {}}
    for service in resources:
        for endpoint in endpoints:
            matches = grouped[service][endpoint]
            if len(matches) != 1:
                raise AnsibleFilterError(
                    f"Configarr {service} {endpoint} readback identity is ambiguous"
                )
            resources[service][endpoint] = matches[0]
    return resources


def acquisition_configarr_owned_projection(results: Any) -> dict[str, Any]:
    resources_by_service = _configarr_result_resources(results)
    projection = {}
    profile_name = "HD Bluray + WEB 1080p"
    format_name = "NAS Repack or Proper"
    for service in ["radarr", "sonarr"]:
        resources = resources_by_service[service]
        profiles = _unique_named(resources["qualityprofile"], f"Configarr {service} profiles")
        if not profiles:
            raise AnsibleFilterError(f"Configarr {service} profiles are empty")
        _validate_unique_numeric_identities(
            profiles, f"Configarr {service} profiles"
        )
        profile_matches = [item for item in profiles if item["name"] == profile_name]
        if len(profile_matches) > 1:
            raise AnsibleFilterError(f"Configarr {service} owned profile identity is ambiguous")

        definitions = [
            _quality_definition_projection(
                item, f"Configarr {service} quality definition", service
            )
            for item in _sequence(
                resources["qualitydefinition"], f"Configarr {service} quality definitions"
            )
        ]
        if not definitions:
            raise AnsibleFilterError(f"Configarr {service} quality definitions are empty")
        definition_names = [item["quality"]["name"] for item in definitions]
        if len(definition_names) != len(set(definition_names)):
            raise AnsibleFilterError(
                f"Configarr {service} quality definitions contain duplicate identities"
            )
        _validate_unique_numeric_identities(
            definitions, f"Configarr {service} quality definitions"
        )
        quality_identifiers = [item["quality"]["id"] for item in definitions]
        if len(quality_identifiers) != len(set(quality_identifiers)):
            raise AnsibleFilterError(
                f"Configarr {service} quality definitions contain duplicate quality IDs"
            )

        formats = _unique_named(
            resources["customformat"], f"Configarr {service} custom formats"
        )
        _validate_unique_numeric_identities(
            formats, f"Configarr {service} custom formats"
        )
        format_matches = [item for item in formats if item["name"] == format_name]
        if len(format_matches) > 1:
            raise AnsibleFilterError(
                f"Configarr {service} owned custom format identity is ambiguous"
            )

        profile_projection = None
        if profile_matches:
            profile = profile_matches[0]
            raw_items = _sequence(
                profile.get("items"), f"Configarr {service} quality items"
            )
            quality_identities = _quality_item_identities(
                raw_items, f"Configarr {service} quality items"
            )
            cutoff = _strict_integer(
                profile.get("cutoff"), f"Configarr {service} quality-profile cutoff"
            )
            if cutoff not in quality_identities:
                raise AnsibleFilterError(
                    f"Configarr {service} quality-profile cutoff identity is unavailable"
                )
            format_items = _unique_named(
                profile.get("formatItems"),
                f"Configarr {service} format-score assignments",
            )
            _validate_unique_numeric_identities(
                format_items,
                f"Configarr {service} format-score assignments",
                "format",
            )
            score_matches = [item for item in format_items if item["name"] == format_name]
            if len(score_matches) > 1:
                raise AnsibleFilterError(
                    f"Configarr {service} owned format-score identity is ambiguous"
                )
            format_assignments = [
                {
                    "format": _strict_integer(
                        item.get("format"),
                        f"Configarr {service} format identity for {item['name']!r}",
                    ),
                    "name": item["name"],
                    "score": _strict_integer(
                        item.get("score"),
                        f"Configarr {service} format score for {item['name']!r}",
                    ),
                }
                for item in format_items
            ]
            format_assignments.sort(key=lambda item: item["name"])
            profile_projection = {
                "name": profile["name"],
                "upgradeAllowed": _strict_boolean(
                    profile.get("upgradeAllowed"),
                    f"Configarr {service} upgradeAllowed",
                ),
                "cutoff": quality_identities[cutoff],
                "minFormatScore": _strict_integer(
                    profile.get("minFormatScore"),
                    f"Configarr {service} minFormatScore",
                ),
                "cutoffFormatScore": _strict_integer(
                    profile.get("cutoffFormatScore"),
                    f"Configarr {service} cutoffFormatScore",
                ),
                "minUpgradeFormatScore": _strict_integer(
                    profile.get("minUpgradeFormatScore"),
                    f"Configarr {service} minUpgradeFormatScore",
                ),
                "items": [
                    _quality_item_projection(item, f"Configarr {service} quality item")
                    for item in raw_items
                ],
                "format_assignment_identity_count": len(score_matches),
                "format_assignments": format_assignments,
            }

        custom_format_projection = None
        if format_matches:
            custom_format = format_matches[0]
            specifications = [
                _specification_projection(
                    item, f"Configarr {service} custom-format specification"
                )
                for item in _sequence(
                    custom_format.get("specifications"),
                    f"Configarr {service} custom-format specifications",
                )
            ]
            specification_identities = [
                (item["name"], item["implementation"]) for item in specifications
            ]
            if len(specification_identities) != len(set(specification_identities)):
                raise AnsibleFilterError(
                    f"Configarr {service} custom-format specifications are ambiguous"
                )
            specifications.sort(key=lambda item: (item["name"], item["implementation"]))
            custom_format_projection = {
                "name": custom_format["name"],
                "includeCustomFormatWhenRenaming": _strict_boolean(
                    custom_format.get("includeCustomFormatWhenRenaming"),
                    f"Configarr {service} includeCustomFormatWhenRenaming",
                ),
                "specifications": specifications,
            }

        naming = _mapping(resources["config/naming"], f"Configarr {service} naming")
        naming_fields = (
            ["renameMovies", "standardMovieFormat", "movieFolderFormat"]
            if service == "radarr"
            else [
                "renameEpisodes",
                "standardEpisodeFormat",
                "dailyEpisodeFormat",
                "animeEpisodeFormat",
                "seriesFolderFormat",
                "seasonFolderFormat",
            ]
        )
        normalized_naming = {}
        for name in naming_fields:
            if name.startswith("rename"):
                normalized_naming[name] = _strict_boolean(
                    naming.get(name), f"Configarr {service} naming field {name}"
                )
            else:
                normalized_naming[name] = _nullable_string(
                    naming.get(name), f"Configarr {service} naming field {name}"
                )

        projection[service] = {
            "quality_profile_identity_count": len(profile_matches),
            "quality_profile_id": (
                _strict_integer(
                    profile_matches[0].get("id"),
                    f"Configarr {service} owned profile id",
                )
                if profile_matches
                else None
            ),
            "quality_profile": profile_projection,
            "quality_definitions": sorted(
                definitions, key=lambda item: item["quality"]["name"]
            ),
            "custom_format_identity_count": len(format_matches),
            "custom_format_id": (
                _strict_integer(
                    format_matches[0].get("id"),
                    f"Configarr {service} owned custom-format id",
                )
                if format_matches
                else None
            ),
            "custom_format": custom_format_projection,
            "naming": normalized_naming,
        }
    return projection


def _configarr_quality_definition_source(
    source: Any, service: str
) -> dict[str, dict[str, Any]]:
    if not isinstance(source, str) or not source:
        raise AnsibleFilterError(
            f"Configarr {service} quality-definition source must be a non-empty string"
        )
    if "\x00" in source:
        raise AnsibleFilterError(
            f"Configarr {service} quality-definition source contains a NUL byte"
        )

    def reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
        value = {}
        for key, item in pairs:
            if key in value:
                raise AnsibleFilterError(
                    f"Configarr {service} quality-definition source has duplicate keys"
                )
            value[key] = item
        return value

    try:
        document = _mapping(
            json.loads(source, object_pairs_hook=reject_duplicate_keys),
            f"Configarr {service} quality-definition source",
        )
    except json.JSONDecodeError as error:
        raise AnsibleFilterError(
            f"Configarr {service} quality-definition source cannot be parsed"
        ) from error

    expected_metadata = {
        "radarr": {
            "trash_id": "aed34b9f60ee115dfa7918b742336277",
            "type": "movie",
        },
        "sonarr": {
            "trash_id": "bef99584217af744e404ed44a33af589",
            "type": "series",
        },
    }
    if service not in expected_metadata:
        raise AnsibleFilterError("Configarr quality-definition service is invalid")
    expected = expected_metadata[service]
    if document.get("trash_id") != expected["trash_id"]:
        raise AnsibleFilterError(
            f"Configarr {service} quality-definition source identity differs"
        )
    if document.get("type") != expected["type"]:
        raise AnsibleFilterError(
            f"Configarr {service} quality-definition source type differs"
        )

    normalized = {}
    for entry in _sequence(
        document.get("qualities"),
        f"Configarr {service} quality-definition source qualities",
    ):
        entry = _mapping(
            entry, f"Configarr {service} quality-definition source entry"
        )
        name = _required_string(
            entry.get("quality"),
            f"Configarr {service} source quality identity",
        )
        if name in normalized:
            raise AnsibleFilterError(
                f"Configarr {service} quality-definition source identities are ambiguous"
            )
        value = {
            "quality": name,
            "minSize": _number(
                entry.get("min"), f"Configarr {service} source {name!r} min"
            ),
            "preferredSize": _number(
                entry.get("preferred"),
                f"Configarr {service} source {name!r} preferred",
            ),
            "maxSize": _number(
                entry.get("max"), f"Configarr {service} source {name!r} max"
            ),
        }
        if "title" in entry:
            value["title"] = _required_string(
                entry.get("title"), f"Configarr {service} source {name!r} title"
            )
        normalized[name] = value
    if not normalized:
        raise AnsibleFilterError(
            f"Configarr {service} quality-definition source is empty"
        )
    return normalized


def acquisition_configarr_quality_definition_invariants(
    projection: Any, sources: Any
) -> dict[str, Any]:
    """Separate pinned Configarr outputs from irreducible Servarr context.

    Configarr v1.28.0 owns minSize/maxSize/preferredSize (and title only when
    present in its source document). Servarr owns the remaining identities and
    metadata. The latter therefore needs continuity, not synthetic desired data.
    https://github.com/raydak-labs/configarr/blob/v1.28.0/src/quality-definitions.ts
    """
    projection = _mapping(projection, "Configarr owned projection")
    sources = _mapping(sources, "Configarr quality-definition sources")
    if set(sources) != {"radarr", "sonarr"}:
        raise AnsibleFilterError(
            "Configarr quality-definition sources must contain exactly Radarr and Sonarr"
        )

    source_current = {}
    source_desired = {}
    opaque_context = {}
    for service in ["radarr", "sonarr"]:
        expected_by_name = _configarr_quality_definition_source(
            sources[service], service
        )
        service_projection = _mapping(
            projection.get(service), f"Configarr {service} owned projection"
        )
        current_items = []
        desired_items = []
        opaque_items = []
        for definition in _sequence(
            service_projection.get("quality_definitions"),
            f"Configarr {service} projected quality definitions",
        ):
            definition = _mapping(
                definition, f"Configarr {service} projected quality definition"
            )
            quality = _mapping(
                definition.get("quality"),
                f"Configarr {service} projected quality identity",
            )
            name = _required_string(
                quality.get("name"), f"Configarr {service} projected quality name"
            )
            opaque = {
                "id": _strict_integer(
                    definition.get("id"), f"Configarr {service} projected definition id"
                ),
                "quality": deepcopy(quality),
                "title": _required_string(
                    definition.get("title"),
                    f"Configarr {service} projected definition title",
                ),
                "weight": _strict_integer(
                    definition.get("weight"),
                    f"Configarr {service} projected definition weight",
                ),
            }
            expected = expected_by_name.get(name)
            if expected is None:
                opaque.update(
                    {
                        "minSize": _nullable_number(
                            definition.get("minSize"),
                            f"Configarr {service} projected {name!r} minSize",
                        ),
                        "preferredSize": _nullable_number(
                            definition.get("preferredSize"),
                            f"Configarr {service} projected {name!r} preferredSize",
                        ),
                        "maxSize": _nullable_number(
                            definition.get("maxSize"),
                            f"Configarr {service} projected {name!r} maxSize",
                        ),
                    }
                )
            else:
                current = {
                    "quality": name,
                    "minSize": _nullable_number(
                        definition.get("minSize"),
                        f"Configarr {service} projected {name!r} minSize",
                    ),
                    "preferredSize": _nullable_number(
                        definition.get("preferredSize"),
                        f"Configarr {service} projected {name!r} preferredSize",
                    ),
                    "maxSize": _nullable_number(
                        definition.get("maxSize"),
                        f"Configarr {service} projected {name!r} maxSize",
                    ),
                }
                desired = {
                    key: deepcopy(value)
                    for key, value in expected.items()
                    if key != "title"
                }
                if "title" in expected:
                    current["title"] = opaque["title"]
                    desired["title"] = expected["title"]
                    opaque.pop("title")
                current_items.append(current)
                desired_items.append(desired)
            opaque_items.append(opaque)

        current_items.sort(key=lambda item: item["quality"])
        desired_items.sort(key=lambda item: item["quality"])
        opaque_items.sort(key=lambda item: (item["quality"]["name"], item["id"]))
        source_current[service] = current_items
        source_desired[service] = desired_items
        opaque_context[service] = opaque_items

    return {
        "source_current": source_current,
        "source_desired": source_desired,
        "opaque_context": opaque_context,
    }


def acquisition_configarr_declared_projection(projection: Any) -> dict[str, Any]:
    projection = _mapping(projection, "Configarr owned projection")
    declared = {}
    format_name = "NAS Repack or Proper"
    for service in ["radarr", "sonarr"]:
        state = _mapping(projection.get(service), f"Configarr {service} owned projection")
        profile = state.get("quality_profile")
        profile_projection = None
        if profile is not None:
            profile = _mapping(profile, f"Configarr {service} quality-profile projection")
            items = _sequence(profile.get("items"), f"Configarr {service} projected items")
            disabled_items = []
            enabled_items = []
            enabled_started = False
            top_order = True
            disabled_started = False
            bottom_order = True
            for item in items:
                item = _mapping(item, f"Configarr {service} projected item")
                if _strict_boolean(item.get("allowed"), "Configarr projected item allowed"):
                    if disabled_started:
                        bottom_order = False
                    enabled_started = True
                    enabled_items.append(deepcopy(item))
                else:
                    if enabled_started:
                        top_order = False
                    disabled_started = True
                    disabled_items.append(item)
            all_quality_names = sorted(
                name for item in items for name in _projected_quality_names(item)
            )
            disabled_quality_names = sorted(
                name
                for item in disabled_items
                for name in _projected_quality_names(item)
            )
            assignments = _sequence(
                profile.get("format_assignments"),
                f"Configarr {service} projected format assignments",
            )
            assignment_matches = [
                item
                for item in assignments
                if _mapping(item, "Configarr projected format assignment").get("name")
                == format_name
            ]
            assignment = (
                {
                    "format": assignment_matches[0]["format"],
                    "name": assignment_matches[0]["name"],
                    "score": assignment_matches[0]["score"],
                }
                if len(assignment_matches) == 1
                else None
            )
            unmatched_scores_reset = all(
                item.get("name") == format_name
                or _strict_integer(
                    item.get("score"), "Configarr unmatched format score"
                ) == 0
                for item in assignments
            )
            if top_order:
                materialized_quality_sort = "top"
            elif bottom_order:
                materialized_quality_sort = "bottom"
            else:
                materialized_quality_sort = "nonconforming"
            profile_projection = {
                "name": profile["name"],
                "upgradeAllowed": profile["upgradeAllowed"],
                "cutoff": profile["cutoff"],
                "minFormatScore": profile["minFormatScore"],
                "cutoffFormatScore": profile["cutoffFormatScore"],
                "minUpgradeFormatScore": profile["minUpgradeFormatScore"],
                "resetUnmatchedScores": unmatched_scores_reset,
                "qualitySort": materialized_quality_sort,
                "items": {
                    "quality_names": all_quality_names,
                    "disabled_quality_names": disabled_quality_names,
                    "enabled": enabled_items,
                },
                "format_assignment": {
                    "identity_count": len(assignment_matches),
                    "value": assignment,
                },
            }
        declared[service] = {
            "quality_profile_identity_count": state["quality_profile_identity_count"],
            "quality_profile": profile_projection,
            "custom_format_identity_count": state["custom_format_identity_count"],
            "custom_format": deepcopy(state["custom_format"]),
            "naming": deepcopy(state["naming"]),
        }
    return declared


def acquisition_configarr_desired_projection(
    config_source: Any, current_projection: Any
) -> dict[str, Any]:
    # Configarr v1.28.0 materializes every quality, reverses configured API
    # order, resets unmatched scores, and derives disabled-upgrade cutoff fields:
    # https://github.com/raydak-labs/configarr/blob/v1.28.0/src/quality-profiles.ts
    if not isinstance(config_source, str) or not config_source:
        raise AnsibleFilterError("Configarr configuration source must be a non-empty string")
    if "\x00" in config_source:
        raise AnsibleFilterError("Configarr configuration source contains a NUL byte")
    sanitized = re.sub(r"!secret\s+[A-Z_]+", '"opaque-secret"', config_source)
    try:
        config = yaml.safe_load(sanitized)
    except yaml.YAMLError as error:
        raise AnsibleFilterError("Configarr configuration cannot be parsed") from error
    config = _mapping(config, "Configarr configuration")
    current_projection = _mapping(
        current_projection, "Configarr current owned projection"
    )
    definitions = _sequence(
        config.get("customFormatDefinitions"), "Configarr custom-format definitions"
    )
    matching_definitions = [
        _mapping(item, "Configarr custom-format definition")
        for item in definitions
        if isinstance(item, dict) and item.get("name") == "NAS Repack or Proper"
    ]
    if len(matching_definitions) != 1:
        raise AnsibleFilterError("Configarr owned custom-format declaration is ambiguous")
    format_definition = matching_definitions[0]
    trash_id = _required_string(
        format_definition.get("trash_id"), "Configarr owned custom-format trash id"
    )
    specifications = []
    for item in _sequence(
        format_definition.get("specifications"),
        "Configarr owned custom-format specifications",
    ):
        item = _mapping(item, "Configarr owned custom-format specification")
        fields = _mapping(item.get("fields"), "Configarr owned custom-format fields")
        specifications.append(
            {
                "name": _required_string(item.get("name"), "Configarr specification name"),
                "implementation": _required_string(
                    item.get("implementation"), "Configarr specification implementation"
                ),
                "negate": _strict_boolean(item.get("negate"), "Configarr specification negate"),
                "required": _strict_boolean(
                    item.get("required"), "Configarr specification required"
                ),
                "fields": {
                    name: _safe_setting_value(value, f"Configarr specification field {name!r}")
                    for name, value in sorted(fields.items())
                },
            }
        )
    specifications.sort(key=lambda item: (item["name"], item["implementation"]))

    desired = {}
    for service in ["radarr", "sonarr"]:
        current_service = _mapping(
            current_projection.get(service), f"Configarr {service} current projection"
        )
        definition_names = [
            _required_string(
                _mapping(
                    item.get("quality"), "Configarr quality-definition identity"
                ).get("name"),
                "Configarr quality-definition name",
            )
            for item in _sequence(
                current_service.get("quality_definitions"),
                f"Configarr {service} current quality definitions",
            )
        ]
        service_config = _mapping(config.get(service), f"Configarr {service} configuration")
        if len(service_config) != 1:
            raise AnsibleFilterError(f"Configarr {service} instance identity is ambiguous")
        policy = _mapping(next(iter(service_config.values())), f"Configarr {service} policy")
        profiles = _unique_named(
            policy.get("quality_profiles"), f"Configarr {service} declared profiles"
        )
        profile_matches = [
            item for item in profiles if item["name"] == "HD Bluray + WEB 1080p"
        ]
        if len(profile_matches) != 1:
            raise AnsibleFilterError(f"Configarr {service} owned profile declaration is ambiguous")
        profile = profile_matches[0]
        configured_quality_items = []
        configured_quality_names = []
        for quality in _sequence(
            profile.get("qualities"), f"Configarr {service} declared qualities"
        ):
            quality = _mapping(quality, f"Configarr {service} declared quality")
            name = _required_string(quality.get("name"), "Configarr declared quality name")
            allowed = _strict_boolean(
                quality.get("enabled", True), "Configarr declared quality enabled"
            )
            if not allowed:
                raise AnsibleFilterError(
                    "Configarr Phase 1 declared qualities must remain enabled"
                )
            if "qualities" in quality:
                child_names = [
                    _required_string(child, "Configarr child quality")
                    for child in _sequence(
                        quality.get("qualities"), "Configarr declared child qualities"
                    )
                ]
                configured_quality_names.extend(child_names)
                configured_quality_items.append(
                    {
                        "kind": "group",
                        "name": name,
                        "allowed": True,
                        "items": [
                            {"kind": "quality", "name": child, "allowed": True}
                            for child in reversed(child_names)
                        ],
                    }
                )
            else:
                configured_quality_names.append(name)
                configured_quality_items.append(
                    {"kind": "quality", "name": name, "allowed": True}
                )
        if len(configured_quality_names) != len(set(configured_quality_names)):
            raise AnsibleFilterError(
                f"Configarr {service} declared quality identities are ambiguous"
            )
        disabled_quality_names = sorted(
            set(definition_names).difference(configured_quality_names)
        )
        enabled_quality_items = list(reversed(configured_quality_items))

        assignments = _sequence(
            policy.get("custom_formats"), f"Configarr {service} custom-format assignments"
        )
        assignment_matches = [
            _mapping(item, "Configarr custom-format assignment")
            for item in assignments
            if isinstance(item, dict) and trash_id in item.get("trash_ids", [])
        ]
        if len(assignment_matches) != 1:
            raise AnsibleFilterError(
                f"Configarr {service} owned custom-format assignment is ambiguous"
            )
        scores = _unique_named(
            assignment_matches[0].get("assign_scores_to"),
            f"Configarr {service} format-score declarations",
        )
        score_matches = [
            item for item in scores if item["name"] == "HD Bluray + WEB 1080p"
        ]
        if len(score_matches) != 1:
            raise AnsibleFilterError(
                f"Configarr {service} owned format-score declaration is ambiguous"
            )

        # Literal Servarr naming formats use Configarr's raw API escape hatch.
        # `media_naming` is reserved for TRaSH preset keys in pinned v1.28.0:
        # https://github.com/raydak-labs/configarr/blob/v1.28.0/src/config.ts#L1086-L1162
        naming = _mapping(
            policy.get("media_naming_api"), f"Configarr {service} naming API policy"
        )
        if service == "radarr":
            desired_naming = {
                "renameMovies": _strict_boolean(
                    naming.get("renameMovies"), "Configarr Radarr rename flag"
                ),
                "standardMovieFormat": _required_string(
                    naming.get("standardMovieFormat"),
                    "Configarr Radarr standard naming",
                ),
                "movieFolderFormat": _required_string(
                    naming.get("movieFolderFormat"), "Configarr Radarr folder naming"
                ),
            }
        else:
            desired_naming = {
                "renameEpisodes": _strict_boolean(
                    naming.get("renameEpisodes"), "Configarr Sonarr rename flag"
                ),
                "standardEpisodeFormat": _required_string(
                    naming.get("standardEpisodeFormat"),
                    "Configarr Sonarr standard naming",
                ),
                "dailyEpisodeFormat": _required_string(
                    naming.get("dailyEpisodeFormat"), "Configarr Sonarr daily naming"
                ),
                "animeEpisodeFormat": _required_string(
                    naming.get("animeEpisodeFormat"), "Configarr Sonarr anime naming"
                ),
                "seriesFolderFormat": _required_string(
                    naming.get("seriesFolderFormat"),
                    "Configarr Sonarr series naming",
                ),
                "seasonFolderFormat": _required_string(
                    naming.get("seasonFolderFormat"),
                    "Configarr Sonarr season naming",
                ),
            }

        desired[service] = {
            "quality_profile_identity_count": 1,
            "quality_profile": {
                "name": "HD Bluray + WEB 1080p",
                "upgradeAllowed": _strict_boolean(
                    _mapping(profile.get("upgrade"), "Configarr profile upgrade").get("allowed"),
                    "Configarr profile upgrade flag",
                ),
                "cutoff": _required_string(
                    _mapping(
                        _sequence(
                            profile.get("qualities"),
                            f"Configarr {service} declared qualities",
                        )[0],
                        "Configarr first declared quality",
                    ).get("name"),
                    "Configarr disabled-upgrade cutoff quality",
                ),
                "minFormatScore": _strict_integer(
                    profile.get("min_format_score"), "Configarr minimum format score"
                ),
                "cutoffFormatScore": 1,
                "minUpgradeFormatScore": 1,
                "resetUnmatchedScores": _strict_boolean(
                    _mapping(
                        profile.get("reset_unmatched_scores"),
                        "Configarr reset unmatched scores",
                    ).get("enabled"),
                    "Configarr reset unmatched scores flag",
                ),
                "qualitySort": _required_string(
                    profile.get("quality_sort"), "Configarr quality sort"
                ),
                "items": {
                    "quality_names": sorted(definition_names),
                    "disabled_quality_names": disabled_quality_names,
                    "enabled": enabled_quality_items,
                },
                "format_assignment": {
                    "identity_count": 1,
                    "value": {
                        "format": current_service.get("custom_format_id"),
                        "name": "NAS Repack or Proper",
                        "score": _strict_integer(
                            score_matches[0].get("score"),
                            "Configarr owned format score",
                        ),
                    },
                },
            },
            "custom_format_identity_count": 1,
            "custom_format": {
                "name": "NAS Repack or Proper",
                "includeCustomFormatWhenRenaming": _strict_boolean(
                    format_definition.get("includeCustomFormatWhenRenaming"),
                    "Configarr include custom format when renaming",
                ),
                "specifications": specifications,
            },
            "naming": desired_naming,
        }
    return desired


def _configarr_api_custom_format_body(value: Any, label: str) -> dict[str, Any]:
    value = _mapping(value, label)
    specifications = []
    for specification in _sequence(value.get("specifications"), f"{label} specifications"):
        specification = _mapping(specification, f"{label} specification")
        fields = _mapping(specification.get("fields"), f"{label} specification fields")
        specifications.append(
            {
                "name": _required_string(
                    specification.get("name"), f"{label} specification name"
                ),
                "implementation": _required_string(
                    specification.get("implementation"),
                    f"{label} specification implementation",
                ),
                "negate": _strict_boolean(
                    specification.get("negate"), f"{label} specification negate"
                ),
                "required": _strict_boolean(
                    specification.get("required"), f"{label} specification required"
                ),
                "fields": [
                    {
                        "name": name,
                        "value": _safe_setting_value(
                            field_value, f"{label} specification field {name!r}"
                        ),
                    }
                    for name, field_value in sorted(fields.items())
                ],
            }
        )
    return {
        "name": _required_string(value.get("name"), f"{label} name"),
        "includeCustomFormatWhenRenaming": _strict_boolean(
            value.get("includeCustomFormatWhenRenaming"), f"{label} rename flag"
        ),
        "specifications": specifications,
    }


def acquisition_configarr_missing_custom_format_bodies(
    config_source: Any, current_projection: Any
) -> dict[str, dict[str, Any]]:
    """Return exact create bodies only for globally preflighted missing targets."""
    desired = acquisition_configarr_desired_projection(
        config_source, current_projection
    )
    current_projection = _mapping(
        current_projection, "Configarr current owned projection"
    )
    bodies = {}
    for service in ["radarr", "sonarr"]:
        current = _mapping(
            current_projection.get(service), f"Configarr {service} current projection"
        )
        identity_count = _strict_integer(
            current.get("custom_format_identity_count"),
            f"Configarr {service} custom-format identity count",
        )
        if identity_count == 0:
            desired_service = _mapping(
                desired.get(service), f"Configarr {service} desired projection"
            )
            bodies[service] = _configarr_api_custom_format_body(
                desired_service.get("custom_format"),
                f"Configarr {service} missing custom format",
            )
        elif identity_count != 1:
            raise AnsibleFilterError(
                f"Configarr {service} custom-format identity is ambiguous"
            )
    return bodies


def _configarr_source_policy(config_source: Any, service: str) -> dict[str, Any]:
    if not isinstance(config_source, str) or not config_source:
        raise AnsibleFilterError("Configarr configuration source must be non-empty")
    sanitized = re.sub(r"!secret\s+[A-Z_]+", '"opaque-secret"', config_source)
    try:
        config = _mapping(yaml.safe_load(sanitized), "Configarr configuration")
    except yaml.YAMLError as error:
        raise AnsibleFilterError("Configarr configuration cannot be parsed") from error
    instances = _mapping(config.get(service), f"Configarr {service} configuration")
    if len(instances) != 1:
        raise AnsibleFilterError(f"Configarr {service} instance identity is ambiguous")
    return _mapping(next(iter(instances.values())), f"Configarr {service} policy")


def _configarr_materialized_profile_items(
    policy: dict[str, Any], definitions: list[dict[str, Any]], service: str
) -> list[dict[str, Any]]:
    profiles = _unique_named(
        policy.get("quality_profiles"), f"Configarr {service} declared profiles"
    )
    matches = [item for item in profiles if item["name"] == "HD Bluray + WEB 1080p"]
    if len(matches) != 1:
        raise AnsibleFilterError(
            f"Configarr {service} owned profile declaration is ambiguous"
        )
    profile = matches[0]
    definitions_by_name = {}
    lookup = {}
    for definition in definitions:
        definition = _mapping(
            definition, f"Configarr {service} profile quality definition"
        )
        quality = _mapping(
            definition.get("quality"), f"Configarr {service} profile quality"
        )
        name = _required_string(
            quality.get("name"), f"Configarr {service} profile quality name"
        )
        if name in definitions_by_name:
            raise AnsibleFilterError(
                f"Configarr {service} quality definitions contain duplicate identities"
            )
        definitions_by_name[name] = deepcopy(quality)
        lookup[name] = definition
        title = _required_string(
            definition.get("title"), f"Configarr {service} quality title"
        )
        lookup[title] = definition

    selected_names = set()
    allowed_items = []
    for index, declaration in enumerate(
        _sequence(profile.get("qualities"), f"Configarr {service} declared qualities")
    ):
        declaration = _mapping(
            declaration, f"Configarr {service} declared quality"
        )
        name = _required_string(
            declaration.get("name"), f"Configarr {service} declared quality name"
        )
        allowed = _strict_boolean(
            declaration.get("enabled", True),
            f"Configarr {service} declared quality enabled",
        )
        if "qualities" in declaration:
            children = []
            for child_name in _sequence(
                declaration.get("qualities"),
                f"Configarr {service} declared grouped qualities",
            ):
                child_name = _required_string(
                    child_name, f"Configarr {service} grouped quality name"
                )
                definition = lookup.get(child_name)
                if definition is None:
                    raise AnsibleFilterError(
                        f"Configarr {service} declared quality {child_name!r} is unavailable"
                    )
                canonical_name = _required_string(
                    _mapping(definition.get("quality"), "Configarr quality").get("name"),
                    "Configarr canonical quality name",
                )
                selected_names.add(canonical_name)
                children.append(
                    {
                        "quality": deepcopy(definition["quality"]),
                        "allowed": allowed,
                        "items": [],
                    }
                )
            allowed_items.append(
                {
                    "id": 1000 + index,
                    "name": name,
                    "allowed": allowed,
                    "items": list(reversed(children)),
                }
            )
        else:
            definition = lookup.get(name)
            if definition is None:
                raise AnsibleFilterError(
                    f"Configarr {service} declared quality {name!r} is unavailable"
                )
            canonical_name = _required_string(
                _mapping(definition.get("quality"), "Configarr quality").get("name"),
                "Configarr canonical quality name",
            )
            selected_names.add(canonical_name)
            allowed_items.append(
                {
                    "quality": deepcopy(definition["quality"]),
                    "allowed": allowed,
                    "items": [],
                }
            )
    missing_items = [
        {"quality": deepcopy(quality), "allowed": False, "items": []}
        for name, quality in definitions_by_name.items()
        if name not in selected_names
    ]
    quality_sort = _required_string(
        profile.get("quality_sort"), f"Configarr {service} quality sort"
    )
    if quality_sort == "bottom":
        return list(reversed(allowed_items)) + missing_items
    if quality_sort != "top":
        raise AnsibleFilterError(
            f"Configarr {service} quality sort must be top or bottom"
        )
    return missing_items + list(reversed(allowed_items))


def _configarr_profile_item_ids(items: Any, label: str) -> dict[str, int]:
    identities = {}
    for item in _sequence(items, label):
        item = _mapping(item, f"{label} item")
        quality = item.get("quality")
        if isinstance(quality, dict):
            name = _required_string(quality.get("name"), f"{label} quality name")
            identifier = _strict_integer(quality.get("id"), f"{label} quality id")
        else:
            name = _required_string(item.get("name"), f"{label} group name")
            identifier = _strict_integer(item.get("id"), f"{label} group id")
        if name in identities:
            raise AnsibleFilterError(f"{label} contains duplicate named identities")
        identities[name] = identifier
        children = _configarr_profile_item_ids(
            item.get("items", []), f"{label} child"
        )
        if set(identities).intersection(children):
            raise AnsibleFilterError(f"{label} contains duplicate named identities")
        identities.update(children)
    return identities


def acquisition_configarr_profile_repair_bodies(
    config_source: Any, results: Any
) -> dict[str, dict[str, Any]]:
    """Build conservative full profile PUTs from an immediate strict readback."""
    resources_by_service = _configarr_result_resources(results)
    current = acquisition_configarr_owned_projection(results)
    desired = acquisition_configarr_desired_projection(config_source, current)
    declared = acquisition_configarr_declared_projection(current)
    repairs = {}
    for service in ["radarr", "sonarr"]:
        resources = resources_by_service[service]
        formats = _unique_named(
            resources["customformat"], f"Configarr {service} custom formats"
        )
        format_ids = []
        for custom_format in formats:
            identifier = _strict_integer(
                custom_format.get("id"), f"Configarr {service} custom-format id"
            )
            if identifier in format_ids:
                raise AnsibleFilterError(
                    f"Configarr {service} custom-format numeric identities are ambiguous"
                )
            format_ids.append(identifier)
        declared_service = _mapping(
            declared.get(service), f"Configarr {service} declared state"
        )
        current_profile = declared_service.get("quality_profile")
        if current_profile is not None:
            current_profile = _mapping(
                current_profile, f"Configarr {service} declared quality profile"
            )
        desired_profile = _mapping(
            _mapping(desired.get(service), f"Configarr {service} desired state").get(
                "quality_profile"
            ),
            f"Configarr {service} desired quality profile",
        )
        if current_profile is None or current_profile == desired_profile:
            continue

        profiles = _unique_named(
            resources["qualityprofile"], f"Configarr {service} profiles"
        )
        profile_matches = [
            item for item in profiles if item["name"] == "HD Bluray + WEB 1080p"
        ]
        if len(profile_matches) != 1:
            raise AnsibleFilterError(
                f"Configarr {service} owned profile identity is ambiguous"
            )
        body = deepcopy(profile_matches[0])
        profile_id = _strict_integer(
            body.get("id"), f"Configarr {service} quality-profile id"
        )
        definitions = _sequence(
            resources["qualitydefinition"],
            f"Configarr {service} quality definitions",
        )
        items = _configarr_materialized_profile_items(
            _configarr_source_policy(config_source, service), definitions, service
        )
        item_ids = _configarr_profile_item_ids(
            items, f"Configarr {service} materialized quality items"
        )
        cutoff_name = _required_string(
            desired_profile.get("cutoff"), f"Configarr {service} desired cutoff"
        )
        if cutoff_name not in item_ids:
            raise AnsibleFilterError(
                f"Configarr {service} desired cutoff identity is unavailable"
            )

        format_items = []
        desired_assignment = _mapping(
            _mapping(
                desired_profile.get("format_assignment"),
                f"Configarr {service} desired format assignment",
            ).get("value"),
            f"Configarr {service} desired format assignment value",
        )
        target_score = _strict_integer(
            desired_assignment.get("score"),
            f"Configarr {service} desired format score",
        )
        for custom_format in formats:
            identifier = _strict_integer(
                custom_format.get("id"), f"Configarr {service} custom-format id"
            )
            name = custom_format["name"]
            format_items.append(
                {
                    "format": identifier,
                    "name": name,
                    "score": target_score if name == "NAS Repack or Proper" else 0,
                }
            )
        if not any(item["name"] == "NAS Repack or Proper" for item in format_items):
            raise AnsibleFilterError(
                f"Configarr {service} owned custom format is unavailable after creation"
            )

        body.update(
            {
                "upgradeAllowed": desired_profile["upgradeAllowed"],
                "cutoff": item_ids[cutoff_name],
                "minFormatScore": desired_profile["minFormatScore"],
                "cutoffFormatScore": desired_profile["cutoffFormatScore"],
                "minUpgradeFormatScore": desired_profile["minUpgradeFormatScore"],
                "items": items,
                "formatItems": format_items,
            }
        )
        repairs[service] = {"id": profile_id, "body": body}
    return repairs


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
            "acquisition_bazarr_declarations": acquisition_bazarr_declarations,
            "acquisition_bazarr_owned_projections": acquisition_bazarr_owned_projections,
            "acquisition_bazarr_connection_body": acquisition_bazarr_connection_body,
            "acquisition_configarr_owned_projection": acquisition_configarr_owned_projection,
            "acquisition_configarr_quality_definition_invariants": acquisition_configarr_quality_definition_invariants,
            "acquisition_configarr_declared_projection": acquisition_configarr_declared_projection,
            "acquisition_configarr_desired_projection": acquisition_configarr_desired_projection,
            "acquisition_configarr_missing_custom_format_bodies": acquisition_configarr_missing_custom_format_bodies,
            "acquisition_configarr_profile_repair_bodies": acquisition_configarr_profile_repair_bodies,
        }
