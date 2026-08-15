# Komga Healthcheck Design

## Problem

Komga has no Compose healthcheck. `docker compose up --wait` therefore treats a
running process as ready even when the application endpoint is not ready. The
runtime contract compensates with its own `/actuator/health` loop, leaving the
production deployment without the same readiness guarantee.

## Design

The Komga Compose service will receive a container-local healthcheck against
`http://127.0.0.1:25600/actuator/health`. The probe must require both HTTP
success and the exact JSON application status `UP`. Its interval, timeout,
retries, and startup grace will bound cold-start behavior without masking a
permanent failure.

The role will keep `docker compose up --wait` and add an explicit application
readiness check before claim, authentication, or library reconciliation. This
keeps the operational error at the service boundary and gives both Compose and
Ansible the same definition of readiness.

## Verification

Static contract tests will require the exact healthcheck and readiness task.
The real-service integration contract will assert that the container is marked
healthy before Komga API mutations begin. Existing claim, library scan,
playback, persistence, drift, and idempotence coverage remains unchanged.
