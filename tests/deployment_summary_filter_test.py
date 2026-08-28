#!/usr/bin/env python3
"""Behavior tests for the deployment report summary filters."""

import importlib.util
import pathlib

from ansible.errors import AnsibleFilterError


ROOT = pathlib.Path(__file__).resolve().parents[1]
PLUGIN_PATH = ROOT / "filter_plugins" / "deployment_summary.py"


def load_plugin():
    spec = importlib.util.spec_from_file_location("deployment_summary", PLUGIN_PATH)
    if spec is None or spec.loader is None:
        raise AssertionError("deployment summary filter cannot be imported")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def require_rejected(function, *arguments):
    try:
        function(*arguments)
    except AnsibleFilterError:
        return
    raise AssertionError(f"accepted invalid deployment summary input: {arguments!r}")


def manifest(images):
    return {
        "git_sha": "0" * 40,
        "services": [
            {"name": name, "images": containers} for name, containers in images.items()
        ],
    }


plugin = load_plugin()
changes_of = plugin.deployment_image_changes
lines_of = plugin.deployment_change_lines
headline_of = plugin.deployment_report_headline

DIGEST_A = "@sha256:" + "a" * 64
DIGEST_B = "@sha256:" + "b" * 64

previous = manifest(
    {
        "jellyfin": {"jellyfin": "docker.io/jellyfin/jellyfin:10.10.3" + DIGEST_A},
        "immich": {
            "immich-server": "ghcr.io/immich-app/immich-server:v1.121.0" + DIGEST_A,
            "immich-machine-learning": "ghcr.io/immich-app/immich-ml:v1.121.0" + DIGEST_A,
        },
        "ntfy": {"ntfy": "docker.io/binwiederhier/ntfy:v2.27.0" + DIGEST_A},
        "retired": {"retired": "docker.io/library/retired:1.0.0" + DIGEST_A},
    }
)
current = manifest(
    {
        "jellyfin": {"jellyfin": "docker.io/jellyfin/jellyfin:10.11.0" + DIGEST_B},
        "immich": {
            "immich-server": "ghcr.io/immich-app/immich-server:v1.122.0" + DIGEST_B,
            "immich-machine-learning": "ghcr.io/immich-app/immich-ml:v1.121.0" + DIGEST_A,
        },
        "ntfy": {"ntfy": "docker.io/binwiederhier/ntfy:v2.27.0" + DIGEST_B},
        "komga": {"komga": "docker.io/gotson/komga:1.19.0" + DIGEST_A},
    }
)

changes = changes_of(previous, current)
assert changes == [
    {"name": "immich/immich-server", "kind": "updated", "from": "v1.121.0", "to": "v1.122.0"},
    {"name": "jellyfin", "kind": "updated", "from": "10.10.3", "to": "10.11.0"},
    {"name": "komga", "kind": "added", "to": "1.19.0"},
    {"name": "ntfy", "kind": "repinned", "to": "v2.27.0"},
    {"name": "retired", "kind": "removed", "from": "1.0.0"},
], changes

assert lines_of(changes) == [
    "immich/immich-server v1.121.0 → v1.122.0",
    "jellyfin 10.10.3 → 10.11.0",
    "komga 1.19.0 (new)",
    "ntfy v2.27.0 (repinned)",
    "retired 1.0.0 (removed)",
]

# An unchanged release must read as unchanged rather than as a repin.
assert changes_of(current, current) == []
assert lines_of([]) == []

# A first install has no previous manifest at all.
first_install = changes_of(None, manifest({"ntfy": {"ntfy": "docker.io/x/ntfy:v2.27.0" + DIGEST_A}}))
assert first_install == [{"name": "ntfy", "kind": "added", "to": "v2.27.0"}]

# The title names services, deduplicated across a service's own containers.
assert headline_of(changes, []) == "NAS deployed: immich, jellyfin, komga +2"
assert headline_of(changes[:1], []) == "NAS deployed: immich"
assert headline_of([], ["fix: correct the Komga library path"]) == (
    "NAS deployed: 1 change, no image moved"
)
assert headline_of([], ["one", "two"]) == "NAS deployed: 2 changes, no image moved"
assert headline_of([], []) == "NAS deployed: no change"

# A digest-only pin is still a released change, and an untagged image is named.
untagged = changes_of(
    manifest({"beszel": {"beszel": "docker.io/henrygd/beszel" + DIGEST_A}}),
    manifest({"beszel": {"beszel": "docker.io/henrygd/beszel" + DIGEST_B}}),
)
assert untagged == [{"name": "beszel", "kind": "repinned", "to": "untagged"}]

require_rejected(changes_of, "not-a-manifest", current)
require_rejected(changes_of, {"services": {"jellyfin": {}}}, current)
require_rejected(changes_of, {"services": [{"images": {}}]}, current)
require_rejected(changes_of, {"services": [{"name": "x", "images": []}]}, current)
require_rejected(changes_of, {"services": [{"name": "x", "images": {"x": 7}}]}, current)
require_rejected(lines_of, "changes")
require_rejected(lines_of, [{"name": "x", "kind": "unheard-of"}])
require_rejected(lines_of, [{"kind": "added", "to": "1.0"}])
require_rejected(headline_of, [], "commits")

print("Deployment report summary behavior passed")
