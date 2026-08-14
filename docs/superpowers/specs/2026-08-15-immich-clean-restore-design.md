# Immich Clean-Deployment Restore Design

## Problem

Immich originals are stored beneath `/volume2/Immich`, while its PostgreSQL
catalogue is stored beneath `/volume1/Docker/immich/postgres`. Immich does not
scan its internal upload/library folders to reconstruct a lost database. A
clean PostgreSQL directory paired with existing originals therefore produces a
healthy but empty application. The current role starts the full stack and
initializes a new administrator without detecting this split-brain state.

## Design

Before starting `immich-server`, the role will classify both sides of the
storage boundary:

- PostgreSQL is either absent/fresh or an existing initialized cluster.
- Immich originals are either absent or present under the internal `upload`
  and `library` trees.
- Database backups are discovered only in the declared
  `/volume2/Immich-backups/database` directory.

Normal initialization remains allowed when both the database and originals are
absent. An existing database is never restored over or replaced. When the
database is fresh and originals exist, deployment requires one newest safe,
valid backup and restores it before the application server starts. If no usable
backup exists, deployment stops with recovery guidance instead of initializing
an empty Immich instance.

Backup selection will reject symlinks, non-regular files, unsafe ownership or
permissions, unexpected names, invalid compression, and ambiguous newest
candidates. The database and Redis dependencies will start without
`immich-server`; the restore will use the pinned database container and the
configured database identity. A failed restore leaves an explicit protected
failure marker and keeps the application server stopped. A later run will not
treat that state as a valid existing installation.

After restore, the role will verify the expected Immich schema, a nonzero asset
count when originals were detected, and database references to readable source
files. Only then will it start the complete stack and continue the existing
administrator, user, onboarding, and settings reconciliation. Generated
thumbnails and machine-learning data remain regenerable and are not restore
preconditions.

## Safety and Idempotence

The restore path is restricted to a PostgreSQL cluster proven fresh during the
same convergence. It never deletes an existing cluster, never imports internal
Immich files as an external library, and never chooses an older backup merely
because a newer candidate failed validation. Secrets and filenames remain
redacted from Ansible output. Once a restore succeeds, subsequent convergence
uses the normal existing-database path.

## Verification

Unit and policy tests will cover storage classification, safe backup selection,
ambiguous or malformed backups, failure-marker behavior, and refusal to touch
an existing database. The Immich integration lane will create assets and a
database backup, remove only the disposable PostgreSQL state, redeploy, and
prove that the same asset IDs, checksums, users, settings, and readable
originals return. Negative scenarios will prove that existing originals with
no valid backup fail before `immich-server` starts.
