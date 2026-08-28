# NAS Controller Requests Bootstrap Design

## Problem

The production deployment poller checks out an eligible `main` revision and
synchronizes the checkout's managed virtual environment from
`controller-requirements.txt` before it starts Ansible. The media acquisition
foundation deployment reached preflight with that managed interpreter, but the
requirements file did not include `requests`. The preflight correctly refused
to continue because `community.docker` modules require `requests` in the Python
interpreter Ansible manages on the NAS.

The integration harness did not expose this dependency gap because it installs
its own separately pinned copy of `requests`.

## Design

`controller-requirements.txt` will pin `requests` at the same version used by
the integration harness. No poller control flow changes are needed: tooling
synchronization already runs after the candidate checkout and before the first
Ansible invocation. A newly merged revision will therefore install `requests`
into the existing NAS controller virtual environment before vault validation,
preflight, or host mutation begins.

The preflight assertion remains fail-closed. It continues to prove that the
managed interpreter can import `requests`, catching incomplete or failed
tooling synchronization before Docker tasks run.

Renovate will track the controller and integration pins as the same PyPI
dependency. A policy regression will require both pins to exist and match so a
future dependency update cannot restore the split-brain state.

## Failure and Recovery Behavior

If pip cannot install the candidate's controller requirements, the poller stops
during tooling synchronization and records a bounded deployment failure. If
installation succeeds but the import still fails, preflight stops without host
mutation and reports the effective interpreter.

The failed foundation merge SHA remains quarantined. After this fix is merged,
the new `main` merge SHA is independently eligible; its tooling synchronization
repairs the virtual environment automatically, so the failed SHA does not need
to be retried.

## Verification

The implementation will first add a failing regression that compares the
`requests` pin in `controller-requirements.txt` with
`tests/integration.sh`. After adding the controller pin and Renovate coverage,
the focused dependency and production-poller tests, repository policy suite,
and Ansible syntax checks must pass. The published PR must contain no
`Co-Authored-By` trailer.
