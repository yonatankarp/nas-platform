"""Configarr quality profiles, quality definitions and custom formats.

Configarr is a job, not a service: it reads one YAML declaration, writes to the
Radarr and Sonarr APIs and exits. Nothing it writes is readable in the shape it
was declared in, so every filter here exists to make a declaration and a
readback comparable.

That comparison is done in three stages, and the filter names follow them:

* `acquisition_configarr_owned_projection` reduces a strict readback of both
  services to the resources this platform owns.
* `acquisition_configarr_declared_projection` turns that into the form a
  declaration can be compared against — quality names rather than the numeric
  identities Radarr and Sonarr generate, and the sort order those identities
  imply.
* `acquisition_configarr_desired_projection` materializes the declaration the
  same way Configarr v1.28.0 does, including the qualities it adds, the order it
  reverses and the cutoff fields it derives.

Quality definitions are separated out because Configarr owns only three of their
fields; `..._quality_definition_invariants` keeps the rest as opaque context so
Servarr's own metadata is carried rather than invented. `..._profile_repair_bodies`
is the write side: a conservative full PUT built from an immediate readback.
"""

from __future__ import annotations

import importlib.util
import json
import re
from copy import deepcopy
from pathlib import Path
from typing import Any

import yaml
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
_mapping = _SCHEMA.mapping
_sequence = _SCHEMA.sequence
_strict_boolean = _SCHEMA.strict_boolean
_strict_integer = _SCHEMA.strict_integer
_required_string = _SCHEMA.required_string
_number = _SCHEMA.number
_nullable_number = _SCHEMA.nullable_number
_nullable_string = _SCHEMA.nullable_string
_safe_setting_value = _SCHEMA.safe_setting_value
_fields = _SCHEMA.fields
_with_native_arguments = _SCHEMA.with_native_arguments


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


CONFIGARR_PROFILE_TREE_MAX_DEPTH = 16


CONFIGARR_PROFILE_TREE_MAX_NODES = 512


def _configarr_profile_tree(items: Any, label: str) -> dict[str, Any]:
    """Strictly project a complete Servarr profile tree and all node identities."""
    identities = []
    names_by_id: dict[int, str] = {}
    ids_by_name: dict[str, int] = {}
    node_count = 0

    def project(item: Any, path: list[str], depth: int) -> dict[str, Any]:
        nonlocal node_count
        if depth > CONFIGARR_PROFILE_TREE_MAX_DEPTH:
            raise AnsibleFilterError(
                f"{label} exceeds maximum depth {CONFIGARR_PROFILE_TREE_MAX_DEPTH}"
            )
        node_count += 1
        if node_count > CONFIGARR_PROFILE_TREE_MAX_NODES:
            raise AnsibleFilterError(
                f"{label} exceeds maximum node count {CONFIGARR_PROFILE_TREE_MAX_NODES}"
            )

        item = _mapping(item, f"{label} item")
        allowed = _strict_boolean(item.get("allowed"), f"{label} item allowed")
        children = _sequence(item.get("items", []), f"{label} item children")
        quality = item.get("quality")
        if "quality" in item and quality is not None and not isinstance(quality, dict):
            raise AnsibleFilterError(
                f"{label} item quality must be a mapping when present"
            )
        if isinstance(quality, dict):
            kind = "quality"
            name = _required_string(quality.get("name"), f"{label} quality name")
            identifier = _strict_integer(quality.get("id"), f"{label} quality id")
            if children:
                raise AnsibleFilterError(
                    f"{label} quality item {name!r} cannot contain child items"
                )
        else:
            kind = "group"
            name = _required_string(item.get("name"), f"{label} group name")
            identifier = _strict_integer(item.get("id"), f"{label} group id")
            if not children:
                raise AnsibleFilterError(
                    f"{label} quality group {name!r} must contain child items"
                )
        # Radarr and Sonarr number the built-in "Unknown" quality 0 and start
        # generated quality groups at 1000, so a quality may legitimately be 0
        # while a group may not.
        minimum_identifier = 0 if kind == "quality" else 1
        if identifier < minimum_identifier:
            raise AnsibleFilterError(
                f"{label} {kind} {name!r} ID must be "
                f"{'a non-negative' if kind == 'quality' else 'a positive'} integer"
            )
        if identifier in names_by_id:
            raise AnsibleFilterError(f"{label} contains duplicate numeric identities")
        if name in ids_by_name:
            raise AnsibleFilterError(f"{label} contains duplicate named identities")

        names_by_id[identifier] = name
        ids_by_name[name] = identifier
        identity_path = path + [f"{kind}:{name}"]
        identities.append(
            {"path": identity_path, "kind": kind, "name": name, "id": identifier}
        )
        projected = {"kind": kind, "name": name, "allowed": allowed}
        if kind == "group":
            projected["items"] = [
                project(child, identity_path, depth + 1) for child in children
            ]
        return projected

    projected_items = [
        project(item, [], 1) for item in _sequence(items, label)
    ]
    identities.sort(key=lambda item: tuple(item["path"]))
    return {
        "items": projected_items,
        "item_identities": identities,
        "names_by_id": names_by_id,
        "ids_by_name": ids_by_name,
    }


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




OWNED_PROFILE_NAME = "HD Bluray + WEB 1080p"
OWNED_FORMAT_NAME = "NAS Repack or Proper"


def _configarr_owned_profiles(
    resources: dict[str, Any], service: str
) -> list[dict[str, Any]]:
    """Return the at-most-one quality profile this platform owns.

    The whole collection is validated on the way through: a duplicate name or
    numeric identity anywhere makes every later identity claim unsafe, not only
    the owned one.
    """
    profiles = _unique_named(resources["qualityprofile"], f"Configarr {service} profiles")
    if not profiles:
        raise AnsibleFilterError(f"Configarr {service} profiles are empty")
    _validate_unique_numeric_identities(profiles, f"Configarr {service} profiles")
    matches = [item for item in profiles if item["name"] == OWNED_PROFILE_NAME]
    if len(matches) > 1:
        raise AnsibleFilterError(f"Configarr {service} owned profile identity is ambiguous")
    return matches


def _configarr_owned_quality_definitions(
    resources: dict[str, Any], service: str
) -> list[dict[str, Any]]:
    """Project every quality definition, refusing an ambiguous identity."""
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
    return definitions


def _configarr_owned_custom_formats(
    resources: dict[str, Any], service: str
) -> list[dict[str, Any]]:
    """Return the at-most-one custom format this platform owns."""
    formats = _unique_named(
        resources["customformat"], f"Configarr {service} custom formats"
    )
    _validate_unique_numeric_identities(formats, f"Configarr {service} custom formats")
    matches = [item for item in formats if item["name"] == OWNED_FORMAT_NAME]
    if len(matches) > 1:
        raise AnsibleFilterError(
            f"Configarr {service} owned custom format identity is ambiguous"
        )
    return matches


def _configarr_owned_profile_projection(
    profile: dict[str, Any], service: str
) -> dict[str, Any]:
    """Reduce one live quality profile to the fields this platform owns.

    The cutoff is stored as a numeric identity Radarr and Sonarr generate, so it
    is resolved to the quality name it points at: the identity is not stable
    across a profile rebuild and the name is what a declaration states.
    """
    raw_items = _sequence(profile.get("items"), f"Configarr {service} quality items")
    quality_tree = _configarr_profile_tree(
        raw_items, f"Configarr {service} quality items"
    )
    quality_identities = quality_tree["names_by_id"]
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
    score_matches = [item for item in format_items if item["name"] == OWNED_FORMAT_NAME]
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
    return {
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
        "items": quality_tree["items"],
        "item_identities": quality_tree["item_identities"],
        "format_assignment_identity_count": len(score_matches),
        "format_assignments": format_assignments,
    }


def _configarr_owned_custom_format_projection(
    custom_format: dict[str, Any], service: str
) -> dict[str, Any]:
    """Reduce one live custom format to its name, rename flag and specifications."""
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
    return {
        "name": custom_format["name"],
        "includeCustomFormatWhenRenaming": _strict_boolean(
            custom_format.get("includeCustomFormatWhenRenaming"),
            f"Configarr {service} includeCustomFormatWhenRenaming",
        ),
        "specifications": specifications,
    }


def _configarr_owned_naming(resources: dict[str, Any], service: str) -> dict[str, Any]:
    """Project the naming fields this platform declares for one service."""
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
    return normalized_naming


def acquisition_configarr_owned_projection(results: Any) -> dict[str, Any]:
    """Reduce a strict readback of both services to the resources this platform owns.

    The stages run in this order for both services, and each refuses input the
    next would otherwise have to tolerate: whichever refusal comes first is the
    message the play reports.
    """
    resources_by_service = _configarr_result_resources(results)
    projection = {}
    for service in ["radarr", "sonarr"]:
        resources = resources_by_service[service]
        profile_matches = _configarr_owned_profiles(resources, service)
        definitions = _configarr_owned_quality_definitions(resources, service)
        format_matches = _configarr_owned_custom_formats(resources, service)

        profile_projection = (
            _configarr_owned_profile_projection(profile_matches[0], service)
            if profile_matches
            else None
        )
        custom_format_projection = (
            _configarr_owned_custom_format_projection(format_matches[0], service)
            if format_matches
            else None
        )
        normalized_naming = _configarr_owned_naming(resources, service)

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


def acquisition_configarr_quality_definition_difference(invariants: Any) -> dict[str, Any]:
    """Name the quality definitions whose live values differ from their source.

    The convergence assert carries no_log because the surrounding tasks handle
    API keys, so a mismatch reported only that something differed. Quality names
    and TRaSH sizes are public guide data and carry no credential, so naming the
    exact entries is what makes a red run diagnosable.
    """
    invariants = _mapping(invariants, "Configarr quality-definition invariants")
    current = _mapping(
        invariants.get("source_current"), "Configarr current quality definitions"
    )
    desired = _mapping(
        invariants.get("source_desired"), "Configarr desired quality definitions"
    )
    difference: dict[str, Any] = {}
    for service in sorted(set(current) | set(desired)):
        current_by_name = {
            _required_string(item.get("quality"), "Configarr current quality name"): item
            for item in _sequence(
                current.get(service, []), f"Configarr {service} current definitions"
            )
        }
        desired_by_name = {
            _required_string(item.get("quality"), "Configarr desired quality name"): item
            for item in _sequence(
                desired.get(service, []), f"Configarr {service} desired definitions"
            )
        }
        entries = [
            {
                "quality": name,
                "current": current_by_name.get(name),
                "desired": desired_by_name.get(name),
            }
            for name in sorted(set(current_by_name) | set(desired_by_name))
            if current_by_name.get(name) != desired_by_name.get(name)
        ]
        if entries:
            difference[service] = entries
    return difference


def acquisition_configarr_quality_definitions_settled(
    definitions: Any, source: Any, service: Any
) -> bool:
    """Report whether a service's quality definitions carry their declared sizes.

    Radarr and Sonarr apply a quality-definition update asynchronously: the API
    accepts it, Configarr exits, and a read issued immediately afterwards still
    returns the previous sizes for a few seconds. Reading once after the job
    therefore captures whatever happened to be committed, so the role waits on
    this instead.
    """
    service = _required_string(service, "Configarr quality-definition service")
    expected = _configarr_quality_definition_source(source, service)
    for definition in _sequence(definitions, "Configarr quality definitions"):
        definition = _mapping(definition, "Configarr quality definition")
        quality = _mapping(definition.get("quality"), "Configarr quality identity")
        name = _required_string(quality.get("name"), "Configarr quality name")
        declared = expected.get(name)
        if declared is None:
            continue
        for live_key, declared_key in (
            ("minSize", "minSize"),
            ("preferredSize", "preferredSize"),
            ("maxSize", "maxSize"),
        ):
            if definition.get(live_key) != declared.get(declared_key):
                return False
    return True


def _configarr_service_invariants(
    service_projection: dict[str, Any], expected_by_name: dict[str, Any], service: str
) -> tuple[list[dict[str, Any]], list[dict[str, Any]], list[dict[str, Any]]]:
    """Split one service's projected definitions into current, desired and context.

    A definition the source document names is comparable: its three sizes (and
    its title, when the source states one) become a current/desired pair. A
    definition the source does not name has no desired value at all, so its
    sizes join the opaque context rather than being invented.
    """
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
        sizes = {
            key: _nullable_number(
                definition.get(key), f"Configarr {service} projected {name!r} {key}"
            )
            for key in ("minSize", "preferredSize", "maxSize")
        }
        expected = expected_by_name.get(name)
        if expected is None:
            opaque.update(sizes)
        else:
            current = {"quality": name, **sizes}
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
    return current_items, desired_items, opaque_items


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
        (
            source_current[service],
            source_desired[service],
            opaque_context[service],
        ) = _configarr_service_invariants(service_projection, expected_by_name, service)

    return {
        "source_current": source_current,
        "source_desired": source_desired,
        "opaque_context": opaque_context,
    }


def acquisition_configarr_declared_projection(projection: Any) -> dict[str, Any]:
    projection = _mapping(projection, "Configarr owned projection")
    declared = {}
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
                == OWNED_FORMAT_NAME
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
                item.get("name") == OWNED_FORMAT_NAME
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
                "item_identities": deepcopy(profile.get("item_identities")),
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


def _configarr_parsed_yaml(config_source: str) -> dict[str, Any]:
    """Load the declaration with its `!secret` tags replaced by a placeholder.

    The document is Configarr's, and PyYAML has no constructor for Configarr's
    `!secret` tag. The tag always names a credential this platform already owns,
    so substituting one opaque string keeps the parse total without ever putting
    a credential in a value a filter could return.
    """
    sanitized = re.sub(r"!secret\s+[A-Z_]+", '"opaque-secret"', config_source)
    try:
        config = yaml.safe_load(sanitized)
    except yaml.YAMLError as error:
        raise AnsibleFilterError("Configarr configuration cannot be parsed") from error
    return _mapping(config, "Configarr configuration")


def _configarr_declaration(config_source: Any) -> dict[str, Any]:
    """Parse the whole Configarr declaration from its source text."""
    if not isinstance(config_source, str) or not config_source:
        raise AnsibleFilterError("Configarr configuration source must be a non-empty string")
    if "\x00" in config_source:
        raise AnsibleFilterError("Configarr configuration source contains a NUL byte")
    return _configarr_parsed_yaml(config_source)


def _configarr_service_policy(config: dict[str, Any], service: str) -> dict[str, Any]:
    """Return the single declared instance policy for one service."""
    service_config = _mapping(config.get(service), f"Configarr {service} configuration")
    if len(service_config) != 1:
        raise AnsibleFilterError(f"Configarr {service} instance identity is ambiguous")
    return _mapping(next(iter(service_config.values())), f"Configarr {service} policy")


def _configarr_declared_custom_format(
    config: dict[str, Any],
) -> tuple[dict[str, Any], str, list[dict[str, Any]]]:
    """Project the one custom-format definition this platform declares.

    Returns the declaration itself, the TRaSH id the per-service score
    assignments refer to it by, and its specifications in the same sorted form
    the readback projection produces, so the two are directly comparable.
    """
    definitions = _sequence(
        config.get("customFormatDefinitions"), "Configarr custom-format definitions"
    )
    matching_definitions = [
        _mapping(item, "Configarr custom-format definition")
        for item in definitions
        if isinstance(item, dict) and item.get("name") == OWNED_FORMAT_NAME
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
    return format_definition, trash_id, specifications


def _configarr_declared_quality_items(
    profile: dict[str, Any], service: str
) -> tuple[list[dict[str, Any]], list[str]]:
    """Project the declared qualities, in declaration order, with their names.

    A group contributes its children rather than itself to the name list,
    because a group is a container Configarr generates while a quality is what a
    definition is keyed by. Children are reversed for the reason Configarr
    reverses them: the API orders a profile worst-first.
    """
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
    return configured_quality_items, configured_quality_names


def _configarr_declared_format_score(
    policy: dict[str, Any], trash_id: str, service: str
) -> int:
    """Return the score the declaration gives the owned format in the owned profile."""
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
    score_matches = [item for item in scores if item["name"] == OWNED_PROFILE_NAME]
    if len(score_matches) != 1:
        raise AnsibleFilterError(
            f"Configarr {service} owned format-score declaration is ambiguous"
        )
    return _strict_integer(score_matches[0].get("score"), "Configarr owned format score")


def _configarr_desired_naming(policy: dict[str, Any], service: str) -> dict[str, Any]:
    """Project the naming formats one service's policy declares."""
    # Literal Servarr naming formats use Configarr's raw API escape hatch.
    # `media_naming` is reserved for TRaSH preset keys in pinned v1.28.0:
    # https://github.com/raydak-labs/configarr/blob/v1.28.0/src/config.ts#L1086-L1162
    naming = _mapping(
        policy.get("media_naming_api"), f"Configarr {service} naming API policy"
    )
    if service == "radarr":
        return {
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
    return {
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


def acquisition_configarr_desired_projection(
    config_source: Any, current_projection: Any
) -> dict[str, Any]:
    """Materialize the declaration into the shape a readback is comparable in.

    Configarr v1.28.0 materializes every quality, reverses configured API order,
    resets unmatched scores, and derives disabled-upgrade cutoff fields:
    https://github.com/raydak-labs/configarr/blob/v1.28.0/src/quality-profiles.ts

    The current projection is an argument because two of those derivations are
    not knowable from the declaration alone: which qualities exist to be left
    disabled, and which numeric identity the owned custom format was created
    with.
    """
    config = _configarr_declaration(config_source)
    current_projection = _mapping(
        current_projection, "Configarr current owned projection"
    )
    format_definition, trash_id, specifications = _configarr_declared_custom_format(config)

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
        policy = _configarr_service_policy(config, service)
        materialized_items = _configarr_materialized_profile_items(
            policy,
            _sequence(
                current_service.get("quality_definitions"),
                f"Configarr {service} current quality definitions",
            ),
            service,
        )
        materialized_tree = _configarr_profile_tree(
            materialized_items,
            f"Configarr {service} materialized quality items",
        )
        profile = _configarr_declared_profile(policy, service)
        configured_quality_items, configured_quality_names = (
            _configarr_declared_quality_items(profile, service)
        )
        disabled_quality_names = sorted(
            set(definition_names).difference(configured_quality_names)
        )
        enabled_quality_items = list(reversed(configured_quality_items))
        format_score = _configarr_declared_format_score(policy, trash_id, service)
        desired_naming = _configarr_desired_naming(policy, service)

        desired[service] = {
            "quality_profile_identity_count": 1,
            "quality_profile": {
                "name": OWNED_PROFILE_NAME,
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
                "item_identities": materialized_tree["item_identities"],
                "format_assignment": {
                    "identity_count": 1,
                    "value": {
                        "format": current_service.get("custom_format_id"),
                        "name": OWNED_FORMAT_NAME,
                        "score": format_score,
                    },
                },
            },
            "custom_format_identity_count": 1,
            "custom_format": {
                "name": OWNED_FORMAT_NAME,
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
    desired_projection: Any, current_projection: Any
) -> dict[str, dict[str, Any]]:
    """Return exact create bodies only for globally preflighted missing targets.

    The desired projection is taken already materialized rather than parsed
    again from the declaration source: the play materializes it once before it
    mutates anything, and materializing it a second time from the same two
    inputs re-ran the whole of `acquisition_configarr_desired_projection` for a
    result that cannot differ. Do not re-add the source parse for convenience —
    pass the fact the play already holds.
    """
    desired = _mapping(desired_projection, "Configarr desired owned projection")
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
    """Parse one service's policy straight out of the declaration source.

    The repair path needs only the policy, not the whole desired projection,
    which is why this exists beside `_configarr_declaration`. It keeps its own
    non-empty message: this is the argument a repair task passes, and the two
    call sites are told apart by which message a red run reports.
    """
    if not isinstance(config_source, str) or not config_source:
        raise AnsibleFilterError("Configarr configuration source must be non-empty")
    return _configarr_service_policy(_configarr_parsed_yaml(config_source), service)


def _configarr_declared_profile(policy: dict[str, Any], service: str) -> dict[str, Any]:
    """Return the one declared quality profile this platform owns."""
    profiles = _unique_named(
        policy.get("quality_profiles"), f"Configarr {service} declared profiles"
    )
    matches = [item for item in profiles if item["name"] == OWNED_PROFILE_NAME]
    if len(matches) != 1:
        raise AnsibleFilterError(
            f"Configarr {service} owned profile declaration is ambiguous"
        )
    return matches[0]


def _configarr_definition_lookup(
    definitions: list[dict[str, Any]], service: str
) -> tuple[dict[str, dict[str, Any]], dict[str, dict[str, Any]]]:
    """Index the live quality definitions by every name a declaration may use.

    Returns the canonical quality identities keyed by quality name, and a lookup
    that also resolves a definition's *title*, because Configarr accepts either
    spelling in a profile declaration and Radarr's titles differ from its
    quality names for several entries.
    """
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
    return definitions_by_name, lookup


def _configarr_selected_quality(
    lookup: dict[str, dict[str, Any]], name: str, service: str
) -> tuple[str, dict[str, Any]]:
    """Resolve one declared quality name to its canonical name and identity."""
    definition = lookup.get(name)
    if definition is None:
        raise AnsibleFilterError(
            f"Configarr {service} declared quality {name!r} is unavailable"
        )
    canonical_name = _required_string(
        _mapping(definition.get("quality"), "Configarr quality").get("name"),
        "Configarr canonical quality name",
    )
    return canonical_name, definition["quality"]


def _configarr_materialized_profile_items(
    policy: dict[str, Any], definitions: list[dict[str, Any]], service: str
) -> list[dict[str, Any]]:
    """Build the profile item tree Configarr v1.28.0 would write.

    Every quality the service knows appears: the declared ones in reversed
    declaration order, and every remaining one disabled. `quality_sort` decides
    which of the two blocks comes first, and generated group identities start at
    1000 exactly as Radarr and Sonarr number them.
    """
    profile = _configarr_declared_profile(policy, service)
    definitions_by_name, lookup = _configarr_definition_lookup(definitions, service)

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
                canonical_name, quality = _configarr_selected_quality(
                    lookup, child_name, service
                )
                selected_names.add(canonical_name)
                children.append(
                    {"quality": deepcopy(quality), "allowed": allowed, "items": []}
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
            canonical_name, quality = _configarr_selected_quality(lookup, name, service)
            selected_names.add(canonical_name)
            allowed_items.append(
                {"quality": deepcopy(quality), "allowed": allowed, "items": []}
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
    return _configarr_profile_tree(items, label)["ids_by_name"]


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
            item for item in profiles if item["name"] == OWNED_PROFILE_NAME
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
                    "score": target_score if name == OWNED_FORMAT_NAME else 0,
                }
            )
        if not any(item["name"] == OWNED_FORMAT_NAME for item in format_items):
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
    """Expose the Configarr materialization filters to Ansible."""

    def filters(self) -> dict[str, Any]:
        return {
            name: _with_native_arguments(function)
            for name, function in self._relationship_filters().items()
        }

    def _relationship_filters(self) -> dict[str, Any]:
        return {
            "acquisition_configarr_owned_projection":
                acquisition_configarr_owned_projection,
            "acquisition_configarr_quality_definition_difference":
                acquisition_configarr_quality_definition_difference,
            "acquisition_configarr_quality_definitions_settled":
                acquisition_configarr_quality_definitions_settled,
            "acquisition_configarr_quality_definition_invariants":
                acquisition_configarr_quality_definition_invariants,
            "acquisition_configarr_declared_projection":
                acquisition_configarr_declared_projection,
            "acquisition_configarr_desired_projection":
                acquisition_configarr_desired_projection,
            "acquisition_configarr_missing_custom_format_bodies":
                acquisition_configarr_missing_custom_format_bodies,
            "acquisition_configarr_profile_repair_bodies":
                acquisition_configarr_profile_repair_bodies,
        }
