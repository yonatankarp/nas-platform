# Readable Stateful ntfy Alerts Design

## Problem

Dozzle currently posts an ntfy JSON envelope that the production endpoint is
storing as plain message text. The resulting iOS view exposes raw JSON. Its
`health_status` detail also omits whether the transition was healthy or
unhealthy, and the independent recovery rule emits a notification for every
normal startup transition.

## Design

A private alert relay will be added to the Dozzle stack. It will listen only on
the stack's internal network, require the existing write-only Dozzle bearer
token, validate a small versioned event schema, and publish to ntfy's JSON API.
Dozzle will send the relay the alert-rule name, container ID and display name,
host name, event name, health status, exit code, and timestamp. Unknown or
malformed payloads will be rejected rather than forwarded.

The relay will render ntfy messages with a short title, Markdown body, priority,
and tags. Examples are `Unhealthy · paperless_webserver`,
`Recovered · immich_server`, `Unexpected exit · service`, and
`Out of memory · service`. The body will identify the host and give the
specific state or exit code without embedding the source JSON.

The relay will persist only a set of unhealthy `(host, container-id)` keys.
An unhealthy event adds the key and is delivered. A healthy event is delivered
as recovery only if the key already exists, then removes it. Initial healthy
events are discarded. Unexpected exits and OOM events are always delivered.
State writes will use an atomic replacement in the existing protected Dozzle
data area. If state cannot be read safely, the relay will fail closed rather
than generate false recoveries.

The NAS ntfy service will continue using `NTFY_UPSTREAM_BASE_URL=https://ntfy.sh`
for iOS poll-request relay. Additional ntfy.sh account registration and mobile
client configuration are outside this change.

## Deployment and Security

The relay will run as the NAS UID/GID with `no-new-privileges`, a read-only root
filesystem, a small tmpfs, no published port, and the same bounded logging
policy as the other services. It receives no Docker socket access. Its source
and runtime configuration will be installed declaratively by the Dozzle role;
secrets remain in the rendered environment and are never logged.

## Verification

Unit tests will cover schema rejection, Markdown rendering, unhealthy-to-
recovery transitions, startup healthy suppression, duplicate recovery
suppression, atomic state persistence, and redaction. The Dozzle integration
contract will publish real unhealthy and healthy transitions and assert exact
ntfy title, message, Markdown, priority, and tags. It will also recreate the
stack to prove state persistence and retain the existing ACL proof that the
publisher token cannot read notification history.
