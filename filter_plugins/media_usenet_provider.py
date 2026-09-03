"""Shape validation for the operator-owned half of the Usenet provider.

Four of the six values a Usenet subscription needs are not credentials: the
host is published by the provider, the port is 563 or 119, the connection
count is a subscription tier, and TLS is a protocol flag. Only the account
name and its password must not be disclosed. Those four therefore live in
`inventory/group_vars/all/main.yml` as ordinary operator policy beside
`media_arr_indexers`, and the `vault_` prefix -- which promises a reader that
a value is vault-authored -- is reserved for the two that are (#298).

The rules moved here unchanged from `vault_credential_schema`, because the
reason they exist has nothing to do with where the values are stored.

SABnzbd rewrites what it does not like. `ConfigServer.set_dict` lowercases and
strips the host, `OptionStr` strips the account name, and `OptionNumber` clamps
the port and the connection count into range. A value SABnzbd would rewrite can
never equal the value the platform declares, so `reconcile_sabnzbd.yml` would
compare the two, find them different and push the declaration again on every
run, for as long as it stood. These rules accept only what SABnzbd stores
unchanged.

The typing is the one thing that did change, and it is the point of the move.
Six vault strings could only ever be validated as strings, so the port arrived
as `"563"` and the TLS flag as `"1"`. Operator policy is typed YAML, so the
port and the connection count are integers and TLS is a boolean, which
`meta/argument_specs.yml` enforces natively before these rules are consulted.
A boolean also removes a foot-gun rather than restating it: SABnzbd parses a
server flag with `bool_conv(int_conv())`, so the string `"true"` is stored as
**0** and silently disables TLS on a connection that still appears to be
configured for it. The caller renders `| int`, and a boolean is the only thing
that can be rendered that way without a reader having to know any of this.

Following `vault_credential_schema` and `vault_managed_user_schema`, no message
carries a value or the literal a value was compared against, so the result is
safe to print from a `fail_msg` even though none of these four is secret. The
rule that keeps a diagnostic printable is that it names fields and nothing
else, and an exception for "this one is not really a secret" is how such a rule
stops holding.
"""

import re

# A bare lowercase hostname with no scheme, no port, no trailing dot and no
# underscore, which is what `ConfigServer.set_dict` stores unchanged. Anchored
# at both ends: `is match` anchors only at the start, and the rules here are
# consulted the same way whether they run in Python or through Jinja.
PROVIDER_HOST = re.compile(r"^[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?\Z")

# `OptionNumber` clamps both of these, so the accepted range is the stored
# range: a port in 1-65535 and a connection count in 1-500. Expressed as
# bounds rather than as the digit-pattern the vault strings needed, because an
# integer can be compared to an integer.
PROVIDER_PORT_RANGE = (1, 65535)
PROVIDER_CONNECTIONS_RANGE = (1, 500)

PROVIDER_KEYS = ("host", "port", "connections", "ssl")


def _is_undeclared(provider):
    """Whether this is a declaration of nothing rather than a bad declaration.

    An empty host is the undeclared state and the only shape in which the other
    three go unchecked, because a target that has not bought a subscription has
    no port, tier or TLS preference to state. It is the state every real target
    starts in, so it is valid rather than a failed converge (#292), and
    `downloaders_usenet_provider_declared` reads this same emptiness -- which
    is now readable without the vault password, where before it was not.
    """
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
        # Reporting a rule violation against a mapping of the wrong shape would
        # name a key the operator did not write, or miss one they did.
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
        # `isinstance(True, int)` is true in Python, and a boolean port is a
        # mistake rather than the number 1, so booleans are rejected here
        # instead of being clamped into range by accident.
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
