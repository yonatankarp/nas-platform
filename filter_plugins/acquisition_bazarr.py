"""Bazarr provider declarations, settings projections and the settings POST.

Bazarr has no JSON settings API. Its whole configuration is one HTML form
POSTed as `settings-<section>-<key>` pairs, and it reads that form back as a
nested JSON document with different types: a boolean is submitted as the string
"true" and returned as a real boolean, an empty list is submitted as `["null"]`.
The three value normalizers below are that asymmetry, named for the direction
each one faces — desired, request, current — and they are why a Bazarr setting
cannot be compared with the same primitives a Servarr field uses.

Provider settings are keyed `settings-<provider>-<setting>` and Bazarr 1.6.0
splits those keys on hyphens, so both halves are held to lowercase identifier
tokens here rather than discovered to be ambiguous at runtime.
"""

from __future__ import annotations

import hashlib
import importlib.util
import re
from copy import deepcopy
from pathlib import Path
from typing import Any

from ansible.errors import AnsibleFilterError


# Filter plugins cannot import module_utils/ by name, and putting the repository
# root on sys.path to reach it would shadow site-packages with library/, roles/,
# services/ and tests/ for the whole Ansible process. Loading the file by path
# shares the primitives with no global side effect. tests/policy_test.rb executes
# every filter plugin and fails if one of them touches sys.path.
_SCHEMA_SPEC = importlib.util.spec_from_file_location(
    "nas_platform_acquisition_schema",
    Path(__file__).resolve().parents[1] / "module_utils" / "acquisition_schema.py",
)
_SCHEMA = importlib.util.module_from_spec(_SCHEMA_SPEC)
_SCHEMA_SPEC.loader.exec_module(_SCHEMA)

# The shared primitives, under the names the bodies below use. Only these are
# shared: every rule about what a Prowlarr field, a Bazarr setting or a Configarr
# profile may contain lives in the file that owns that domain.
MASKED_VALUE = _SCHEMA.MASKED_VALUE
_mapping = _SCHEMA.mapping
_sequence = _SCHEMA.sequence
_strict_boolean = _SCHEMA.strict_boolean
_strict_integer = _SCHEMA.strict_integer
_required_string = _SCHEMA.required_string
_number = _SCHEMA.number
_boolean = _SCHEMA.coerce_boolean
_integer = _SCHEMA.coerce_integer
_safe_setting_value = _SCHEMA.safe_setting_value
_with_native_arguments = _SCHEMA.with_native_arguments


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
    if isinstance(value, bool):
        return str(value).lower()
    if isinstance(value, str) and value.strip().lower() in {"true", "false"}:
        return value.strip().lower()
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
        # Bazarr v1.6.0 splits form keys on hyphens before indexing settings.
        # Provider/input identifiers in the pinned provider registry therefore
        # use lowercase identifier tokens, never additional delimiters:
        # https://github.com/morpheus65535/bazarr/blob/v1.6.0/bazarr/app/config.py#L641
        if not re.fullmatch(r"[a-z][a-z0-9_]*", name):
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
            if not re.fullmatch(r"[a-z][a-z0-9_]*", setting_name):
                raise AnsibleFilterError(
                    f"Bazarr provider {name!r} setting suffixes must use canonical identifiers"
                )
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




def _bazarr_connection_secrets(
    auth: dict[str, Any], radarr: dict[str, Any], sonarr: dict[str, Any]
) -> tuple[list[str], dict[str, str]]:
    """Split the three connection secrets into masked names and readable values.

    Bazarr returns a stored secret as a run of asterisks. That is neither the
    value nor its absence, so a masked setting is reported by name and left out
    of the comparison entirely rather than compared against the mask.
    """
    masked = []
    readable = {}
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
            masked.append(projection_name)
        else:
            readable[projection_name] = value
    return masked, readable


def _bazarr_enabled_provider_state(general: dict[str, Any]) -> list[str]:
    """Project Bazarr's enabled-provider list, refusing an ambiguous one."""
    enabled_providers = []
    for name in _sequence(
        general.get("enabled_providers"), "Bazarr enabled provider state"
    ):
        enabled_providers.append(
            _required_string(name, "Bazarr enabled provider state entry")
        )
    if len(enabled_providers) != len(set(enabled_providers)):
        raise AnsibleFilterError("Bazarr enabled provider state is ambiguous")
    return enabled_providers


def _bazarr_enabled_languages(language_state: Any) -> list[str]:
    """Name the enabled languages in Bazarr's full language table.

    Bazarr reports every language it knows with an `enabled` flag rather than
    reporting the enabled ones, so the whole table is validated for identity and
    only the enabled codes are returned.
    """
    language_codes = []
    current_languages = []
    for entry in _sequence(language_state, "Bazarr language state"):
        entry = _mapping(entry, "Bazarr language state entry")
        code = _required_string(entry.get("code2"), "Bazarr language code")
        if not re.fullmatch(r"[a-z0-9_-]+", code):
            raise AnsibleFilterError("Bazarr language state uses a non-canonical code")
        language_codes.append(code)
        if _strict_boolean(entry.get("enabled"), f"Bazarr language {code!r} enabled"):
            current_languages.append(code)
    if len(language_codes) != len(set(language_codes)):
        raise AnsibleFilterError("Bazarr language state contains duplicate identities")
    return current_languages


def _bazarr_current_connection(
    auth: dict[str, Any],
    general: dict[str, Any],
    radarr: dict[str, Any],
    sonarr: dict[str, Any],
    enabled_providers: list[str],
    declared_names: list[Any],
    current_languages: list[str],
    readable_secrets: dict[str, str],
) -> dict[str, Any]:
    """Project the connection settings this platform owns from live state."""
    return {
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
        "readable_secrets": readable_secrets,
    }


def _bazarr_provider_projections(
    settings: dict[str, Any], declarations: dict[str, Any], declared_names: list[Any]
) -> tuple[dict[str, Any], dict[str, Any], list[str]]:
    """Pair every declared provider's live settings with its declared ones.

    A setting Bazarr masks is reported by name and dropped from both sides. A
    setting Bazarr does not carry yet appears only in the desired projection, and
    a setting this platform does not declare is carried into both sides
    unchanged so it is preserved rather than reported as drift.
    """
    current_projection = {}
    desired_projection = {}
    masked = []
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
                masked.append(f"{provider_name}.{setting_name}")
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
        current_projection[provider_name] = current_readable
        desired_projection[provider_name] = desired_readable
    return current_projection, desired_projection, masked


def acquisition_bazarr_owned_projections(
    settings: Any,
    language_state: Any,
    declarations: Any,
    username: Any,
    password: Any,
    radarr_api_key: Any,
    sonarr_api_key: Any,
) -> dict[str, Any]:
    """Pair the whole owned Bazarr configuration with what it should be.

    The stages below run in this order because each one refuses input the next
    would otherwise have to tolerate, and the first refusal is the message the
    play reports.
    """
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

    desired_connection_settings = {
        "auth.password": hashlib.md5(
            password.encode("utf-8"), usedforsecurity=False
        ).hexdigest(),
        "radarr.apikey": radarr_api_key,
        "sonarr.apikey": sonarr_api_key,
    }
    masked_connection_settings, readable_connection_settings = (
        _bazarr_connection_secrets(auth, radarr, sonarr)
    )
    enabled_providers = _bazarr_enabled_provider_state(general)
    declared_names = _sequence(
        declarations.get("provider_names"), "normalized Bazarr provider names"
    )
    current_languages = _bazarr_enabled_languages(language_state)

    current_connection = _bazarr_current_connection(
        auth,
        general,
        radarr,
        sonarr,
        enabled_providers,
        declared_names,
        current_languages,
        readable_connection_settings,
    )
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

    (
        current_provider_projection,
        desired_provider_projection,
        masked_provider_settings,
    ) = _bazarr_provider_projections(settings, declarations, declared_names)

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


class FilterModule:
    """Expose the Bazarr settings filters to Ansible."""

    def filters(self) -> dict[str, Any]:
        return {
            name: _with_native_arguments(function)
            for name, function in self._relationship_filters().items()
        }

    def _relationship_filters(self) -> dict[str, Any]:
        return {
            "acquisition_bazarr_declarations": acquisition_bazarr_declarations,
            "acquisition_bazarr_owned_projections": acquisition_bazarr_owned_projections,
            "acquisition_bazarr_connection_body": acquisition_bazarr_connection_body,
        }
