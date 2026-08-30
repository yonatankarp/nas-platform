#!/usr/bin/env python3
"""Behaviour of the Configarr comparison, invariant and repair filters.

Seven of the eight Configarr filters were reachable only by spawning
`ansible-playbook`: `tests/acquisition_configarr_field_coverage_test.rb` calls
the owned projection, and the rest were exercised only as a side effect of a
reconciliation fixture run. Between them they are the largest functions in the
repository, and they are pure, so their contracts are stated here directly.

The inputs are the platform's own declaration — `roles/arr/files/configarr/` as
the plays pass it — and `tests/fixtures/acquisition/configarr_results.json`, a
converged Radarr and Sonarr readback captured from the reconciliation fixture
and reduced to the two keys these filters read. Converged is the useful starting
point: every case below breaks one thing and names what must be noticed.
"""

from __future__ import annotations

import copy
import importlib.util
import json
import pathlib
import sys

from ansible.errors import AnsibleFilterError

ROOT = pathlib.Path(__file__).resolve().parents[1]
PLUGIN = ROOT / "filter_plugins" / "acquisition_configarr.py"
CONFIGARR = ROOT / "roles" / "arr" / "files" / "configarr"
RESULTS = ROOT / "tests" / "fixtures" / "acquisition" / "configarr_results.json"


def load_plugin():
    spec = importlib.util.spec_from_file_location("acquisition_configarr", PLUGIN)
    if spec is None or spec.loader is None:
        raise AssertionError("the Configarr filters cannot be imported")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


plugin = load_plugin()
RESULTS_FIXTURE = json.loads(RESULTS.read_text())
CONFIG_SOURCE = (CONFIGARR / "config.yml").read_text()
SOURCES = {
    "radarr": (CONFIGARR / "quality-definition-movie.json").read_text(),
    "sonarr": (CONFIGARR / "quality-definition-series.json").read_text(),
}


def resource(results, service, endpoint):
    """Return the readback entry for one service's endpoint, for mutation."""
    for entry in results:
        if entry["item"][0]["name"] == service and entry["item"][1] == endpoint:
            return entry
    raise AssertionError(f"the fixture has no {service} {endpoint} readback")


def results_with(mutate):
    results = copy.deepcopy(RESULTS_FIXTURE)
    mutate(results)
    return results


def check(failures, condition, message):
    if not condition:
        failures.append(message)


def refuses(failures, call, message):
    try:
        call()
    except AnsibleFilterError:
        return
    failures.append(message)


def collect_failures():
    failures = []
    projection = plugin.acquisition_configarr_owned_projection(RESULTS_FIXTURE)

    # --- acquisition_configarr_declared_projection ------------------------
    declared = plugin.acquisition_configarr_declared_projection(projection)
    radarr = declared["radarr"]["quality_profile"]
    check(failures, radarr["qualitySort"] == "top",
          "every enabled quality ahead of every disabled one is Configarr's 'top' sort")
    check(failures, radarr["resetUnmatchedScores"] is True,
          "every unowned format scoring zero is Configarr's reset-unmatched-scores")
    check(failures, radarr["cutoff"] == "Bluray-1080p",
          "the cutoff must be reported as a quality name, not a generated identity")
    check(failures, radarr["format_assignment"]["identity_count"] == 1,
          "the owned custom format must be assigned a score exactly once")
    check(failures,
          set(radarr["items"]["disabled_quality_names"])
          <= set(radarr["items"]["quality_names"]),
          "a disabled quality must be one of the qualities the service knows")

    check(failures,
          plugin.acquisition_configarr_declared_projection(
              _sorted_profile(projection, "bottom")
          )["radarr"]["quality_profile"]["qualitySort"] == "bottom",
          "every enabled quality ahead of every disabled one is the 'bottom' sort")
    check(failures,
          plugin.acquisition_configarr_declared_projection(
              _sorted_profile(projection, "top")
          )["radarr"]["quality_profile"]["qualitySort"] == "top",
          "every disabled quality ahead of every enabled one is the 'top' sort")
    mixed = plugin.acquisition_configarr_declared_projection(
        _interleaved_profile(projection)
    )
    check(failures,
          mixed["radarr"]["quality_profile"]["qualitySort"] == "nonconforming",
          "an interleaved profile is neither sort and must be named as such")
    scored = copy.deepcopy(projection)
    for item in scored["radarr"]["quality_profile"]["format_assignments"]:
        if item["name"] != "NAS Repack or Proper":
            item["score"] = 5
    if len(scored["radarr"]["quality_profile"]["format_assignments"]) > 1:
        check(failures,
              plugin.acquisition_configarr_declared_projection(scored)["radarr"]
              ["quality_profile"]["resetUnmatchedScores"] is False,
              "an unowned format carrying a score must clear resetUnmatchedScores")

    absent = copy.deepcopy(projection)
    absent["radarr"]["quality_profile"] = None
    absent["radarr"]["quality_profile_identity_count"] = 0
    check(failures,
          plugin.acquisition_configarr_declared_projection(absent)["radarr"]
          ["quality_profile"] is None,
          "a missing owned profile must project as absent, not as an empty profile")

    # --- acquisition_configarr_desired_projection -------------------------
    desired = plugin.acquisition_configarr_desired_projection(
        CONFIG_SOURCE, projection
    )
    check(failures, declared == desired,
          "the captured readback is converged, so declared and desired must agree")
    for service in ("radarr", "sonarr"):
        profile = desired[service]["quality_profile"]
        check(failures, profile["cutoffFormatScore"] == 1
              and profile["minUpgradeFormatScore"] == 1,
              f"Configarr derives {service}'s disabled-upgrade cutoff fields as 1")
        check(failures, profile["items"]["quality_names"]
              == sorted(profile["items"]["quality_names"]),
              f"{service}'s materialized quality names must be sorted")
        check(failures, profile["items"]["disabled_quality_names"],
              f"{service} must leave the qualities it does not declare disabled")
        check(failures,
              desired[service]["custom_format"]["name"] == "NAS Repack or Proper",
              f"{service} must declare the owned custom format by name")
    check(failures,
          desired["radarr"]["quality_profile"]["format_assignment"]["value"]["format"]
          == projection["radarr"]["custom_format_id"],
          "the desired score must name the custom-format identity Radarr created")
    check(failures, "renameMovies" in desired["radarr"]["naming"]
          and "renameEpisodes" in desired["sonarr"]["naming"],
          "each service's naming fields must be its own")

    refuses(failures,
            lambda: plugin.acquisition_configarr_desired_projection("", projection),
            "an empty Configarr configuration source must be refused")
    refuses(failures,
            lambda: plugin.acquisition_configarr_desired_projection(
                CONFIG_SOURCE + "\n\x00", projection),
            "a Configarr configuration source with a NUL byte must be refused")
    refuses(failures,
            lambda: plugin.acquisition_configarr_desired_projection(
                "radarr: [", projection),
            "an unparseable Configarr configuration must be refused")
    refuses(failures,
            lambda: plugin.acquisition_configarr_desired_projection(
                CONFIG_SOURCE, {"radarr": projection["radarr"]}),
            "a projection missing a service must be refused")

    # --- acquisition_configarr_missing_custom_format_bodies ---------------
    check(failures,
          plugin.acquisition_configarr_missing_custom_format_bodies(
              CONFIG_SOURCE, projection) == {},
          "nothing may be created while both custom formats already exist")
    without_format = copy.deepcopy(projection)
    without_format["radarr"]["custom_format_identity_count"] = 0
    without_format["radarr"]["custom_format_id"] = None
    without_format["radarr"]["custom_format"] = None
    bodies = plugin.acquisition_configarr_missing_custom_format_bodies(
        CONFIG_SOURCE, without_format
    )
    check(failures, list(bodies) == ["radarr"],
          "only the service whose custom format is absent may get a create body")
    body = bodies.get("radarr", {})
    check(failures, body.get("name") == "NAS Repack or Proper",
          "the create body must carry the declared custom-format name")
    check(failures, isinstance(body.get("specifications"), list)
          and body["specifications"]
          and isinstance(body["specifications"][0].get("fields"), list),
          "the create body must spell specification fields as the API's name/value list")
    ambiguous = copy.deepcopy(projection)
    ambiguous["radarr"]["custom_format_identity_count"] = 2
    refuses(failures,
            lambda: plugin.acquisition_configarr_missing_custom_format_bodies(
                CONFIG_SOURCE, ambiguous),
            "an ambiguous custom-format identity must be refused, not created over")

    # --- acquisition_configarr_quality_definition_invariants --------------
    invariants = plugin.acquisition_configarr_quality_definition_invariants(
        projection, SOURCES
    )
    check(failures, sorted(invariants) == ["opaque_context", "source_current",
                                           "source_desired"],
          "the invariants must separate the compared pair from the carried context")
    for service in ("radarr", "sonarr"):
        current = invariants["source_current"][service]
        desired_sizes = invariants["source_desired"][service]
        opaque = invariants["opaque_context"][service]
        check(failures, len(current) == len(desired_sizes),
              f"{service} must produce one desired entry per comparable definition")
        check(failures, len(opaque) >= len(current),
              f"{service}'s context must cover every definition, compared or not")
        check(failures, all(set(item) <= {"quality", "minSize", "preferredSize",
                                          "maxSize", "title"} for item in current),
              f"{service} may only compare the fields Configarr owns")
        check(failures, all("weight" in item and "id" in item for item in opaque),
              f"{service}'s context must carry the metadata Servarr owns")
        check(failures, [item["quality"] for item in current]
              == sorted(item["quality"] for item in current),
              f"{service}'s compared definitions must be sorted by quality name")
    refuses(failures,
            lambda: plugin.acquisition_configarr_quality_definition_invariants(
                projection, {"radarr": SOURCES["radarr"]}),
            "a source document set missing a service must be refused")
    refuses(failures,
            lambda: plugin.acquisition_configarr_quality_definition_invariants(
                projection, {"radarr": SOURCES["sonarr"], "sonarr": SOURCES["radarr"]}),
            "a source document belonging to the other service must be refused")

    # --- acquisition_configarr_quality_definition_difference --------------
    check(failures,
          plugin.acquisition_configarr_quality_definition_difference(invariants) == {},
          "a converged readback must produce no quality-definition difference")
    drifted = copy.deepcopy(invariants)
    drifted["source_current"]["radarr"][0]["maxSize"] = 1
    difference = plugin.acquisition_configarr_quality_definition_difference(drifted)
    check(failures, list(difference) == ["radarr"],
          "only the service whose sizes differ may be reported")
    check(failures, len(difference.get("radarr", [])) == 1,
          "only the definition that differs may be reported, not the whole set")
    entry = difference.get("radarr", [{}])[0]
    check(failures, entry.get("quality")
          == invariants["source_current"]["radarr"][0]["quality"]
          and entry.get("current") != entry.get("desired"),
          "the difference must name the quality and both of its values")

    # --- acquisition_configarr_quality_definitions_settled ----------------
    for service in ("radarr", "sonarr"):
        check(failures,
              plugin.acquisition_configarr_quality_definitions_settled(
                  projection[service]["quality_definitions"], SOURCES[service], service
              ) is True,
              f"{service}'s captured definitions carry their declared sizes")
    unsettled = copy.deepcopy(projection["radarr"]["quality_definitions"])
    unsettled[0]["maxSize"] = 1
    check(failures,
          plugin.acquisition_configarr_quality_definitions_settled(
              unsettled, SOURCES["radarr"], "radarr") is False,
          "a definition still carrying its previous size must not read as settled")
    undeclared = [{"quality": {"name": "Not In The Guide"}, "maxSize": 1}]
    check(failures,
          plugin.acquisition_configarr_quality_definitions_settled(
              undeclared, SOURCES["radarr"], "radarr") is True,
          "a quality the source document does not name has nothing to settle on")
    refuses(failures,
            lambda: plugin.acquisition_configarr_quality_definitions_settled(
                projection["radarr"]["quality_definitions"], "{}", "radarr"),
            "a source document with the wrong identity must be refused")

    # --- acquisition_configarr_profile_repair_bodies ----------------------
    check(failures,
          plugin.acquisition_configarr_profile_repair_bodies(
              CONFIG_SOURCE, RESULTS_FIXTURE) == {},
          "a converged profile must need no repair")

    def break_cutoff(results):
        profiles = resource(results, "radarr", "qualityprofile")["json"]
        for profile in profiles:
            if profile["name"] == "HD Bluray + WEB 1080p":
                profile["minFormatScore"] = 99
    repairs = plugin.acquisition_configarr_profile_repair_bodies(
        CONFIG_SOURCE, results_with(break_cutoff)
    )
    check(failures, list(repairs) == ["radarr"],
          "only the service whose profile drifted may be repaired")
    repair = repairs.get("radarr", {})
    check(failures, isinstance(repair.get("id"), int),
          "a repair must name the profile identity it will PUT to")
    body = repair.get("body", {})
    check(failures, body.get("minFormatScore")
          == plugin.acquisition_configarr_desired_projection(
              CONFIG_SOURCE,
              plugin.acquisition_configarr_owned_projection(results_with(break_cutoff)),
          )["radarr"]["quality_profile"]["minFormatScore"],
          "the repair body must carry the declared value, not the drifted one")
    check(failures, isinstance(body.get("items"), list) and body["items"],
          "the repair must PUT the whole materialized item tree, not a fragment")
    check(failures,
          any(item["name"] == "NAS Repack or Proper" and item["score"] != 0
              for item in body.get("formatItems", [])),
          "the repair must keep the owned format's score")
    check(failures,
          all(item["score"] == 0 for item in body.get("formatItems", [])
              if item["name"] != "NAS Repack or Proper"),
          "the repair must reset every unowned format's score, as Configarr does")

    def drop_profile(results):
        entry = resource(results, "radarr", "qualityprofile")
        entry["json"] = [item for item in entry["json"]
                         if item["name"] != "HD Bluray + WEB 1080p"]
    check(failures,
          plugin.acquisition_configarr_profile_repair_bodies(
              CONFIG_SOURCE, results_with(drop_profile)) == {},
          "an absent profile is created by Configarr, not repaired by this platform")

    def duplicate_naming(results):
        results.append(copy.deepcopy(resource(results, "radarr", "config/naming")))
    refuses(failures,
            lambda: plugin.acquisition_configarr_profile_repair_bodies(
                CONFIG_SOURCE, results_with(duplicate_naming)),
            "an ambiguous readback identity must be refused, not repaired from")

    return failures


def _sorted_profile(projection, order):
    """Return the projection with Radarr's items in one of Configarr's two sorts.

    The API orders a profile worst-first, so Configarr's "top" — the declared
    qualities preferred over everything else — is the disabled block first in
    the array, and "bottom" is the reverse.
    """
    sorted_projection = copy.deepcopy(projection)
    items = sorted_projection["radarr"]["quality_profile"]["items"]
    enabled = [item for item in items if item["allowed"]]
    disabled = [item for item in items if not item["allowed"]]
    if not enabled or not disabled:
        raise AssertionError("the fixture cannot express either sort order")
    sorted_projection["radarr"]["quality_profile"]["items"] = (
        disabled + enabled if order == "top" else enabled + disabled
    )
    return sorted_projection


def _interleaved_profile(projection):
    """Return the projection with Radarr's profile items alternating."""
    interleaved = copy.deepcopy(projection)
    items = interleaved["radarr"]["quality_profile"]["items"]
    enabled = [item for item in items if item["allowed"]]
    disabled = [item for item in items if not item["allowed"]]
    if not enabled or len(disabled) < 2:
        raise AssertionError("the fixture cannot express an interleaved profile")
    interleaved["radarr"]["quality_profile"]["items"] = (
        [disabled[0]] + enabled + disabled[1:]
    )
    return interleaved


def main():
    failures = collect_failures()
    if failures:
        for line in failures:
            print(f"FAIL {line}", file=sys.stderr)
        raise SystemExit(f"{len(failures)} Configarr filter violation(s)")
    print("acquisition Configarr filters: comparison, invariants and repair hold")


if __name__ == "__main__":
    main()
