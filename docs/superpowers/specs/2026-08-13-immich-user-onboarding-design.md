# Immich Per-User Onboarding Reconciliation

## Problem

Immich 3.1.0 maintains two independent onboarding states. The platform already
sets the server-wide `system-metadata/admin-onboarding` state, but the web client
uses each authenticated user's onboarding metadata from the login response.
Freshly created administrator and managed-user accounts therefore receive
`isOnboarded: false` and are shown the first-login wizard.

## Supported API design

The role will use only Immich's supported authenticated user API. It will not
read or write Immich's database directly.

For the administrator and every configured `vault_managed_users.immich` entry,
the role will:

1. authenticate with that user's vault credentials;
2. read `GET /users/me/onboarding`;
3. validate the exact owned response shape before any onboarding mutation;
4. update only incomplete users with
   `PUT /users/me/onboarding` and `{"isOnboarded": true}`;
5. re-read every configured user's state and require `isOnboarded: true`.

All credential-bearing requests and derived tokens remain redacted. Existing
completed users are not mutated. The server-wide onboarding reconciliation
remains in place because it controls a separate Immich state.

## Failure and ordering contract

Authentication and response-schema preflight for all configured users must
complete before the first onboarding update. A missing user, rejected password,
duplicate normalized identity, malformed response, or unexpected API status
fails closed without partially updating later users. Updates are limited to the
single owned onboarding boolean through the self-service endpoint.

## Verification

Tests will prove the regression first: a fresh administrator and managed user
with no user-onboarding metadata must fail the current contract. Behavioral
fixtures will cover absent/false reconciliation, already-true idempotence,
multi-user preflight before mutation, malformed response rejection, and exact
read-back.

The static and live Immich contracts will authenticate the administrator and
every configured managed user, require `GET /users/me/onboarding` to return
exactly `{"isOnboarded": true}`, and continue to verify their existing settings
and non-administrator policies. The completed change will be exercised by a
new full fresh Mac proof that stops at the manual-validation handoff with the
services left running.
