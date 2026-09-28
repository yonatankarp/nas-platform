"""Schema validation for the preference documents Immich sends back.

Not `immich_preference_schema` (what the operator declares), and must not be
merged with it: here every field is required, unknown keys are accepted, and
only literal field paths are ever printed, never a value (the caller is no_log).
"""

import runpy
from pathlib import Path
from types import SimpleNamespace

from ansible.errors import AnsibleFilterError


# module_utils/ is run by file path, never via sys.path: tests/policy_test.rb
# says why, and fails any filter plugin that touches it.
_MODULE_UTILS = Path(__file__).resolve().parents[1] / "module_utils"
_GUARDS = SimpleNamespace(**runpy.run_path(str(_MODULE_UTILS / "schema_guards.py")))


BOOLEAN = "boolean"
INTEGER = "integer"
STRING = "string"
ENUM = "enum"

ASSET_ORDERS = ("asc", "desc")

# Every entry is required; fields absent from the table are ignored, so a new
# Immich field does not fail a run.
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
    # `==`, not `is`, and an `else` that refuses an unknown kind (#648).
    if kind == BOOLEAN:
        if not _GUARDS.is_boolean(value):
            errors.append(f"{path}: must be a boolean")
    elif kind == INTEGER:
        if not _GUARDS.is_integer(value):
            errors.append(f"{path}: must be an integer")
    elif kind == STRING:
        if not _GUARDS.is_string(value):
            errors.append(f"{path}: must be a string")
    elif kind == ENUM:
        if not _GUARDS.is_string(value) or value not in allowed:
            errors.append(f"{path}: must be one of {', '.join(allowed)}")
    else:
        # Safe to name: every kind here is a literal from SCOPES.
        raise AnsibleFilterError(f"{path}: unknown field kind {kind!r}")


def immich_preference_response_errors(response, label=ROOT_LABEL):
    """Return every violation in one Immich preference response, as field paths (never values)."""
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
