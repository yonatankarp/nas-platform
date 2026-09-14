#!/usr/bin/env python3
"""Behavior tests for strict managed-user state parsers."""

from __future__ import annotations

import importlib.util
import os
import pathlib

from ansible.errors import AnsibleFilterError


ROOT = pathlib.Path(__file__).resolve().parents[1]
PLUGIN_PATH = pathlib.Path(
    os.environ.get("MANAGED_USER_STATE_PLUGIN", ROOT / "filter_plugins" / "managed_user_state.py")
)


def load_plugin():
    spec = importlib.util.spec_from_file_location("managed_user_state", PLUGIN_PATH)
    if spec is None or spec.loader is None:
        raise AssertionError("managed-user state filter cannot be imported")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def require_rejected(parser, source: str, label: str) -> None:
    try:
        parser(source)
    except AnsibleFilterError:
        return
    raise AssertionError(f"accepted unsafe {label}")


plugin = load_plugin()
parse_users = plugin.managed_users_yaml

valid = parse_users(
    """---
users:
  Reader:
    password: hash
    custom:
      nested: [1, two, null]
outside:
  arbitrary: true
"""
)
assert valid == {
    "users": {
        "Reader": {
            "password": "hash",
            "custom": {"nested": [1, "two", None]},
        }
    },
    "outside": {"arbitrary": True},
}

unsafe_documents = {
    "malformed syntax": "users: [unterminated\n",
    "anchor": "users: &users {reader: {password: hash}}\n",
    "alias": "base: &base {password: hash}\nusers: {reader: *base}\n",
    "exact duplicate root key": "users: {}\nusers: {}\n",
    "exact duplicate user key": (
        "users:\n  reader: {password: one}\n  reader: {password: two}\n"
    ),
    "normalized duplicate user key": (
        "users:\n  Reader: {password: one}\n  ' reader ': {password: two}\n"
    ),
    "multiple documents": "users: {}\n---\nusers: {}\n",
    "non-mapping root": "[]\n",
    "non-mapping users": "users: []\n",
    "non-string user identity": "users:\n  42: {password: hash}\n",
}
for label, source in unsafe_documents.items():
    require_rejected(parse_users, source, label)

print("Managed-user state filter: strict YAML behavior holds")
