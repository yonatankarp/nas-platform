"""Normalization and merge of the Jellyfin plugin repository list.

`roles/jellyfin/tasks/settings.yml` previously built this list with six tasks,
four of which were `set_fact` loops that appended one entry per iteration: one
to key the desired repositories by normalized URL, one to pair every current
repository with its normalized URL, one to preserve the current repositories
that are neither retired nor overridden, and one to append the desired
repositories that are absent. Jellyfin's `POST /Repositories` replaces the whole
collection, so all four had to agree on one ordering, and the ordering was
expressed as "whichever order these four loops happened to run in".

The merge itself is a dictionary lookup with a fallback, which Jinja cannot
express over a list without either a nested loop or a `zip`/`regex_replace`
chain that hides the rule it implements. That is why this is Python and not more
Jinja.

Parity with the loops it replaces, verified by differential on ansible-core
2.21.3 rather than by reading:

* Normalization is `Url | trim | lower | regex_replace('/+$', '')`. Jinja's
  `trim` and `lower` stringify a non-string rather than refusing it, so this
  module stringifies too. The role asserts `item.Url is string` on the current
  repositories immediately before calling in, so that coercion is the behaviour
  of a path the role has already closed, not a new tolerance.
* The retired list is compared against the *normalized* URL but is itself used
  raw, exactly as the `when:` condition did. Normalizing it here would newly
  retire a repository whose declared URL differs only in case or trailing slash.
  Its list-ness is enforced, which the `when:` condition never did: `in` against
  a string is Python's substring test, so a scalar retired URL silently retired
  every repository whose URL it contained. That is a refusal, not a normalization
  — the raw comparison of the members themselves is unchanged.
* `combine` with the default `recursive=false` is a shallow overlay in which the
  desired keys win and every unrelated key on the current record survives, so
  the merge is `{**raw, **desired}` and not a replacement.
* Order is preserved current repositories first, in the order Jellyfin returned
  them, then absent desired repositories in declaration order. The role compares
  the merged list against the unmodified read-back to decide whether to POST at
  all, so any reordering would turn a converged platform into a permanent change.
* A desired repository that normalizes onto a retired URL is dropped when
  Jellyfin already lists it and appended when it does not. That is what the
  loops did; it is preserved deliberately rather than tidied.

The duplicate-URL refusal stays in the role as an `assert`, and this module
neither performs it nor depends on it: the role's task order runs the assert
between the inventory and the merge, so a duplicate still aborts with the role's
own message before any merged list is used.
"""

import importlib.util
import re
from pathlib import Path

from ansible.errors import AnsibleFilterError


# Filter plugins cannot import module_utils/ by name, and putting the repository
# root on sys.path to reach it would shadow site-packages with library/, roles/,
# services/ and tests/ for the whole Ansible process. Loading the file by path
# shares the guards with no global side effect. tests/policy_test.rb executes
# every filter plugin and fails if one of them touches sys.path.
_GUARDS_SPEC = importlib.util.spec_from_file_location(
    "nas_platform_schema_guards",
    Path(__file__).resolve().parents[1] / "module_utils" / "schema_guards.py",
)
_GUARDS = importlib.util.module_from_spec(_GUARDS_SPEC)
_GUARDS_SPEC.loader.exec_module(_GUARDS)


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

    Last-wins is what `combine` did per iteration. The role's duplicate refusal
    is what makes a collision fatal, so a collision is not rejected here.
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

    `inventory` is the output of `jellyfin_normalized_repositories`, `desired` the
    declared list, and `retired` the raw retired-URL list.
    """
    entries = _require_sequence(inventory, "the Jellyfin repository inventory")
    declared = _require_sequence(desired, "declared Jellyfin plugin repositories")
    retired = _require_sequence(retired, "retired Jellyfin plugin repository URLs")
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
