"""Filters that turn two deployment manifests into a human-readable summary."""

import runpy
from pathlib import Path
from types import SimpleNamespace
import re

from ansible.errors import AnsibleFilterError


# module_utils/ is run by file path, never via sys.path: tests/policy_test.rb
# says why, and fails any filter plugin that touches it.
_MODULE_UTILS = Path(__file__).resolve().parents[1] / "module_utils"
_GUARDS = SimpleNamespace(**runpy.run_path(str(_MODULE_UTILS / "schema_guards.py")))


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

    A repin (same tag, new digest) is its own kind. Current images carry their
    full `reference`, the literal a Git pickaxe finds.
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

    Any lookup that did not yield exactly one SHA reads as no commit: a wrong
    release-notes link is worse than none.
    """
    # Called for its exceptions only: it is the sole validation of the change
    # list's shape (#654).
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
            "deployment_summary_document": deployment_summary_document,
        }
