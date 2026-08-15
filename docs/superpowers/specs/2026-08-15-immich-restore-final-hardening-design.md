# Immich Restore Final Hardening Design

## Goal

Close the remaining restore safety gaps in selective Immich role execution,
cache reset, native Mac ownership, backup compatibility, and crash marker
serialization without weakening existing clean-restore or adoption guarantees.

## Runtime helper integrity

The tracked `services/immich/classify_restore.py` controller file is the trust
anchor. Before each deployed helper execution, the role validates the controller
source as a regular file with mode `0644`, computes its SHA-256 without trimming
bytes, and validates the deployed file using a non-following remote stat. The
deployed helper must exist, be a regular non-symlink file, have mode `0644`, and
have the exact controller checksum.

This check is a reusable task include placed immediately before both helper
executions: initial storage classification and restored-asset verification. It
therefore applies to selective `--tags immich` runs without relying on the
deployment bundle role having executed in the same play. A missing, tampered, or
mode-drifted helper fails before Python is invoked and reports only a fixed
sanitized diagnostic.

## Protected Redis reset

The restore path starts database and Redis dependencies and waits for health,
then enters the protected restore block. Its first stage is `redis-reset`. The
role executes `redis-cli --raw flushall` inside the Redis service with argv,
redacts command details, and accepts only return code zero, empty stderr, and
stdout exactly `OK` after removing the command newline. Any other result enters
the existing rescue path and retains a sanitized JSON marker identifying the
`redis-reset` stage. SQL restore and full server startup cannot occur first.

The disposable integration path stops the application and database services but
does not remove or recreate Redis. It preseeds a real stale cache key before the
PostgreSQL directory is quarantined, performs the restore, and proves the key is
gone while the clean-restore asset contract still succeeds.

## Platform-aware ownership

Backup ownership expectations are derived from the effective platform. NAS and
Linux ownership-managed executions expect root-owned backup files (`0:0`),
matching the container-created files. Native Mac executions where Linux
ownership management is disabled use the connected Ansible user's UID and GID,
matching Docker Desktop bind-file ownership.

Marker writes follow the same policy boundary. NAS and ownership-managed runs
set the managed Linux UID/GID. Native Mac runs omit owner and group so Ansible
does not force foreign Linux identities onto host files. Adoption lifecycle
fixtures use these role defaults rather than overriding backup ownership and
prove marker creation, valid contents, retention, and removal.

## Backup compatibility

Canonical backup names continue to use:

`immich-db-backup-YYYYMMDDTHHMMSS-vVERSION-pgVERSION.sql.gz`

The parser captures the timestamp, Immich version, and PostgreSQL version.
Selection first determines the unique newest canonical timestamp. That exact
newest file must declare Immich version `3.1.0` and PostgreSQL major `14`, matching
the pinned Compose images. An incompatible newest file is refused with the fixed
diagnostic `incompatible-newest-backup`; the classifier never falls back to an
older compatible file. Existing databases remain outside backup selection.

The expected versions are public role defaults with argument specifications and
are passed explicitly to classification. Asset-verification mode does not accept
classification compatibility arguments.

## Marker format and lifecycle

Every marker is valid JSON followed by an actual newline. Marker documents have
exactly the schema `{"version":1,"stage":"<sanitized-stage>"}`. Initial marker
creation uses Ansible JSON serialization rather than a quoted string containing
the two literal characters backslash and `n`; rescue markers use the same
serialization path.

Lifecycle fixtures parse every marker observed after a protected failure, assert
the exact schema and integer version, and validate the expected stage. Successful
initialized restores remove the marker. SQL, Redis, startup, or initialization
failures retain it and prevent later restore or administrator mutation.

## Testing and failure boundaries

Tests are added before implementation and must fail specifically for each absent
boundary. Unit tests cover compatible and incompatible newest filenames.
Executable Ansible fixtures cover selective-role helper integrity and native
normal/adoption marker lifecycle. Static and mutation contracts reject reordered
Redis reset, missing helper verification, ambient trust paths, ownership drift,
compatibility bypass, and invalid marker serialization. Existing immutable
release packaging, Compose rendering, syntax, lint, focused restore contracts,
and the full registered policy suite remain green.
