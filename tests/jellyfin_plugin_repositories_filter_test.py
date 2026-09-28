#!/usr/bin/env python3
"""Behavior tests for the Jellyfin plugin repository merge filters."""

import importlib.util
import pathlib

from ansible.errors import AnsibleFilterError


ROOT = pathlib.Path(__file__).resolve().parents[1]
PLUGIN_PATH = ROOT / "filter_plugins" / "jellyfin_plugin_repositories.py"

STABLE_URL = "https://repo.jellyfin.org/files/plugin/manifest.json"
INTRO_URL = "https://intro-skipper.org/manifest.json"
RETIRED_URL = "https://repo.jellyfin.org/releases/plugin/manifest-stable.json"


def load_plugin():
    spec = importlib.util.spec_from_file_location("jellyfin_plugin_repositories", PLUGIN_PATH)
    if spec is None or spec.loader is None:
        raise AssertionError("Jellyfin plugin repository filters cannot be imported")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def require_rejected(function, *arguments):
    try:
        function(*arguments)
    except AnsibleFilterError:
        return
    raise AssertionError(f"{function.__name__} accepted {arguments!r}")


plugin = load_plugin()
inventory_of = plugin.jellyfin_normalized_repositories
keyed_by_url = plugin.jellyfin_repositories_by_url
merged_from = plugin.jellyfin_merged_repositories

stable = {"Name": "Jellyfin Stable", "Url": STABLE_URL, "Enabled": True}
intro = {"Name": "Intro Skipper", "Url": INTRO_URL, "Enabled": True}
declared = [stable, intro]
retired = [RETIRED_URL]

assert sorted(plugin.FilterModule().filters()) == [
    "jellyfin_merged_repositories",
    "jellyfin_normalized_repositories",
    "jellyfin_repositories_by_url",
]

# Trim, lower, strip trailing slashes; the raw record is carried through.
noisy = {"Name": "Noisy", "Url": "  HTTPS://Repo.Jellyfin.ORG/files/plugin/manifest.json//  "}
assert inventory_of([noisy]) == [{"raw": noisy, "normalized_url": STABLE_URL}]
assert inventory_of([]) == []
assert inventory_of([{"Url": "///"}]) == [{"raw": {"Url": "///"}, "normalized_url": ""}]
assert inventory_of([{"Url": ""}]) == [{"raw": {"Url": ""}, "normalized_url": ""}]

# Non-strings are stringified like Jinja's trim/lower; the role's assert is the gate.
assert inventory_of([{"Url": 5}])[0]["normalized_url"] == "5"
assert inventory_of([{"Url": None}])[0]["normalized_url"] == "none"

# Declaration order kept, last declaration wins.
assert list(keyed_by_url(declared)) == [STABLE_URL, INTRO_URL]
shadowed = {"Name": "Shadow", "Url": STABLE_URL.upper() + "/"}
collided = keyed_by_url([stable, shadowed])
assert collided == {STABLE_URL: shadowed}
assert keyed_by_url([]) == {}

reported = {"Name": "Stale", "Url": STABLE_URL + "/", "Enabled": False, "Id": "keep", "X": [1]}
assert merged_from(inventory_of([reported]), declared, retired) == [
    {"Name": "Jellyfin Stable", "Url": STABLE_URL, "Enabled": True, "Id": "keep", "X": [1]},
    intro,
]

# Jellyfin's order first, then absent declarations: the role POSTs only when the
# merged list differs from the read-back.
assert merged_from(inventory_of([intro]), declared, retired) == [intro, stable]
assert merged_from(inventory_of(declared), declared, retired) == declared
assert merged_from([], declared, retired) == declared
assert merged_from(inventory_of(declared), [], retired) == declared
assert merged_from([], [], []) == []

third_party = {"Name": "Third Party", "Url": "https://example.invalid/manifest.json"}
assert merged_from(inventory_of([third_party, stable]), declared, retired) == [
    third_party,
    stable,
    intro,
]

# Both sides of the retired comparison are normalized (#648).
listed_retired = {"Name": "Old Stable", "Url": RETIRED_URL.upper()}
assert merged_from(inventory_of([listed_retired]), [], retired) == []
old_stable = {"Name": "Old", "Url": RETIRED_URL}
assert merged_from(inventory_of([old_stable]), [], [RETIRED_URL + "/"]) == []
assert merged_from(inventory_of([old_stable]), [], [RETIRED_URL.upper()]) == []
assert merged_from(inventory_of([old_stable]), [], ["  " + RETIRED_URL + "//  "]) == []
assert merged_from(inventory_of([old_stable]), [], [RETIRED_URL + "?x"]) == [old_stable]

# A declared repository matching a retired URL is dropped if listed, appended if not.
retired_declaration = {"Name": "Retired Declaration", "Url": RETIRED_URL}
assert merged_from(inventory_of([listed_retired]), [retired_declaration], retired) == []
assert merged_from([], [retired_declaration], retired) == [retired_declaration]

# A scalar retired value is refused: `in` on a string is a substring test.
require_rejected(merged_from, inventory_of([stable]), [], STABLE_URL)
require_rejected(merged_from, inventory_of([stable]), [], STABLE_URL + "?x")
require_rejected(merged_from, inventory_of([stable]), [], None)
require_rejected(merged_from, inventory_of([stable]), [], {STABLE_URL: True})

try:
    merged_from(inventory_of([stable]), [], STABLE_URL)
except AnsibleFilterError as refusal:
    assert str(refusal) == "retired Jellyfin plugin repository URLs must be a list", refusal
else:
    raise AssertionError("a scalar retired URL was accepted")

# A tuple is accepted (the templar can deliver one) and compared by equality.
assert merged_from(inventory_of([stable]), [], (STABLE_URL,)) == []
assert merged_from(inventory_of([stable]), [], (STABLE_URL + "?x",)) == [stable]

require_rejected(inventory_of, {"Url": STABLE_URL})
require_rejected(inventory_of, STABLE_URL)
require_rejected(inventory_of, None)
require_rejected(inventory_of, ["not-a-mapping"])
require_rejected(inventory_of, [{"Name": "No URL"}])
require_rejected(keyed_by_url, {STABLE_URL: stable})
require_rejected(keyed_by_url, [{"Name": "No URL"}])
require_rejected(merged_from, None, declared, retired)
require_rejected(merged_from, [{"raw": stable}], declared, retired)
require_rejected(merged_from, [{"normalized_url": STABLE_URL}], declared, retired)
require_rejected(merged_from, [{"raw": "text", "normalized_url": ""}], declared, retired)
require_rejected(merged_from, inventory_of([stable]), "not-a-list", retired)

print("Jellyfin plugin repository merge behavior passed")
