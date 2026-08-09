# CI Runtime Redesign

## Objective

Reduce pull-request feedback from roughly one hour to minutes without removing
the integration coverage that protects deployment safety, service contracts,
idempotence, and check mode.

Documentation-only and repository-metadata-only pull requests must not run
Ansible, Docker, lint, or integration work. They still produce the lightweight
required `validate` check because branch protection currently requires that
context; allowing the workflow to be skipped entirely would leave the pull
request permanently pending.

## Current behavior

The CI workflow has one serial `validate` job. Its disposable integration step
consumes more than 95 percent of the job and combines all of these concerns:

- deployment-boundary and unsafe-state refusal scenarios;
- a complete fresh platform converge;
- Beszel, Dozzle, and Audiobookshelf drift and duplicate-state scenarios;
- media and document fixture contracts;
- Paperless export, import, snapshot, restore, and recreation;
- a second complete converge for idempotence;
- a third complete converge in check mode.

Any changed commit repeats the whole sequence. Superseded pull-request runs are
not cancelled. Target containment also launches one Ansible command for every
path every time the validation is repeated.

## Selected architecture

### Required gate and change classification

The existing `validate` context remains the only branch-protection contract.
It always runs and depends on every job that the classifier selected. It fails
if any selected job failed or was cancelled and succeeds when all selected jobs
passed or were intentionally skipped.

A dependency-free repository script classifies the changed paths. The script
accepts a base and head revision, computes the changed-file list, and emits a
stable set of booleans for GitHub Actions. Its rules are also executable locally
with an explicit changed-file list so policy behavior can be tested without a
GitHub environment.

Classification is fail-safe:

- documentation and inert repository metadata select no expensive jobs;
- a service-owned path selects static checks, the shared smoke lane, and that
  service's integration lane;
- shared deployment, inventory, vault, workflow, test harness, dependency, or
  unknown paths select every lane;
- pushes to `main`, scheduled runs, and manual runs select every lane.

The initial service lanes are `beszel`, `dozzle`, `audiobookshelf`, `media`, and
`paperless`. The `media` lane owns Komga, tinyMediaManager, Jellyfin, and Immich
contracts because those services share fixture trees and ordering constraints.

Documentation-only changes include `README.md`, `docs/**`, and other Markdown
files outside executable test fixtures. Repository metadata includes `LICENSE`,
`.gitignore`, and editor configuration. `AGENTS.md`, workflow files, dependency
manifests, inventory, and test documentation embedded in executable fixtures are
not inert and therefore select full CI.

### Parallel workflow

The workflow is decomposed into these jobs:

1. `changes` checks out enough history and emits lane selections.
2. `static` runs shell syntax, policy tests, cleanup tests, Ansible lint, and
   playbook syntax whenever executable or configuration paths changed.
3. `foundation` runs controller-cleanliness, symlink, containment, and stale
   deployment scenarios when shared infrastructure changed.
4. `smoke` performs one fresh selected-service converge for service changes and
   one full fresh converge for shared changes.
5. Service jobs run their owned drift, duplicate-state, fixture, and persistence
   contracts independently.
6. `idempotence-check` runs idempotence and check mode for the selected service
   scope, or the whole site for shared changes.
7. `validate` aggregates all job results and preserves the required context.

Jobs run on isolated GitHub-hosted runners. Each integration lane owns its
sandbox and Docker daemon, so fixed ports and project names do not conflict
between lanes. The existing integration lock remains useful within a runner.

The workflow adds pull-request concurrency keyed by pull-request number and
cancels superseded runs. Push, schedule, and manual runs use their Git ref as the
concurrency key.

### Integration harness interface

The integration harness gains explicit suite selection instead of inferring
behavior from positional Ansible arguments. Supported suites are focused and
composable:

- `foundation`
- `smoke`
- `beszel`
- `dozzle`
- `audiobookshelf`
- `media`
- `paperless`
- `idempotence-check`
- `full`

`full` preserves the current complete behavior for main, nightly, manual, and
shared-platform validation. A service suite creates only the services and
dependencies required by that suite. Common sandbox creation, vault generation,
cleanup, and Ansible argument construction remain shared helpers.

Unknown suite names fail before creating or mutating Docker state. Cleanup runs
on success, failure, and cancellation.

### Containment optimization

The deployment target validator retains its existing security assertions and
its placement immediately before sensitive mutations. Instead of an Ansible
loop that starts one Python module invocation per path, one invocation receives
the complete path list as JSON and validates every path internally.

Failure output identifies the exact rejected path and reason. Tests cover safe
paths, lexical escape, canonical escape, forbidden symlinks, allowed deployment
pointers, and the current-release requirement. This changes process granularity,
not the safety model.

## Trigger policy

| Event or change | Required work |
|---|---|
| Markdown/docs/metadata only | `changes`, then lightweight `validate` |
| One service only | `changes`, `static`, `smoke`, service lane, scoped idempotence/check, `validate` |
| Multiple services | Union of their lanes plus shared jobs |
| Shared deployment/inventory/tests/workflows/unknown | Every lane |
| Push to `main` | Every lane |
| Nightly schedule | Every lane |
| Manual dispatch | Every lane |

No third-party path-filter action is introduced. The classifier is repository
code with repository tests, avoiding a new supply-chain dependency and making
the policy reproducible locally.

## Testing strategy

Path-classifier tests use temporary Git repositories and explicit file lists to
prove:

- documentation-only and metadata-only changes select no expensive work;
- each service path selects only its lane and shared prerequisites;
- multiple services produce the union of their lanes;
- shared and unknown paths select everything;
- deleted and renamed files are classified by all relevant old and new paths;
- full events select everything regardless of paths.

Harness command-line tests prove valid suite dispatch, rejection of unknown
suites before Docker access, and cleanup behavior. Existing service contract
tests remain the behavioral authority for each lane.

Containment tests run before and after the process-consolidation change and must
produce the same acceptance and refusal outcomes. Workflow validation checks
YAML parsing, job dependency integrity, the stable `validate` name, and result
aggregation for success, failure, cancellation, and intentional skips.

## Operational expectations

The target pull-request wall times are:

- documentation-only: seconds;
- typical single-service change: 5 to 10 minutes;
- Paperless-scale change: 8 to 15 minutes;
- shared-platform change: 15 to 20 minutes;
- complete nightly matrix: 15 to 20 minutes wall-clock, with comparable or
  moderately higher aggregate runner minutes because work runs in parallel.

Dependency caching and a prebuilt integration-runner image are intentionally
deferred. The measured installation work is under one minute and is not a
material first-order bottleneck.

## Rollout and safeguards

The rollout keeps `full` behavior available throughout. The classifier and
suite dispatch land with tests before the workflow begins relying on them. The
parallel workflow then keeps `full` on `main`, schedule, and manual events while
using selective lanes for pull requests.

If classification cannot determine a safe narrow scope, it selects all lanes.
If the aggregate gate sees an unexpected job result, it fails. These defaults
favor excess coverage over a false green build.
