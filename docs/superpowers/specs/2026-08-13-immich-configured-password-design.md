# Immich Configured-Password Reconciliation

## Problem

Immich 3.1.0 defaults newly created users to `shouldChangePassword: true` when
the creation request omits that field. The platform currently omits it, so a
configured managed user is forced into an interactive password-change screen
even though its vault password is already the intended durable password. The
same flag is also true for the freshly created vault administrator.

## Supported API design

The role will use only Immich's supported authenticated API. It will not read
or write Immich's database.

For managed users, the role will explicitly send `shouldChangePassword: false`
to `POST /api/admin/users` during creation. For both the vault administrator
and every configured managed user, reconciliation will use the v3
`PATCH /api/admin/users/{id}` endpoint with a minimal body containing
`shouldChangePassword: false` only when the authoritative admin user response
reports the flag as true.

The configured passwords will never be resent through the repair endpoint or
changed as part of this reconciliation. Managed users will remain
non-administrators, and the existing identity, credential, preference,
onboarding, and preservation checks will remain in force.

## Safety and ordering

Before the first password-policy mutation, the role will resolve and validate
the administrator and complete managed-user inventory. Every target must have
a unique stable ID, the expected normalized email and active status, and a
boolean `shouldChangePassword` field. Every managed target must also remain a
non-administrator. Unsupported, missing, duplicated, or malformed targets will
fail the batch before mutation.

After any minimal PATCH, the role will re-read the authoritative admin user
records and require `shouldChangePassword: false` for the administrator and
all configured managed users. Check mode will report the planned repair without
calling a mutating endpoint. Verification mode will be read-only.

## Verification and handoff

Tests will first demonstrate the current regression. Behavioral coverage will
include fresh creation, existing true-to-false repair, already-false
idempotence, all-target preflight, malformed/duplicate target rejection,
minimal PATCH bodies, no password mutation, exact read-back, check mode, and
read-only verification.

The live Immich contract will require login responses and authoritative admin
user reads to report `shouldChangePassword: false` for every configured
account. After the focused and policy suites pass, the current disposable Mac
sandbox will be cleaned up and a new full fresh proof will run to the manual
validation boundary with services left running.
