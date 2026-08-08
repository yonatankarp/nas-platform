# Immich Database Probe Diagnostics Design

## Goal

Make Immich's pre-deployment database credential check explain failures on
native Linux and ADM without exposing database credentials or raw module
results.

## Design

The existing PostgreSQL probe remains the authority and remains protected by
`no_log`. Immediately after it runs, the role derives a non-sensitive status
from its return code and output:

- `execution-failed` when Ansible could not execute the probe in the selected
  container;
- `connection-rejected` when `psql` ran but returned a non-zero status;
- `identity-mismatch` when the query succeeded but returned a different
  database user or database name;
- `verified` when the expected user and database are returned.

The assertion consumes only this status. Its failure message includes the
status and selected container name, but never the password, environment, raw
standard output, raw standard error, or complete registered result.

## Scope

This is part of the current Immich migration PR because it is required to
diagnose that PR's blocking native-Linux failure. It does not change database
credentials, retry policy, PostgreSQL state, or application schema.

## Confirmed Native-Linux Failure

The diagnostic classified the repeated CI failure as `execution-failed`:
`community.docker.docker_container_exec` never returned an exit code. That
module talks directly to the Docker API and requires Python's `requests`
library on the managed host. The dependency exists in the local Mac proof
environment but is not installed in the disposable Linux target and cannot be
assumed on ADM.

The credential probe will use `community.docker.docker_compose_v2_exec`
instead. This is the repository's established ADM-safe pattern: it drives the
Docker Compose CLI already required by deployment rather than adding a hidden
target-side Python dependency. It will select Compose service `database`, reuse
the same project name, Compose files and environment file as deployment, pass
the same secret `PGPASSWORD`, and disable TTY allocation so the identity query
has exact machine-readable output.

The role will no longer derive a platform-specific PostgreSQL container name
for this probe. Public failures will identify the stable Compose service
`database`; raw command output and credentials remain redacted.

## Testing

The Immich static contract will require the four bounded status values and
will reject diagnostic output that references the password or raw probe
streams. The existing disposable Linux convergence remains the end-to-end
test: its next failure must expose one safe category, after which the actual
platform defect can be fixed and verified in a subsequent run.

The contract will also reject `docker_container_exec` in the Immich role and
require `docker_compose_v2_exec` with service `database`, `tty: false`, and the
same project/files/environment inputs used by deployment. Native-Linux CI is
the authoritative end-to-end proof that the hidden Python dependency is gone.

## Success Criteria

- CI and ADM operators receive an actionable failure category.
- Credentials and raw probe results remain redacted.
- Successful credential verification behaves exactly as before.
- The native-Linux CI lane passes before the PR is merged.
