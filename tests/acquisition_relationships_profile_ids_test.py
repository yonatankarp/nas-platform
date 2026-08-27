#!/usr/bin/env python3
"""Behavior tests for Configarr materialized profile-tree identities."""

from __future__ import annotations

import importlib.util
import pathlib

from ansible.errors import AnsibleFilterError


ROOT = pathlib.Path(__file__).resolve().parents[1]
PLUGIN_PATH = ROOT / "filter_plugins" / "acquisition_relationships.py"


def load_plugin():
    spec = importlib.util.spec_from_file_location(
        "acquisition_relationships", PLUGIN_PATH
    )
    if spec is None or spec.loader is None:
        raise AssertionError("acquisition relationship filter cannot be imported")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def require_rejected(items, label: str) -> None:
    try:
        profile_item_ids(items, "Configarr test profile items")
    except AnsibleFilterError:
        return
    raise AssertionError(f"accepted unsafe profile-tree identity: {label}")


plugin = load_plugin()
profile_item_ids = plugin._configarr_profile_item_ids

valid_items = [
    {
        "id": 1001,
        "name": "WEB 1080p",
        "allowed": True,
        "items": [
            {
                "quality": {"id": 3, "name": "WEBDL-1080p"},
                "allowed": True,
                "items": [],
            },
            {
                "quality": {"id": 15, "name": "WEBRip-1080p"},
                "allowed": True,
                "items": [],
            },
        ],
    },
    {
        "quality": {"id": 7, "name": "Bluray-1080p"},
        "allowed": True,
        "items": [],
    },
]
assert profile_item_ids(valid_items, "Configarr test profile items") == {
    "WEB 1080p": 1001,
    "WEBDL-1080p": 3,
    "WEBRip-1080p": 15,
    "Bluray-1080p": 7,
}

colliding_items = [
    {
        "id": 1001,
        "name": "WEB 1080p",
        "allowed": True,
        "items": [
            {
                "quality": {"id": 1001, "name": "WEBDL-1080p"},
                "allowed": True,
                "items": [],
            }
        ],
    }
]
require_rejected(colliding_items, "generated group and nested quality ID collision")

for invalid_id in [True, 0, -1, 1.5]:
    invalid_group = [
        {"id": invalid_id, "name": "WEB 1080p", "allowed": True, "items": []}
    ]
    require_rejected(invalid_group, f"group ID {invalid_id!r}")

    invalid_quality = [
        {
            "id": 1001,
            "name": "WEB 1080p",
            "allowed": True,
            "items": [
                {
                    "quality": {"id": invalid_id, "name": "WEBDL-1080p"},
                    "allowed": True,
                    "items": [],
                }
            ],
        }
    ]
    require_rejected(invalid_quality, f"nested quality ID {invalid_id!r}")

print("Configarr materialized profile-tree identity behavior holds")
