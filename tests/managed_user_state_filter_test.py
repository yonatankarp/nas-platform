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
parse_env = plugin.managed_user_env
parse_ntfy_users = plugin.ntfy_auth_users
parse_ntfy_list = plugin.ntfy_user_list

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

environment = parse_env(
    """# existing runtime state
NTFY_AUTH_USERS=admin:$$2b$$12$$hash:admin,reader:$$2b$$12$$reader:user
NTFY_AUTH_ACCESS=reader:nas-critical:read-only
NTFY_AUTH_TOKENS=
"""
)
assert environment["NTFY_AUTH_USERS"] == (
    "admin:$$2b$$12$$hash:admin,reader:$$2b$$12$$reader:user"
)
require_rejected(parse_env, "NTFY_AUTH_USERS=one\nNTFY_AUTH_USERS=two\n", "duplicate env key")
require_rejected(parse_env, "not an env assignment\n", "malformed env line")

provisioned = parse_ntfy_users(environment["NTFY_AUTH_USERS"])
assert provisioned == {
    "admin": {"username": "admin", "password_hash": "$2b$12$hash", "role": "admin"},
    "reader": {"username": "reader", "password_hash": "$2b$12$reader", "role": "user"},
}
require_rejected(parse_ntfy_users, "reader:hash:user,Reader:hash:user", "normalized ntfy env identity")
require_rejected(parse_ntfy_users, "reader:hash:owner", "invalid ntfy env role")

listed = parse_ntfy_list(
    """user * (role: anonymous, tier: none)
- no access to any (other) topics (server config)
user admin (role: admin, tier: none, server config)
- read-write access to all topics (admin role)
user manual.user (role: user, tier: none)
- no topic-specific permissions
"""
)
assert listed == {
    "*": {"username": "*", "role": "anonymous", "provisioned": False},
    "admin": {"username": "admin", "role": "admin", "provisioned": True},
    "manual.user": {"username": "manual.user", "role": "user", "provisioned": False},
}
require_rejected(parse_ntfy_list, "", "empty ntfy CLI output")
require_rejected(parse_ntfy_list, "user reader changed format\n", "changed ntfy CLI output")
require_rejected(
    parse_ntfy_list,
    "user * (role: anonymous, tier: none)\n- permissions changed format\n",
    "changed ntfy CLI permission output",
)
require_rejected(
    parse_ntfy_list,
    "user * (role: anonymous, tier: none)\n- no permissions\n"
    "user Reader (role: user, tier: none)\n- no permissions\n"
    "user reader (role: user, tier: none)\n- no permissions\n",
    "normalized duplicate ntfy CLI identity",
)

print("Managed-user state filter: strict YAML, env, and ntfy CLI behavior holds")
