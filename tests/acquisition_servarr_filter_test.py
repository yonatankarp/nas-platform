#!/usr/bin/env python3
"""Behaviour of the Prowlarr and Servarr relationship filters.

Eight of these eleven filters were reachable only by spawning
`ansible-playbook`: `tests/acquisition_owned_field_coverage_test.py` calls the
three projections, and the bodies, the masking passes, the URL match and the
field merge were exercised only as a side effect of a reconciliation fixture
run. They are pure functions over plain containers, so their contracts are
stated here directly and the fixture keeps only the properties that need a real
play.

Each case names what it protects. The bodies are what this platform writes, so
their shape is the contract with Radarr, Sonarr and Prowlarr; the masking passes
decide which fields are compared at all, so a mask that stopped being detected
would make a stored secret look like permanent drift; and the field merge is
what preserves everything this platform does not own.
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

APPLICATION_DECLARATION = {
    "name": "Radarr",
    "implementation": "Radarr",
    "config_contract": "RadarrSettings",
    "base_url": "http://radarr:7878",
    "api_key": "fixture-radarr-api-secret",
    "sync_categories": [2020, 2000, 2010],
    "tags": [9, 3],
}

RADARR_INSTANCE = {"name": "radarr", "category": "movies", "tags": [5, 1]}
SONARR_INSTANCE = {"name": "sonarr", "category": "series", "tags": []}

INDEXER_DECLARATION = {
    "name": "Fixture Indexer",
    "implementation": "Newznab",
    "config_contract": "NewznabSettings",
    "fields": [
        {"name": "baseUrl", "value": "https://indexer.example"},
        {"name": "apiKey", "value": "fixture-indexer-key"},
        {"name": "categories", "value": [2010, 2000]},
    ],
}


def masked(fields, *names):
    """Return API fields with the named ones replaced by Servarr's asterisks."""
    return [
        {"name": entry["name"], "value": "****" if entry["name"] in names else entry["value"]}
        for entry in fields
    ]


def field_value(body, name):
    for entry in body["fields"]:
        if entry["name"] == name:
            return entry["value"]
    raise AssertionError(f"body has no field {name!r}")


def check(failures, condition, message):
    if not condition:
        failures.append(message)


def refuses(failures, call, message):
    try:
        call()
    except AnsibleFilterError:
        return
    failures.append(message)


def refuses_with(failures, call, expected, message):
    """Assert both that a call is refused and how it words the refusal.

    The three projections are one function driven by a per-relationship
    descriptor, so the wording is what proves a descriptor is wired to the
    relationship it names. An operator reads these strings out of a failed play.
    """
    try:
        call()
    except AnsibleFilterError as error:
        if str(error) != expected:
            failures.append(f"{message} (said {str(error)!r})")
        return
    failures.append(message)


def collect_failures():
    failures = []

    # --- acquisition_application_body -------------------------------------
    body = plugin.acquisition_application_body(
        APPLICATION_DECLARATION, "http://prowlarr:9696", "fullSync"
    )
    check(failures, body["enable"] is True,
          "a Prowlarr application body must enable the application it declares")
    check(failures, body["syncLevel"] == "fullSync",
          "the application body must carry the sync level it was given")
    check(failures, body["implementationName"] == "Radarr",
          "implementationName must default to the implementation")
    check(failures, body["tags"] == [3, 9],
          "application tags must be sorted, so tag order is not drift")
    check(failures, field_value(body, "syncCategories") == [2000, 2010, 2020],
          "sync categories must be sorted, so declaration order is not drift")
    check(failures, field_value(body, "username") == ""
          and field_value(body, "password") == "",
          "the application body must clear the credentials Prowlarr does not use")
    check(failures, field_value(body, "prowlarrUrl") == "http://prowlarr:9696",
          "the application body must carry the Prowlarr URL it was given")
    named = plugin.acquisition_application_body(
        dict(APPLICATION_DECLARATION, implementation_name="Legacy"),
        "http://prowlarr:9696", "fullSync",
    )
    check(failures, named["implementationName"] == "Legacy",
          "a declared implementation name must override the implementation")
    refuses(failures,
            lambda: plugin.acquisition_application_body("radarr", "u", "fullSync"),
            "a non-mapping application declaration must be refused")

    # --- acquisition_application_masked_fields ----------------------------
    readable = plugin.acquisition_application_body(
        APPLICATION_DECLARATION, "http://prowlarr:9696", "fullSync"
    )
    check(failures, plugin.acquisition_application_masked_fields(readable) == [],
          "a readable application must report no masked fields")
    hidden = copy.deepcopy(readable)
    hidden["fields"] = masked(hidden["fields"], "apiKey")
    check(failures, plugin.acquisition_application_masked_fields(hidden) == ["apiKey"],
          "an asterisked application API key must be reported as masked")
    check(failures,
          "apiKey" not in plugin.acquisition_application_projection(hidden)["fields"],
          "a masked API key must be left out of the projection, not compared")

    # --- acquisition_servarr_client_body ----------------------------------
    client = plugin.acquisition_servarr_client_body(
        RADARR_INSTANCE, "SABnzbd", "sabnzbd", "8080",
        "api-secret", "sab-user", "sab-secret",
    )
    check(failures, client["implementation"] == "Sabnzbd"
          and client["configContract"] == "SabnzbdSettings",
          "the download-client body must declare the SABnzbd implementation")
    check(failures, field_value(client, "port") == 8080,
          "a port given as a canonical string must become an integer")
    check(failures, field_value(client, "movieCategory") == "movies",
          "Radarr's category field must be movieCategory")
    check(failures, "tvCategory" not in [entry["name"] for entry in client["fields"]],
          "Radarr's body must not also carry a tvCategory field")
    series = plugin.acquisition_servarr_client_body(
        SONARR_INSTANCE, "SABnzbd", "sabnzbd", 8080, "k", "u", "p"
    )
    check(failures, field_value(series, "tvCategory") == "series",
          "Sonarr's category field must be tvCategory")
    check(failures, client["removeCompletedDownloads"] is True
          and client["removeFailedDownloads"] is True,
          "the download client must remove completed and failed downloads")
    refuses(failures,
            lambda: plugin.acquisition_servarr_client_body(
                RADARR_INSTANCE, "SABnzbd", "sabnzbd", "8080a", "k", "u", "p"),
            "a port that is not a canonical integer must be refused")

    # --- acquisition_servarr_client_masked_fields -------------------------
    check(failures, plugin.acquisition_servarr_client_masked_fields(client) == [],
          "a readable download client must report no masked fields")
    hidden_client = copy.deepcopy(client)
    hidden_client["fields"] = masked(
        hidden_client["fields"], "apiKey", "username", "password"
    )
    check(failures,
          plugin.acquisition_servarr_client_masked_fields(hidden_client)
          == ["apiKey", "username", "password"],
          "all three asterisked client secrets must be reported as masked")
    projection = plugin.acquisition_servarr_client_projection(hidden_client)
    check(failures,
          not {"apiKey", "username", "password"} & set(projection["fields"]),
          "masked client secrets must be left out of the projection")

    # --- acquisition_servarr_client_url_matches ---------------------------
    other = copy.deepcopy(client)
    other["fields"] = [
        entry if entry["name"] != "host" else {"name": "host", "value": "elsewhere"}
        for entry in other["fields"]
    ]
    without_host = {"name": "Torrent", "fields": [{"name": "port", "value": 8080}]}
    matches = plugin.acquisition_servarr_client_url_matches(
        [client, other, without_host], "sabnzbd", 8080
    )
    check(failures, matches == [client],
          "only the client at the declared host and port may be claimed")
    check(failures,
          plugin.acquisition_servarr_client_url_matches([client], "sabnzbd", "8080")
          == [client],
          "a port given as a canonical string must match the same client")
    check(failures, plugin.acquisition_servarr_client_url_matches(None, "h", 1) == [],
          "an absent download-client collection must match nothing")

    # --- acquisition_indexer_body -----------------------------------------
    indexer = plugin.acquisition_indexer_body(INDEXER_DECLARATION)
    check(failures, indexer["enable"] is True and indexer["priority"] == 25,
          "an indexer body must default to enabled at Prowlarr's own priority")
    check(failures, indexer["implementationName"] == "Newznab",
          "an indexer implementationName must default to the implementation")
    check(failures, indexer["fields"] == INDEXER_DECLARATION["fields"],
          "an indexer body must carry the declared fields unchanged")
    check(failures, indexer["fields"] is not INDEXER_DECLARATION["fields"],
          "an indexer body must copy the declared fields, not alias them")
    explicit = plugin.acquisition_indexer_body(
        dict(INDEXER_DECLARATION, enable=False, priority=17)
    )
    check(failures, explicit["enable"] is False and explicit["priority"] == 17,
          "a declared enable flag and priority must override the defaults")
    refuses(failures,
            lambda: plugin.acquisition_indexer_body(dict(
                INDEXER_DECLARATION,
                fields=[{"name": "apiKey", "value": 1}, {"name": "apiKey", "value": 2}])),
            "a duplicated indexer field name must be refused")

    # --- acquisition_indexer_masked_fields --------------------------------
    live = plugin.acquisition_indexer_body(INDEXER_DECLARATION)
    check(failures,
          plugin.acquisition_indexer_masked_fields(live, INDEXER_DECLARATION) == [],
          "a readable indexer must report no masked fields")
    hidden_indexer = copy.deepcopy(live)
    hidden_indexer["fields"] = masked(hidden_indexer["fields"], "apiKey")
    check(failures,
          plugin.acquisition_indexer_masked_fields(hidden_indexer, INDEXER_DECLARATION)
          == ["apiKey"],
          "an asterisked indexer field must be reported as masked")
    undeclared = copy.deepcopy(live)
    undeclared["fields"].append({"name": "undeclared", "value": "****"})
    check(failures,
          plugin.acquisition_indexer_masked_fields(undeclared, INDEXER_DECLARATION) == [],
          "a masked field this platform does not declare must not be reported")

    # --- the shared owned projection --------------------------------------
    refuses_with(failures,
                 lambda: plugin.acquisition_application_projection(readable, "apiKey"),
                 "masked Prowlarr application fields must be a sequence",
                 "a non-sequence application mask must be refused as the application's")
    refuses_with(failures,
                 lambda: plugin.acquisition_servarr_client_projection(client, "apiKey"),
                 "masked Servarr client fields must be a sequence",
                 "a non-sequence client mask must be refused as the client's")
    refuses_with(failures,
                 lambda: plugin.acquisition_indexer_projection(
                     live, INDEXER_DECLARATION, "apiKey"),
                 "masked Prowlarr indexer fields must be a sequence",
                 "a non-sequence indexer mask must be refused as the indexer's")
    refuses_with(failures,
                 lambda: plugin.acquisition_servarr_client_projection(None),
                 "Servarr SABnzbd client must be a mapping",
                 "a malformed download client must be named as the SABnzbd client")
    declared_extra = dict(
        INDEXER_DECLARATION,
        fields=INDEXER_DECLARATION["fields"] + [{"name": "apiPath", "value": "/api"}],
    )
    refuses_with(failures,
                 lambda: plugin.acquisition_indexer_projection(live, declared_extra),
                 "Prowlarr indexer field 'apiPath' is missing from readable state",
                 "a declared indexer field absent from the readback must be named")
    check(failures,
          "apiPath" not in plugin.acquisition_indexer_projection(
              live, declared_extra, ["apiPath"])["fields"],
          "a masked declared field must be skipped, not demanded of the readback")
    check(failures, list(plugin.acquisition_servarr_client_projection(client)) == [
        "name", "enable", "protocol", "priority", "removeCompletedDownloads",
        "removeFailedDownloads", "implementation", "implementationName",
        "configContract", "tags", "fields"],
        "the client projection must carry exactly its owned attributes, tags last")
    check(failures,
          list(plugin.acquisition_servarr_client_projection(client)["fields"]) == [
              "host", "port", "useSsl", "urlBase", "movieCategory", "tvCategory",
              "apiKey", "username", "password"],
          "the client projection must compare its readable fields and its secrets")
    check(failures, list(plugin.acquisition_indexer_projection(
        live, INDEXER_DECLARATION)) == [
            "name", "enable", "priority", "implementation", "implementationName",
            "configContract", "tags", "fields"],
        "the indexer projection must carry exactly its owned attributes, tags last")
    # A Servarr API omits `tags` from a resource that has none, and an explicit
    # null is a type that changed rather than an absence.
    without_tags = {key: item for key, item in readable.items() if key != "tags"}
    try:
        omitted_tags = plugin.acquisition_application_projection(without_tags)["tags"]
    except AnsibleFilterError as error:
        omitted_tags = f"refused: {error}"
    check(failures, omitted_tags == [],
          "a resource that omits tags entirely must project no tags, "
          f"not {omitted_tags!r}")
    refuses_with(failures,
                 lambda: plugin.acquisition_application_projection(
                     dict(readable, tags=None)),
                 "relationship integer lists must be sequences",
                 "a null tags value must be refused rather than read as empty")

    # --- acquisition_merge_owned_fields -----------------------------------
    current = [
        {"name": "baseUrl", "value": "https://stale.example"},
        {"name": "operatorChoice", "value": "keep me"},
        {"name": "apiKey", "value": "****"},
    ]
    desired = [{"name": "baseUrl", "value": "https://indexer.example"}]
    merged = plugin.acquisition_merge_owned_fields(current, desired)
    check(failures, merged == [
        {"name": "operatorChoice", "value": "keep me"},
        {"name": "apiKey", "value": "****"},
        {"name": "baseUrl", "value": "https://indexer.example"},
    ], "the merge must replace declared fields and preserve every other one")
    extra = plugin.acquisition_merge_owned_fields(current, desired, ["apiKey"])
    check(failures, [entry["name"] for entry in extra] == ["operatorChoice", "baseUrl"],
          "an extra owned name must drop that field even when it is not declared")
    check(failures,
          plugin.acquisition_merge_owned_fields(None, None) == [],
          "merging nothing into nothing must produce no fields")
    check(failures, merged[0] is not current[1],
          "the merge must copy the preserved fields, not alias them")
    refuses(failures,
            lambda: plugin.acquisition_merge_owned_fields(current, desired, "apiKey"),
            "a non-sequence set of extra owned names must be refused")

    return failures


def main():
    failures = collect_failures()
    if failures:
        for line in failures:
            print(f"FAIL {line}", file=sys.stderr)
        raise SystemExit(f"{len(failures)} Servarr relationship filter violation(s)")
    print("acquisition Servarr filters: bodies, masking and merges hold")


if __name__ == "__main__":
    main()
