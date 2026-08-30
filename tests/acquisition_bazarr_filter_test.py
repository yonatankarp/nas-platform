#!/usr/bin/env python3
"""Behaviour of the Bazarr settings projection, its differences and the POST body.

The projection and the POST body were reachable only by spawning
`ansible-playbook`: the reconciliation fixture drove them through a fake Bazarr,
and nothing called them directly. They are pure functions, so the properties that
do not need a running Bazarr are checked here. The difference list joins them
because it is the printable half of the projection comparison, and what makes it
printable — that it names settings and never their values — is a property, not
an observation about today's callers.

`tests/fixtures/acquisition/bazarr_state.json` is a converged readback captured
from that fixture's Bazarr, keyed by argument name. Starting from a converged
state is what makes the cases below readable: each one breaks exactly one thing
and names what must be noticed.
"""

from __future__ import annotations

import copy
import importlib.util
import json
import pathlib
import sys

from ansible.errors import AnsibleFilterError

ROOT = pathlib.Path(__file__).resolve().parents[1]
PLUGIN = ROOT / "filter_plugins" / "acquisition_bazarr.py"
STATE = ROOT / "tests" / "fixtures" / "acquisition" / "bazarr_state.json"


def load_plugin():
    spec = importlib.util.spec_from_file_location("acquisition_bazarr", PLUGIN)
    if spec is None or spec.loader is None:
        raise AssertionError("the Bazarr filters cannot be imported")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


plugin = load_plugin()
STATE_FIXTURE = json.loads(STATE.read_text())


def project(**overrides):
    state = copy.deepcopy(STATE_FIXTURE)
    state.update(overrides)
    return plugin.acquisition_bazarr_owned_projections(
        state["settings"], state["language_state"], state["declarations"],
        state["username"], state["password"], state["radarr_api_key"],
        state["sonarr_api_key"],
    )


def settings_with(mutate):
    settings = copy.deepcopy(STATE_FIXTURE["settings"])
    mutate(settings)
    return settings


def differences(projections):
    return plugin.acquisition_bazarr_projection_differences(projections)


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
    fixture = STATE_FIXTURE

    # --- acquisition_bazarr_owned_projections -----------------------------
    converged = project()
    check(failures, converged["current"] == converged["desired"],
          "the captured Bazarr state is converged, so its two projections must agree")
    check(failures, converged["masked_connection_settings"] == []
          and converged["masked_provider_settings"] == []
          and converged["unmanaged_enabled_providers"] == [],
          "a converged Bazarr must report nothing masked and nothing unmanaged")

    for label, mutate in [
        ("auth.username", lambda s: s["auth"].update(username="someone-else")),
        ("auth.type", lambda s: s["auth"].update(type=None)),
        ("general.use_radarr", lambda s: s["general"].update(use_radarr=False)),
        ("radarr.port", lambda s: s["radarr"].update(port=1234)),
        ("sonarr.ssl", lambda s: s["sonarr"].update(ssl=True)),
        ("radarr.base_url", lambda s: s["radarr"].update(base_url="/stale")),
        ("path mappings", lambda s: s["general"].update(
            path_mappings=[["/from", "/to"]])),
        ("a provider setting", lambda s: s["animetosho"].update(search_threshold=99)),
    ]:
        drifted = project(settings=settings_with(mutate))
        check(failures, drifted["current"] != drifted["desired"],
              f"drift in {label} must show as a difference between the projections")
        # The difference list is the same verdict, said in field paths. Every
        # case the projections call drift must therefore name something.
        check(failures, differences(drifted) != [],
              f"drift in {label} must be named by the difference list")

    languages = copy.deepcopy(fixture["language_state"])
    languages[-1]["enabled"] = True
    drifted = project(language_state=languages)
    check(failures, drifted["current"]["connection"]["languages"] == ["de", "en", "fr"],
          "an enabled language must appear in the current projection")
    check(failures, drifted["current"] != drifted["desired"],
          "an undeclared enabled language must show as drift")

    masked = project(settings=settings_with(
        lambda s: s["auth"].update(password="****")
    ))
    check(failures, masked["masked_connection_settings"] == ["auth.password"],
          "an asterisked Bazarr password must be reported as masked")
    check(failures,
          "auth.password" not in masked["current"]["connection"]["readable_secrets"],
          "a masked secret must be left out of the comparison, not compared")
    check(failures, masked["current"] == masked["desired"],
          "masking a secret must not by itself look like drift")

    readable = project()
    check(failures,
          readable["current"]["connection"]["readable_secrets"]["auth.password"]
          == fixture["settings"]["auth"]["password"],
          "a readable Bazarr password hash must be projected for comparison")
    check(failures,
          readable["desired"]["connection"]["readable_secrets"]["auth.password"]
          != fixture["password"],
          "the desired password must be the hash Bazarr stores, not the plaintext")

    unmanaged = project(settings=settings_with(
        lambda s: s["general"].update(enabled_providers=["animetosho", "opensubtitles"])
    ))
    check(failures, unmanaged["unmanaged_enabled_providers"] == ["opensubtitles"],
          "a provider enabled outside this platform must be named, not silently kept")
    check(failures,
          unmanaged["current"]["connection"]["general"]["enabled_providers"]
          == ["animetosho"],
          "an unmanaged provider must be left out of the compared provider list")

    masked_provider = project(settings=settings_with(
        lambda s: s["animetosho"].update(search_threshold="****")
    ))
    check(failures,
          masked_provider["masked_provider_settings"] == ["animetosho.search_threshold"],
          "an asterisked provider setting must be reported as masked")
    check(failures,
          "search_threshold"
          not in masked_provider["current"]["providers"]["animetosho"],
          "a masked provider setting must be left out of the comparison")

    undeclared_setting = project(settings=settings_with(
        lambda s: s["animetosho"].update(operator_choice="kept")
    ))
    check(failures,
          undeclared_setting["current"]["providers"]["animetosho"]["operator_choice"]
          == "kept"
          and undeclared_setting["desired"]["providers"]["animetosho"]["operator_choice"]
          == "kept",
          "a provider setting this platform does not declare must be carried, not drift")

    refuses(failures,
            lambda: project(settings=settings_with(
                lambda s: s["radarr"].update(port="7878"))),
            "a Bazarr port that is not an integer must be refused, not coerced")
    refuses(failures,
            lambda: project(language_state=[
                {"code2": "en", "enabled": True}, {"code2": "en", "enabled": True}]),
            "a duplicated language identity must be refused")
    refuses(failures,
            lambda: project(settings=settings_with(
                lambda s: s["general"].update(
                    enabled_providers=["animetosho", "animetosho"]))),
            "an ambiguous enabled-provider list must be refused")
    refuses(failures, lambda: project(password=""),
            "an empty Bazarr administrator password must be refused")

    # --- acquisition_bazarr_projection_differences ------------------------
    # The projections carry live credentials, so the drift assert that holds
    # them runs under no_log and could report only that they were unequal. This
    # filter is the printable half of that verdict: the same comparison, said
    # as field paths.
    check(failures, differences(converged) == [],
          "a converged Bazarr must report no differences at all")

    for label, mutate, expected in [
        ("auth.type", lambda s: s["auth"].update(type=None),
         ["connection.auth.type"]),
        ("radarr.port", lambda s: s["radarr"].update(port=1234),
         ["connection.radarr.port"]),
        ("path mappings", lambda s: s["general"].update(
            path_mappings=[["/from", "/to"]]), ["connection.general.path_mappings"]),
        ("a provider setting", lambda s: s["animetosho"].update(search_threshold=99),
         ["providers.animetosho.search_threshold"]),
        ("a provider setting Bazarr has not stored",
         lambda s: s["animetosho"].pop("search_threshold"),
         ["providers.animetosho.search_threshold"]),
    ]:
        named = differences(project(settings=settings_with(mutate)))
        check(failures, named == expected,
              f"drift in {label} must be named exactly {expected}, not {named}")

    check(failures, differences(project(language_state=languages))
          == ["connection.languages"],
          "an undeclared enabled language must be named by its list, not its codes")

    # A drifted list is one leaf: Bazarr's languages, enabled providers and path
    # mappings are lists *of* values, so naming an element would print one.
    check(failures, differences(project(
              language_state=languages,
              settings=settings_with(lambda s: s["general"].update(
                  path_mappings=[["/from", "/to"]])))) ==
          ["connection.general.path_mappings", "connection.languages"],
          "a difference must name the list that drifted, never an element of it")

    # The redaction proof. Drift all three connection secrets at once and
    # require the result to name them and to carry none of them.
    secrets = {
        "password": "f" * 32,
        "radarr": "sentinel-radarr-api-key",
        "sonarr": "sentinel-sonarr-api-key",
    }

    def drift_every_secret(settings):
        settings["auth"]["password"] = secrets["password"]
        settings["radarr"]["apikey"] = secrets["radarr"]
        settings["sonarr"]["apikey"] = secrets["sonarr"]

    exposed = differences(project(settings=settings_with(drift_every_secret)))
    check(failures, exposed == ["connection.readable_secrets.auth.password",
                                "connection.readable_secrets.radarr.apikey",
                                "connection.readable_secrets.sonarr.apikey"],
          f"a drifted Bazarr secret must be named by its path, not by {exposed}")
    known_credentials = [
        *secrets.values(), fixture["password"], fixture["radarr_api_key"],
        fixture["sonarr_api_key"], fixture["settings"]["auth"]["password"],
        fixture["settings"]["radarr"]["apikey"],
        fixture["settings"]["sonarr"]["apikey"],
    ]
    check(failures, not any(credential in name
                            for name in exposed for credential in known_credentials),
          "the difference list must name a credential's setting, never its value")

    # Defence in depth for a projection key that is not a canonical identifier.
    # Nothing reaches one today — an undeclared live setting is copied to both
    # sides and so never differs — which is exactly why the rule is checked on a
    # projection built here rather than on one the fixture can produce.
    crafted = differences({
        "current": {"providers": {"animetosho": {"password=sentinel-value": "a"}}},
        "desired": {"providers": {"animetosho": {"password=sentinel-value": "b"}}},
    })
    check(failures, crafted == ["providers.animetosho[0]"],
          "a projection key that is not a canonical identifier must be named by position")

    refuses(failures, lambda: differences({"current": {}, "desired": []}),
            "a projection that is not a mapping must be refused, not diffed")
    refuses(failures, lambda: differences("not a projection"),
            "a projections argument that is not a mapping must be refused")

    # --- acquisition_bazarr_connection_body -------------------------------
    body = plugin.acquisition_bazarr_connection_body(
        fixture["declarations"], fixture["username"], fixture["password"],
        fixture["radarr_api_key"], fixture["sonarr_api_key"],
    )
    check(failures, body["settings-auth-type"] == "form"
          and body["settings-auth-username"] == fixture["username"]
          and body["settings-auth-password"] == fixture["password"],
          "the settings POST must carry form auth and the declared administrator")
    check(failures, body["settings-general-use_radarr"] == "true"
          and body["settings-general-use_sonarr"] == "true",
          "Bazarr's form takes booleans as the strings 'true' and 'false'")
    check(failures, body["settings-radarr-port"] == "7878"
          and body["settings-sonarr-port"] == "8989",
          "the form takes ports as strings, at this platform's fixed ports")
    check(failures, body["languages-enabled"] == ["de", "en"]
          and body["settings-general-enabled_providers"] == ["animetosho"],
          "the form must enable exactly the declared languages and providers")
    check(failures, body["settings-general-path_mappings"] == ["null"]
          and body["settings-general-path_mappings_movie"] == ["null"],
          "Bazarr's form spells an empty list ['null'], not []")

    preserved = plugin.acquisition_bazarr_connection_body(
        fixture["declarations"], fixture["username"], fixture["password"],
        fixture["radarr_api_key"], fixture["sonarr_api_key"],
        ["opensubtitles"],
    )
    check(failures,
          preserved["settings-general-enabled_providers"]
          == ["animetosho", "opensubtitles"],
          "the POST must keep providers enabled outside this platform enabled")

    empty = plugin.acquisition_bazarr_connection_body(
        {"languages": [], "provider_names": []},
        fixture["username"], fixture["password"], "k", "k",
    )
    check(failures, empty["languages-enabled"] == ["null"]
          and empty["settings-general-enabled_providers"] == ["null"],
          "an empty declaration must POST ['null'], which is how Bazarr clears a list")

    refuses(failures,
            lambda: plugin.acquisition_bazarr_connection_body(
                fixture["declarations"], "", fixture["password"], "k", "k"),
            "an empty administrator username must be refused")

    return failures


def main():
    failures = collect_failures()
    if failures:
        for line in failures:
            print(f"FAIL {line}", file=sys.stderr)
        raise SystemExit(f"{len(failures)} Bazarr filter violation(s)")
    print("acquisition Bazarr filters: projection, masking and settings POST hold")


if __name__ == "__main__":
    main()
