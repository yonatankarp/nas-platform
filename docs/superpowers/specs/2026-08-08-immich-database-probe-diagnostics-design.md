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

## Testing

The Immich static contract will require the four bounded status values and
will reject diagnostic output that references the password or raw probe
streams. The existing disposable Linux convergence remains the end-to-end
test: its next failure must expose one safe category, after which the actual
platform defect can be fixed and verified in a subsequent run.

## Success Criteria

- CI and ADM operators receive an actionable failure category.
- Credentials and raw probe results remain redacted.
- Successful credential verification behaves exactly as before.
- The native-Linux CI lane passes before the PR is merged.
