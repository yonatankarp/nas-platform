"""Filters that turn two deployment manifests into a human-readable summary.

The manifest already records every pinned image of a release, so the difference
between the previously active release and the one just installed answers "what
did this deployment actually change" without a Git checkout at hand.
"""

from ansible.errors import AnsibleFilterError


def _require_manifest(manifest, label):
    if manifest is None:
        return {"services": []}
    if not isinstance(manifest, dict):
        raise AnsibleFilterError(f"{label} deployment manifest must be a mapping")
    services = manifest.get("services", [])
    if not isinstance(services, list):
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
                changes.append({"name": label, "kind": "added", "to": _version(now)})
            elif now is None:
                changes.append({"name": label, "kind": "removed", "from": _version(was)})
            elif _version(was) != _version(now):
                changes.append(
                    {
                        "name": label,
                        "kind": "updated",
                        "from": _version(was),
                        "to": _version(now),
                    }
                )
            else:
                changes.append({"name": label, "kind": "repinned", "to": _version(now)})
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


def deployment_report_headline(changes, commits):
    """Return the notification title: what moved, readable on a lock screen."""
    if not isinstance(commits, list):
        raise AnsibleFilterError("deployment commit subjects must be a list")
    deployment_change_lines(changes)
    names = []
    for change in changes:
        name = change["name"].split("/", 1)[0]
        if name not in names:
            names.append(name)
    if names:
        shown = ", ".join(names[:3])
        if len(names) > 3:
            shown = f"{shown} +{len(names) - 3}"
        return f"NAS deployed: {shown}"
    if commits:
        subject = "1 change" if len(commits) == 1 else f"{len(commits)} changes"
        return f"NAS deployed: {subject}, no image moved"
    return "NAS deployed: no change"


class FilterModule:
    """Expose deployment report filters."""

    def filters(self):
        return {
            "deployment_image_changes": deployment_image_changes,
            "deployment_change_lines": deployment_change_lines,
            "deployment_report_headline": deployment_report_headline,
        }
