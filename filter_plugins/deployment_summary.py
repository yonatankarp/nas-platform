"""Filters that turn two deployment manifests into a human-readable summary.

The manifest already records every pinned image of a release, so the difference
between the previously active release and the one just installed answers "what
did this deployment actually change" without a Git checkout at hand.
"""

import importlib.util
from pathlib import Path
import re

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


def _require_manifest(manifest, label):
    if manifest is None:
        return {"services": []}
    _GUARDS.mapping(manifest, f"{label} deployment manifest")
    services = manifest.get("services", [])
    if not _GUARDS.is_list(services):
        raise AnsibleFilterError(f"{label} deployment manifest services must be a list")
    return manifest


def _images(manifest):
    """Return {service: {container: image reference}} for one manifest."""
    images = {}
    for service in manifest.get("services", []) or []:
        if not isinstance(service, dict):
            raise AnsibleFilterError("deployment manifest service must be a mapping")
        name = service.get("name")
        if not isinstance(name, str) or not name:
            raise AnsibleFilterError("deployment manifest service must be named")
        declared = service.get("images")
        if declared is None:
            declared = {}
        if not isinstance(declared, dict):
            raise AnsibleFilterError(f"{name}: deployment manifest images must be a mapping")
        for container, reference in declared.items():
            if not isinstance(container, str) or not isinstance(reference, str):
                raise AnsibleFilterError(f"{name}: deployment manifest image entry is invalid")
            images.setdefault(name, {})[container] = reference
    return images


def _version(reference):
    """Return the readable tag of a pinned reference, ignoring its digest."""
    tagged = reference.split("@", 1)[0]
    final_segment = tagged.rsplit("/", 1)[-1]
    if ":" not in final_segment:
        return "untagged"
    return final_segment.rsplit(":", 1)[-1]


def _label(service, container):
    return service if service == container else f"{service}/{container}"


def deployment_image_changes(previous_manifest, current_manifest):
    """Return one sorted, non-secret entry per image the deployment moved.

    A repin — same readable tag, different digest — is reported as its own kind,
    because "nothing changed" and "the same tag now resolves elsewhere" are
    different answers to what shipped.

    Every image the release now runs carries its full pinned `reference`, which
    is the literal a Git pickaxe finds in the commit that introduced it. A
    removed image has nothing in the release to find, so it carries none.
    """
    previous = _images(_require_manifest(previous_manifest, "previous"))
    current = _images(_require_manifest(current_manifest, "current"))
    changes = []
    for service in sorted(set(previous) | set(current)):
        before = previous.get(service, {})
        after = current.get(service, {})
        for container in sorted(set(before) | set(after)):
            was = before.get(container)
            now = after.get(container)
            if was == now:
                continue
            label = _label(service, container)
            if was is None:
                changes.append({"name": label, "kind": "added", "to": _version(now), "reference": now})
            elif now is None:
                changes.append({"name": label, "kind": "removed", "from": _version(was)})
            elif _version(was) != _version(now):
                changes.append(
                    {
                        "name": label,
                        "kind": "updated",
                        "from": _version(was),
                        "to": _version(now),
                        "reference": now,
                    }
                )
            else:
                changes.append(
                    {"name": label, "kind": "repinned", "to": _version(now), "reference": now}
                )
    return changes


def deployment_change_lines(changes):
    """Render image changes as the lines a phone notification shows."""
    if not isinstance(changes, list):
        raise AnsibleFilterError("deployment image changes must be a list")
    lines = []
    for change in changes:
        if not isinstance(change, dict) or not isinstance(change.get("name"), str):
            raise AnsibleFilterError("deployment image change entry is invalid")
        name = change["name"]
        kind = change.get("kind")
        if kind == "updated":
            lines.append(f"{name} {change['from']} → {change['to']}")
        elif kind == "added":
            lines.append(f"{name} {change['to']} (new)")
        elif kind == "removed":
            lines.append(f"{name} {change['from']} (removed)")
        elif kind == "repinned":
            lines.append(f"{name} {change['to']} (repinned)")
        else:
            raise AnsibleFilterError("deployment image change kind is unknown")
    return lines


_SHA = re.compile(r"[0-9a-f]{40}")


def deployment_summary_document(changes, image_commits, commit_lines, release, previous):
    """Return the version-1 summary the deployment poller announces (#558).

    image_commits is the registered loop of per-image `git log -S` lookups, and
    commit_lines are `%H<TAB>%s` lines. Everything a lookup could not settle -- a
    skipped item, a non-zero exit, output that is not one SHA -- reads as no
    commit, because a wrong release-notes link is worse than none.
    """
    # Called for its exceptions, not its value: it is the only validation of the
    # change list's shape, and every kind it does not know raises. Discarding the
    # return is deliberate -- #654 read it as a stray statement, which is exactly
    # what a validation call with no name looks like.
    deployment_change_lines(changes)
    if not isinstance(image_commits, list) or not isinstance(commit_lines, list):
        raise AnsibleFilterError("deployment summary lookups must be lists")
    introduced = {}
    for lookup in image_commits:
        item = lookup.get("item") if isinstance(lookup, dict) else None
        sha = str(lookup.get("stdout", "")).strip() if isinstance(lookup, dict) else ""
        if isinstance(item, dict) and lookup.get("rc") == 0 and _SHA.fullmatch(sha):
            introduced[item.get("reference")] = sha
    commits = []
    for line in commit_lines:
        sha, _tab, subject = str(line).partition("\t")
        if _SHA.fullmatch(sha):
            commits.append({"sha": sha, "subject": subject})
    return {
        "version": 1,
        "release": release,
        "previous": previous if isinstance(previous, str) and _SHA.fullmatch(previous) else "",
        "images": [
            {
                "name": change["name"],
                "kind": change["kind"],
                "from": change.get("from"),
                "to": change.get("to"),
                "commit": introduced.get(change["reference"]) if "reference" in change else None,
            }
            for change in changes
        ],
        "commits": commits,
    }


class FilterModule:
    """Expose deployment report filters."""

    def filters(self):
        return {
            "deployment_image_changes": deployment_image_changes,
            "deployment_change_lines": deployment_change_lines,
            "deployment_summary_document": deployment_summary_document,
        }
