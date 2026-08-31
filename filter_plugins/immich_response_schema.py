"""Schema validation for the preference documents Immich sends back.

`roles/immich/tasks/managed_users.yml` carried this as two byte-identical
36-condition `assert` tasks — one before the batch creation boundary and one
after it — differing only in the register they looped over. Both ran under
`no_log` with a generic `fail_msg`, so an Immich release that changed one field's
type reported only that the response was unsupported.

**This is not `immich_preference_schema`, and the two must not be merged.** That
module validates what the *operator declares*: profiles and per-email overrides
authored in the vault, where every scope and every field is optional because the
role reads them through `| default(...)`, and where an unknown key is a typo that
must be refused. This module validates what the *Immich API returns*, and the
rules are the opposite in three places:

* **Every scope and every field is required.** The conditions read
  `item.json.cast.gCastEnabled is boolean`; a missing key is Undefined, which
  fails that test, so absence was already a rejection.
* **Unknown keys are accepted.** The condition was `[...12 names...] |
  difference(item.json.keys() | list) | length == 0`, which requires the twelve
  to be present and says nothing about the rest. Immich adding a preference
  field must not fail a converged deployment.
* **`archiveSize`, `duration` and `minimumFaces` are integers, not positive
  integers**, and there is no `avatar` scope: the avatar colour is a property of
  the admin user document, guarded by a separate task.

Unlike the declared-preference schema, every name this module can print is an
Immich API literal from the table below, so paths name the field. The value is
never printed and neither is anything drawn from the response, because the task
that calls this loops over `uri` results whose `item` is a vault managed-user
record; only `item.json` is ever passed in, and only these literal paths ever
come out.

Semantics are matched to Ansible's own Jinja tests, verified on ansible-core
2.21.3: `is integer` rejects booleans, `is boolean` rejects integers, and `is
string` rejects None. A non-string compared against an enum failed the original
condition rather than erroring, since `42 in ['asc', 'desc']` is false, which is
why an enum reports only the membership.
"""

import importlib.util
from pathlib import Path


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


BOOLEAN = "boolean"
INTEGER = "integer"
STRING = "string"
ENUM = "enum"

ASSET_ORDERS = ("asc", "desc")

# The response contract, scope by scope. Every entry here is required; anything
# absent from the table is ignored rather than refused, so a new Immich field
# does not fail a run that never reads it.
SCOPES = {
    "albums": {"defaultAssetOrder": (ENUM, ASSET_ORDERS)},
    "cast": {"gCastEnabled": (BOOLEAN, None)},
    "download": {"archiveSize": (INTEGER, None),
                 "includeEmbeddedVideos": (BOOLEAN, None)},
    "emailNotifications": {"enabled": (BOOLEAN, None),
                           "albumInvite": (BOOLEAN, None),
                           "albumUpdate": (BOOLEAN, None)},
    "folders": {"enabled": (BOOLEAN, None), "sidebarWeb": (BOOLEAN, None)},
    "memories": {"enabled": (BOOLEAN, None), "duration": (INTEGER, None)},
    "people": {"enabled": (BOOLEAN, None), "sidebarWeb": (BOOLEAN, None),
               "minimumFaces": (INTEGER, None)},
    "purchase": {"showSupportBadge": (BOOLEAN, None),
                 "hideBuyButtonUntil": (STRING, None)},
    "ratings": {"enabled": (BOOLEAN, None)},
    "recentlyAdded": {"sidebarWeb": (BOOLEAN, None)},
    "sharedLinks": {"enabled": (BOOLEAN, None), "sidebarWeb": (BOOLEAN, None)},
    "tags": {"enabled": (BOOLEAN, None), "sidebarWeb": (BOOLEAN, None)},
}

ROOT_LABEL = "preferences"


def _field(errors, path, value, kind, allowed):
    if kind is BOOLEAN:
        if not _GUARDS.is_boolean(value):
            errors.append(f"{path}: must be a boolean")
    elif kind is INTEGER:
        if not _GUARDS.is_integer(value):
            errors.append(f"{path}: must be an integer")
    elif kind is STRING:
        if not _GUARDS.is_string(value):
            errors.append(f"{path}: must be a string")
    elif kind is ENUM:
        if not _GUARDS.is_string(value) or value not in allowed:
            errors.append(f"{path}: must be one of {', '.join(allowed)}")


def immich_preference_response_errors(response, label=ROOT_LABEL):
    """Return every violation in one Immich preference response, as field paths.

    Never includes a value, so the result is safe to print from the `fail_msg` of
    a task that runs under `no_log`. An empty list means Immich returned a
    document the role knows how to reconcile.
    """
    errors = []
    if not _GUARDS.is_mapping(response):
        return [f"{label}: must be a mapping"]

    for scope, fields in SCOPES.items():
        scope_path = f"{label}.{scope}"
        if scope not in response:
            errors.append(f"{scope_path}: is missing")
            continue
        scoped = response[scope]
        if not _GUARDS.is_mapping(scoped):
            errors.append(f"{scope_path}: must be a mapping")
            continue
        for field, (kind, allowed) in fields.items():
            field_path = f"{scope_path}.{field}"
            if field not in scoped:
                errors.append(f"{field_path}: is missing")
                continue
            _field(errors, field_path, scoped[field], kind, allowed)

    return errors


class FilterModule:
    """Expose the Immich preference response schema validator to Ansible."""

    def filters(self):
        return {"immich_preference_response_errors": immich_preference_response_errors}
