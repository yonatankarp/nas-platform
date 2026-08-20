# Split Media CI Suites Design

## Goal

Replace the combined `media` integration lane with independent `komga`,
`tinymediamanager`, `jellyfin`, and `immich` suites while preserving every
existing service scenario, path-based selective routing, and the manual `full`
suite's broad end-to-end contract coverage.

## Motivation and Timing

The latest successful CI run for PR #57 spent about 16 minutes 43 seconds in
the combined `media` job. Initial convergence took roughly 7 minutes 33
seconds. The Komga, tinyMediaManager, and Jellyfin post-convergence contracts
then completed in about 18 seconds, while Immich's restore scenarios consumed
most of the remaining 8 minutes 44 seconds.

The combined lane therefore makes three comparatively short services wait for
Immich and makes a change to any one media service deploy and exercise all four.
Independent suites improve selective-run time, failure attribution, and service
ownership. Full CI events still select all four suites, so complete coverage is
retained. Parallel setup may increase aggregate runner minutes, but the expected
wall-clock critical path becomes the `immich` suite rather than a serial bundle
of unrelated services.

## Suite Model

The canonical CI lane and integration-suite order will be:

1. `foundation`
2. `smoke`
3. `beszel`
4. `dozzle`
5. `audiobookshelf`
6. `komga`
7. `tinymediamanager`
8. `jellyfin`
9. `immich`
10. `paperless`
11. `idempotence-check`

The `media` lane and suite will be removed. Each new service suite will use only
the shared prerequisites and its own service tag:

- `komga`: `host_prep,deployment_bundle,komga`
- `tinymediamanager`: `host_prep,deployment_bundle,tinymediamanager`
- `jellyfin`: `host_prep,deployment_bundle,jellyfin`
- `immich`: `host_prep,deployment_bundle,immich`

`smoke` and `idempotence-check` remain the only suites accepting classifier-
provided tags. All named service suites retain fixed tag plans.

## Change Classification and Workflow Contract

Changes under each service's role, Compose definitions, or integration contract
select that service's lane only, plus the existing `static`, `smoke`, and
`idempotence_check` lanes. Multiple service changes combine their suites in
canonical order. Shared, unknown, and full-event changes select every lane.
Documentation-only and other currently inert paths remain inert.

The workflow continues to use the classifier-produced JSON suite matrix. No
event-level path filter or third-party path-filter action will be introduced.
The aggregate `validate` job and the matrix dispatch shell contract remain
unchanged except for recognizing the new suite names through classifier output.

## Fixture Isolation

Host-side fixture preparation must occur before the controller container is
started because the service containers consume nested bind mounts through the
Docker daemon. Each selective suite will prepare only its own fixture:

- `komga` prepares the comic archive.
- `tinymediamanager` prepares its movie and episode files.
- `jellyfin` prepares its distinct Task 11 movie fixture directly.
- `immich` retains its existing fixture preparation within its contract flow.

The shared `PLATFORM_MEDIA_FIXTURES_PRESEEDED` state will be replaced for these
services by service-specific preseed variables. In particular, Jellyfin will
use `PLATFORM_JELLYFIN_FIXTURE_PRESEEDED`; its fixture path, bytes, setup, and
scenario dispatch will not depend on tinyMediaManager being present or running.
The manual `full` suite prepares all required host fixtures before deployment
and passes each service's own preseed state.

## Scenario Ownership

Each selective suite owns the scenarios previously executed inside `media`:

- `komga`: seed, scan/persistence proof, and normal runtime contract.
- `tinymediamanager`: seed, metadata/persistence proof, and normal runtime
  contract.
- `jellyfin`: seed, library/direct-play/transcode/persistence proof, and normal
  runtime contract.
- `immich`: clean-restore seed, clean restore, restore-negative matrix, and
  normal runtime contract.

The manual `full` suite preserves its current behavior: it seeds all normal
service contracts and executes the broad contract runner, but it does not
duplicate the expensive Immich clean-restore and negative-restore scenarios.
Full CI events do not rely on the manual `full` suite; the classifier selects all
four independent suites, including the complete `immich` suite.

## Failure Handling

Unknown or removed suite names continue to fail before Docker is invoked.
Passing `--tags` to a fixed service suite remains an error. Fixture preparation
must remain idempotent and reject drifted fixture bytes. A failure in one matrix
leg must not cancel other suites because the workflow retains `fail-fast: false`.

## Testing and Verification

Tests will be changed before production dispatch code so they first fail against
the combined lane. Coverage will include:

- classifier lane selection, canonical suite ordering, output serialization,
  multiple-service changes, full events, and selective tag plans;
- workflow matrix and argv contracts for all four suites;
- integration suite listing, descriptions, fixed-tag rejection, scenario
  dispatch, and pre-controller fixture preparation;
- explicit proof that Jellyfin has its own preseed variable and no ordering or
  fixture dependency on tinyMediaManager;
- absence of the retired `media` lane and suite.

Final verification will run the complete policy gate and all four Docker-backed
integration suites. Any environment, network, registry, or runtime limitation
will be reported with the exact failed command and available evidence.
