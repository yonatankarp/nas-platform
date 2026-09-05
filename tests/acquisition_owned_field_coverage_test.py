#!/usr/bin/env python3
"""Every owned field must be visible in its relationship's projection.

Drift is detected by comparing projections, so a field that the projection
drops is a field whose drift is silently accepted. The reconciliation fixture
proves this per field with a full Ansible round-trip, which costs seconds each
and proves the same pure property every time: mutate one owned field and the
projection must change. That property is checked here directly against the real
filters, so the fixture only has to keep one round-trip per behavioural class.
"""

from __future__ import annotations

import copy
import importlib.util
import pathlib
import sys

from ansible.errors import AnsibleFilterError

ROOT = pathlib.Path(__file__).resolve().parents[1]
PLUGIN = ROOT / "filter_plugins" / "acquisition_servarr.py"


def load_plugin():
    spec = importlib.util.spec_from_file_location("acquisition_servarr", PLUGIN)
    if spec is None or spec.loader is None:
        raise AssertionError("the Servarr relationship filters cannot be imported")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


plugin = load_plugin()


def field(body, name, value):
    body = copy.deepcopy(body)
    for entry in body["fields"]:
        if entry["name"] == name:
            entry["value"] = value
            return body
    raise AssertionError(f"canonical body has no field {name!r}")


def top(body, name, value):
    body = copy.deepcopy(body)
    if name not in body:
        raise AssertionError(f"canonical body has no key {name!r}")
    body[name] = value
    return body


APPLICATION = {
    "id": 11, "name": "Radarr", "enable": True, "syncLevel": "fullSync",
    "implementation": "Radarr", "implementationName": "Radarr",
    "configContract": "RadarrSettings", "tags": [3, 9],
    "fields": [
        {"name": "prowlarrUrl", "value": "http://prowlarr:9696"},
        {"name": "baseUrl", "value": "http://radarr:7878"},
        {"name": "username", "value": ""},
        {"name": "password", "value": ""},
        {"name": "apiKey", "value": "fixture-application-key"},
        {"name": "syncCategories", "value": [2000, 2020]},
    ],
}

DOWNLOAD_CLIENT = {
    "id": 21, "name": "SABnzbd", "enable": True, "protocol": "usenet",
    "priority": 1, "removeCompletedDownloads": True, "removeFailedDownloads": True,
    "implementation": "Sabnzbd", "implementationName": "SABnzbd",
    "configContract": "SabnzbdSettings", "tags": [1, 5],
    "fields": [
        {"name": "host", "value": "sabnzbd"},
        {"name": "port", "value": 8080},
        {"name": "useSsl", "value": False},
        {"name": "urlBase", "value": ""},
        {"name": "apiKey", "value": "fixture-sab-key"},
        {"name": "username", "value": "fixture-sab-user"},
        {"name": "password", "value": "fixture-sab-password"},
        {"name": "movieCategory", "value": "movies"},
    ],
}

PROWLARR_CLIENT = {
    "id": 41, "name": "SABnzbd", "enable": True, "protocol": "usenet",
    "priority": 1, "implementation": "Sabnzbd", "implementationName": "SABnzbd",
    "configContract": "SabnzbdSettings", "tags": [2, 6],
    "fields": [
        {"name": "host", "value": "sabnzbd"},
        {"name": "port", "value": 8080},
        {"name": "useSsl", "value": False},
        {"name": "urlBase", "value": ""},
        {"name": "apiKey", "value": "fixture-sab-key"},
        {"name": "username", "value": "fixture-sab-user"},
        {"name": "password", "value": "fixture-sab-password"},
        {"name": "category", "value": "movies"},
    ],
}

INDEXER = {
    "id": 31, "name": "Fixture Indexer", "enable": True, "priority": 17,
    "appProfileId": 1, "redirect": True,
    "implementation": "Newznab", "implementationName": "Newznab",
    "configContract": "NewznabSettings", "tags": [3, 9],
    "fields": [
        {"name": "baseUrl", "value": "https://indexer.example"},
        {"name": "apiPath", "value": "/api"},
        {"name": "apiKey", "value": "fixture-indexer-key"},
        {"name": "categories", "value": [2000, 2010]},
        {"name": "minimumSeeders", "value": 2},
    ],
}

CASES = [
    (
        "Prowlarr application",
        lambda body: plugin.acquisition_application_projection(body),
        APPLICATION,
        [
            ("name", lambda b: top(b, "name", "Legacy Radarr")),
            ("enable", lambda b: top(b, "enable", False)),
            ("syncLevel", lambda b: top(b, "syncLevel", "addOnly")),
            ("implementation", lambda b: top(b, "implementation", "Legacy")),
            ("implementationName", lambda b: top(b, "implementationName", "Legacy")),
            ("configContract", lambda b: top(b, "configContract", "LegacySettings")),
            ("tags", lambda b: top(b, "tags", [44])),
            ("fields.prowlarrUrl", lambda b: field(b, "prowlarrUrl", "http://legacy:9696")),
            ("fields.baseUrl", lambda b: field(b, "baseUrl", "http://legacy:7878")),
            ("fields.username", lambda b: field(b, "username", "legacy-user")),
            ("fields.password", lambda b: field(b, "password", "legacy-secret")),
            ("fields.syncCategories", lambda b: field(b, "syncCategories", [1])),
        ],
    ),
    (
        "Servarr download client",
        lambda body: plugin.acquisition_servarr_client_projection(body),
        DOWNLOAD_CLIENT,
        [
            ("name", lambda b: top(b, "name", "Legacy SABnzbd")),
            ("enable", lambda b: top(b, "enable", False)),
            ("protocol", lambda b: top(b, "protocol", "torrent")),
            ("priority", lambda b: top(b, "priority", 9)),
            ("removeCompletedDownloads", lambda b: top(b, "removeCompletedDownloads", False)),
            ("removeFailedDownloads", lambda b: top(b, "removeFailedDownloads", False)),
            ("implementation", lambda b: top(b, "implementation", "Legacy")),
            ("implementationName", lambda b: top(b, "implementationName", "Legacy")),
            ("configContract", lambda b: top(b, "configContract", "LegacySettings")),
            ("tags", lambda b: top(b, "tags", [44])),
            ("fields.host", lambda b: field(b, "host", "legacy-host")),
            ("fields.port", lambda b: field(b, "port", 9999)),
            ("fields.useSsl", lambda b: field(b, "useSsl", True)),
            ("fields.urlBase", lambda b: field(b, "urlBase", "/legacy")),
            ("fields.movieCategory", lambda b: field(b, "movieCategory", "legacy")),
        ],
    ),
    (
        "Prowlarr download client",
        lambda body: plugin.acquisition_prowlarr_client_projection(body),
        PROWLARR_CLIENT,
        [
            ("name", lambda b: top(b, "name", "Legacy SABnzbd")),
            ("enable", lambda b: top(b, "enable", False)),
            ("protocol", lambda b: top(b, "protocol", "torrent")),
            ("priority", lambda b: top(b, "priority", 9)),
            ("implementation", lambda b: top(b, "implementation", "Legacy")),
            ("implementationName", lambda b: top(b, "implementationName", "Legacy")),
            ("configContract", lambda b: top(b, "configContract", "LegacySettings")),
            ("tags", lambda b: top(b, "tags", [44])),
            ("fields.host", lambda b: field(b, "host", "legacy-host")),
            ("fields.port", lambda b: field(b, "port", 9999)),
            ("fields.useSsl", lambda b: field(b, "useSsl", True)),
            ("fields.urlBase", lambda b: field(b, "urlBase", "/legacy")),
            ("fields.category", lambda b: field(b, "category", "legacy")),
        ],
    ),
    (
        "Prowlarr indexer",
        lambda body: plugin.acquisition_indexer_projection(body, INDEXER),
        INDEXER,
        [
            ("name", lambda b: top(b, "name", "Legacy Indexer")),
            ("enable", lambda b: top(b, "enable", False)),
            ("priority", lambda b: top(b, "priority", 44)),
            ("appProfileId", lambda b: top(b, "appProfileId", 44)),
            ("redirect", lambda b: top(b, "redirect", False)),
            ("implementation", lambda b: top(b, "implementation", "Legacy")),
            ("implementationName", lambda b: top(b, "implementationName", "Legacy")),
            ("configContract", lambda b: top(b, "configContract", "LegacySettings")),
            ("tags", lambda b: top(b, "tags", [44])),
            ("fields.baseUrl", lambda b: field(b, "baseUrl", "https://legacy.example")),
            ("fields.apiPath", lambda b: field(b, "apiPath", "/legacy")),
            ("fields.categories", lambda b: field(b, "categories", [9999])),
            ("fields.minimumSeeders", lambda b: field(b, "minimumSeeders", 99)),
        ],
    ),
]

# A hand-written mutation list goes stale the moment a relationship gains an
# attribute, and it goes stale silently: the new attribute is simply never
# mutated. Adding `appProfileId` and `redirect` to `_INDEXER` turned this file
# red only because the canonical body then failed to project at all, and the
# complaint named a coercer rather than the missing keys. Pin every attribute of
# every spec to a mutation of the same name so the next added attribute says so.
SPECS = {
    "Prowlarr application": plugin._APPLICATION,
    "Servarr download client": plugin._SERVARR_CLIENT,
    "Prowlarr download client": plugin._PROWLARR_CLIENT,
    "Prowlarr indexer": plugin._INDEXER,
}
ATTRIBUTE_FLOOR = 20

failures = []
checked = 0
attributes_pinned = 0
for relationship, _project, body, mutations in CASES:
    spec = SPECS[relationship]
    mutated_names = {label for label, _ in mutations}
    for name, _coerce in spec.attributes:
        attributes_pinned += 1
        if name not in mutated_names:
            failures.append(
                f"{relationship} owns attribute {name!r}, which no mutation covers, "
                "so this file cannot prove its drift is detected"
            )
        if name not in body:
            failures.append(
                f"{relationship} owns attribute {name!r}, which the canonical body "
                "omits, so the projection cannot read it"
            )
if attributes_pinned < ATTRIBUTE_FLOOR:
    failures.append(
        f"only {attributes_pinned} owned attributes were pinned to a mutation, "
        f"fewer than the {ATTRIBUTE_FLOOR} these relationships declare; the spec "
        "lookup has gone quiet rather than the attributes having disappeared"
    )

for relationship, project, body, mutations in CASES:
    try:
        baseline = project(body)
    except AnsibleFilterError as error:  # pragma: no cover - fixture defect
        failures.append(f"{relationship}: canonical body is not projectable: {error}")
        continue
    for label, mutate in mutations:
        checked += 1
        try:
            mutated = project(mutate(body))
        except AnsibleFilterError as error:
            failures.append(f"{relationship} {label}: mutated body is not projectable: {error}")
            continue
        if mutated == baseline:
            failures.append(
                f"{relationship} owned field {label} is absent from the projection, "
                "so drift in it would never be detected"
            )

if failures:
    for line in failures:
        print(f"FAIL {line}", file=sys.stderr)
    raise SystemExit(f"{len(failures)} owned-field coverage violation(s)")
print(f"acquisition owned fields: all {checked} owned fields reach their projection")
