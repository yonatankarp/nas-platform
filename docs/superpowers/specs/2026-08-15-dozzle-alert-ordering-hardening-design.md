# Dozzle Alert Ordering and Relay Hardening Design

## Goal

Make the private Dozzle alert relay resilient to concurrent, out-of-order webhook
delivery while reducing its filesystem privileges and strengthening readiness and
upstream-token handling. Existing authentication, notification rendering, and
unhealthy/recovery publication semantics remain unchanged except where event
ordering requires suppressing a stale notification.

## Durable ordered state

State schema version 2 stores a canonical list sorted by identity. Each entry has
exactly `identity`, `state`, and `timestamp`; `state` is `healthy` or `unhealthy`.
Only health events participate in per-identity ordering. OOM and unexpected-exit
events continue to publish without changing an identity's health state.

RFC3339 timestamps use the exact UTC `Z` form already accepted by the relay,
including one to nine fractional-second digits. Validation produces an integer
nanosecond ordering key without floating-point conversion. For each identity:

- An older health event is ignored without publication or state change.
- At equal timestamps, Recovery wins over Unhealthy regardless of arrival order.
- Repeated equal-time Unhealthy may republish when no equal-time healthy entry
  already wins, preserving the existing repeat-alert behavior.
- Repeated or startup healthy events do not publish, but a newer startup healthy
  event persists a tombstone so an older Unhealthy cannot revive stale state.

Version 1 unhealthy-set files are parsed without discarding identities. Each
identity receives the minimum supported timestamp and remains unhealthy. The next
accepted event atomically writes version 2; migration follows normal upstream
commit ordering when that event publishes.

## Bounds and retention

Healthy tombstones older than 30 days relative to the relay's trusted current UTC
wall clock are removed during accepted-event state reconciliation. If more
trimming is required, healthy tombstones are removed deterministically by
`(timestamp, identity)` until the state has at most 128 entries and serializes to
at most 64 KiB. Unhealthy entries are never evicted. If unhealthy entries alone
exceed either hard bound, the request fails closed before publication.

## Filesystem isolation and readiness

Before any child-path mutation, the role inspects
`${DOZZLE_STATE_ROOT}/alert-relay` without following links. An existing child
must be a real directory with the expected managed ownership and no group/world
write permission; symlinks and special files fail closed. Only after that gate
may the non-following file task converge the child to the NAS UID/GID and mode
`0700`. Compose mounts only that subdirectory read-write at `/state`; the relay
cannot access Dozzle's `users.yml` or `notifications.yml`. Adoption uses the same
dedicated child under the selected legacy Dozzle root.

`GET /healthz` validates the state directory, lock file, and state file type,
ownership, permissions, size, and schema. It takes a nonblocking shared lock. A
valid lock held exclusively by an active request is considered ready immediately
after directory and lock-file safety are established; readiness never waits for
the publisher network call. After parsing an available state document, readiness
also dry-runs retention and hard-bound reconciliation using the trusted current
UTC clock. A parseable version-1 file whose version-2 expansion cannot fit is
therefore unavailable. Unsafe, corrupt, symlinked, or operationally unbounded
state returns 503.

Persisted identities require valid UTF-8 scalar data in both identity parts, and
every persisted field is type-checked before value comparison. All malformed
persisted values become `StateError`; they never escape as handler tracebacks.
State and lock leaf opens include `O_NONBLOCK` with `O_NOFOLLOW`, so FIFOs and
devices reach descriptor type rejection without hanging readiness or requests.
The subsequent `flock` behavior is unchanged.

## Strict event strings

Every JSON envelope string must encode as valid UTF-8 before relationship,
rendering, or state processing. JSON escape sequences that decode to unpaired
Unicode surrogates are rejected with the same fixed 400 response as other schema
errors, without upstream publication, state mutation, or traceback output.

## Upstream and atomic-write hardening

State replacements use randomized, exclusive temporary filenames in the already
validated state directory. Every error path closes and removes a created
temporary file. The ntfy client disables redirects, so the bearer token is never
forwarded to a redirect target; a redirect is an upstream failure and leaves
state unchanged.

## Verification

Real local HTTP tests cover ordering in both arrival orders, equal timestamps,
restart persistence, version 1 migration, retention and hard bounds, readiness
with safe/unsafe state and a held lock, randomized temporary cleanup, and redirect
rejection. Static and mutation contracts protect the dedicated child mount and
pre-mutation role preparation. An executable Ansible proof places the child path
as a symlink to a sentinel directory and verifies failure before the sentinel's
ownership, mode, or contents change. Existing Dozzle notification integration
continues to prove the real unhealthy-to-recovered path. Real FIFO fixtures prove
state and lock paths return fixed failures without blocking or side effects.
