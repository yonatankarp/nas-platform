"""Normalization and merge of the Jellyfin plugin repository list.

`POST /Repositories` replaces the whole collection. Rules kept from the Jinja
loops this replaced:

* Normalization is `Url | trim | lower | regex_replace('/+$', '')`; both sides of
  the retired comparison are normalized, and the retired list must be a list
  (a scalar would be a substring test) (#648).
* The merge is a shallow `{**raw, **desired}` overlay.
* Order: current repositories as Jellyfin returned them, then absent desired
  ones in declaration order; any reordering would be a permanent change.
* A desired repository normalizing onto a retired URL is dropped when listed and
  appended when not -- a preserved wart.

The duplicate-URL refusal stays in the role as an `assert`, run before the merge.
"""

import re
import runpy
from pathlib import Path
from types import SimpleNamespace

from ansible.errors import AnsibleFilterError


# module_utils/ is run by file path, never via sys.path: tests/policy_test.rb
# says why, and fails any filter plugin that touches it.
_MODULE_UTILS = Path(__file__).resolve().parents[1] / "module_utils"
_GUARDS = SimpleNamespace(**runpy.run_path(str(_MODULE_UTILS / "schema_guards.py")))


def _normalized_url(value):
    """Reproduce `value | trim | lower | regex_replace('/+$', '')`."""
    text = value if isinstance(value, str) else str(value)
    return re.sub(r"/+$", "", text.strip().lower())


def _require_sequence(value, label):
    """Jellyfin reports a sequence as "a list"; the wording is the role's."""
    return _GUARDS.sequence(value, label, noun="a list")


def jellyfin_normalized_repositories(current):
    """Pair every repository Jellyfin reports with its normalized URL."""
    entries = _require_sequence(current, "Jellyfin plugin repositories")
    inventory = []
    for entry in entries:
        record = _GUARDS.mapping(entry, "a Jellyfin plugin repository")
        if "Url" not in record:
            raise AnsibleFilterError(
                "a Jellyfin plugin repository is missing its Url"
            )
        inventory.append(
            {"raw": record, "normalized_url": _normalized_url(record["Url"])}
        )
    return inventory


def jellyfin_repositories_by_url(desired):
    """Key the declared repositories by normalized URL, last declaration winning.

    The role's duplicate refusal is what makes a collision fatal.
    """
    entries = _require_sequence(desired, "declared Jellyfin plugin repositories")
    keyed = {}
    for entry in entries:
        record = _GUARDS.mapping(entry, "a declared Jellyfin plugin repository")
        if "Url" not in record:
            raise AnsibleFilterError(
                "a declared Jellyfin plugin repository is missing its Url"
            )
        keyed[_normalized_url(record["Url"])] = record
    return keyed


def jellyfin_merged_repositories(inventory, desired, retired):
    """Overlay the declared repositories onto the reported ones.

    `retired` is the raw list, normalized here like the inventory's URLs (#648).
    """
    entries = _require_sequence(inventory, "the Jellyfin repository inventory")
    declared = _require_sequence(desired, "declared Jellyfin plugin repositories")
    retired = {
        _normalized_url(url)
        for url in _require_sequence(
            retired, "retired Jellyfin plugin repository URLs"
        )
    }
    keyed = jellyfin_repositories_by_url(declared)

    merged = []
    for entry in entries:
        record = _GUARDS.mapping(entry, "a Jellyfin repository inventory entry")
        for key in ("raw", "normalized_url"):
            if key not in record:
                raise AnsibleFilterError(
                    f"a Jellyfin repository inventory entry is missing {key}"
                )
        normalized = record["normalized_url"]
        if normalized in retired:
            continue
        raw = _GUARDS.mapping(record["raw"], "a Jellyfin plugin repository")
        merged.append({**raw, **keyed.get(normalized, {})})

    reported = [record["normalized_url"] for record in entries]
    for record in declared:
        if _normalized_url(record["Url"]) not in reported:
            merged.append(record)
    return merged


class FilterModule:
    """Expose the Jellyfin plugin repository merge to Ansible."""

    def filters(self):
        return {
            "jellyfin_normalized_repositories": jellyfin_normalized_repositories,
            "jellyfin_repositories_by_url": jellyfin_repositories_by_url,
            "jellyfin_merged_repositories": jellyfin_merged_repositories,
        }
