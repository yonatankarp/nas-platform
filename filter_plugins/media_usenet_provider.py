"""Shape validation for the operator-owned half of the Usenet provider (#298).

Host, port, connections and TLS are typed operator policy, not vault strings.
The rules accept only what SABnzbd stores unchanged, since a value it rewrites
would reconcile forever. Messages name fields only, never values.
"""

import re

# A bare lowercase hostname, as `ConfigServer.set_dict` stores it. Anchored at
# both ends because Jinja's `is match` anchors only at the start.
PROVIDER_HOST = re.compile(r"^[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?\Z")

# `OptionNumber` clamps both, so the accepted range is the stored range.
PROVIDER_PORT_RANGE = (1, 65535)
PROVIDER_CONNECTIONS_RANGE = (1, 500)

PROVIDER_KEYS = ("host", "port", "connections", "ssl")


def _is_undeclared(provider):
    """Whether this declares nothing (empty host), a valid state (#292)."""
    return provider.get("host") == ""


def media_usenet_provider_errors(value):
    """Return every shape violation in the operator-owned provider policy.

    Never includes a value or a comparand. An empty list means the declaration
    is one SABnzbd will store unchanged, or that there is no declaration.
    """
    if not isinstance(value, dict):
        return ["media_usenet_provider: must be a mapping"]

    errors = []
    missing = [key for key in PROVIDER_KEYS if key not in value]
    if missing:
        errors.append(f"media_usenet_provider: missing {', '.join(missing)}")
    unexpected = [str(key) for key in value if key not in PROVIDER_KEYS]
    if unexpected:
        errors.append("media_usenet_provider: unexpected "
                      f"{', '.join(sorted(unexpected))}")
    if errors:
        return errors

    if _is_undeclared(value):
        return errors

    host = value["host"]
    if not isinstance(host, str):
        errors.append("media_usenet_provider.host: must be a string")
    elif not PROVIDER_HOST.match(host):
        errors.append("media_usenet_provider.host: must be a bare lowercase "
                      "hostname, because SABnzbd stores nothing else unchanged")

    for key, (low, high) in (("port", PROVIDER_PORT_RANGE),
                             ("connections", PROVIDER_CONNECTIONS_RANGE)):
        number = value[key]
        # A boolean is an int in Python; reject it rather than clamp True to 1.
        if isinstance(number, bool) or not isinstance(number, int):
            errors.append(f"media_usenet_provider.{key}: must be an integer")
        elif not low <= number <= high:
            errors.append(f"media_usenet_provider.{key}: must be within the "
                          "range SABnzbd stores without clamping")

    if not isinstance(value["ssl"], bool):
        errors.append("media_usenet_provider.ssl: must be a boolean, because "
                      "SABnzbd parses a server flag with bool_conv(int_conv()) "
                      "and stores any other spelling as 0")

    return errors


class FilterModule:
    """Expose the operator-owned Usenet provider shape validator to Ansible."""

    def filters(self):
        return {"media_usenet_provider_errors": media_usenet_provider_errors}
