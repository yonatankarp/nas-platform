# Dozzle Contract Hardening Design

## Scope

Harden the implemented Dozzle service contract with executable proofs for
ambiguous managed identities, removal of surplus unmanaged notification state,
and truthful non-mutating Ansible check-mode reporting. Preserve the existing
pinned images, notification definitions, secret handling, exact convergence,
and full Mac lifecycle.

## Dynamic API fixtures

The existing `tests/contracts/dozzle.sh` Ruby driver remains the only component
that mutates pinned Dozzle API fixtures. New modes are orthogonal:

- Dispatcher duplicate modes create a second dispatcher with the managed name,
  store the created fixture ID, record all matching opaque IDs, prove the API
  contains the duplicate, and delete only the stored fixture ID during cleanup.
- Rule duplicate modes perform the same lifecycle for one managed rule name
  while the dispatcher identity is unique. This ensures the rule duplicate
  guard is reached instead of being hidden by the dispatcher guard.
- Surplus modes create a uniquely named unmanaged dispatcher and an unmanaged
  rule linked to it, store only their created IDs, prove both exist, then prove
  normal convergence removes both and restores the exact desired state.

IDs are opaque strings. Before they are written or printed, they must match an
allowlist suitable for a single identifier and must never be interpolated into
shell code. Contract output and expected-failure output may contain only these
safe IDs and fixed messages; response bodies, URLs, headers, credentials, and
vault values remain suppressed. Fixture cleanup refuses missing, malformed, or
ambiguous ownership artifacts and never deletes a managed original by name.

## Duplicate refusal

The role derives safe ID-only lists from the secret-bearing API results before
asserting uniqueness. Dispatcher and rule assertions reference only those
derived lists and report the conflicting IDs in their fixed failure messages.
The original API reads remain `no_log: true`. Linux integration creates each
duplicate independently, proves verification refuses it, proves convergence
refuses it while naming all safe IDs, validates expected-failure logs contain no
vault secret, then removes only the contract-created fixture.

## Surplus reconciliation

Surplus state is distinct from managed-name ambiguity. With exactly one managed
dispatcher and one instance of every managed rule, convergence deletes every
unmanaged rule before deleting unmanaged dispatchers. The contract verifies
the stored surplus IDs existed before convergence and are absent afterward,
then runs the existing exact desired-state verification.

## Check-mode planning

All API reads and authentication continue to execute in check mode with
`check_mode: false` and `changed_when: false`. All REST mutations remain guarded
by `not ansible_check_mode`; no POST, PUT, PATCH, or DELETE request executes
during `--check --diff`.

For each actual-state predicate used by a mutation, a separate secret-free
planned-change task runs only in check mode and reports `changed: true`:

- managed dispatcher POST;
- managed dispatcher PUT;
- managed rule POST;
- managed rule PUT;
- managed rule enabled-state PATCH;
- unmanaged rule DELETE;
- unmanaged dispatcher DELETE.

Messages contain only a fixed category and an allowlisted rule name or opaque
ID. Tasks that evaluate secret-bearing dispatcher configuration remain
`no_log: true`; their public planning task consumes only a derived boolean.
Resolution facts tolerate an absent managed dispatcher in check mode so rule
planning can continue without pretending a dispatcher was created.

## Check-mode acceptance

Two fixtures cover mutually exclusive actual states:

1. Mixed drift keeps the managed dispatcher present, changes dispatcher fields,
   changes a managed rule and its enabled state, removes one managed rule, and
   adds a surplus dispatcher and rule. It exercises dispatcher/rule PUT, rule
   PATCH, managed-rule POST, and both DELETE plans.
2. Missing managed state removes managed rules followed by the managed
   dispatcher. It exercises managed dispatcher and rule POST plans.

Before each check run, the contract writes a canonical JSON snapshot containing
only the complete API state returned by Dozzle to a mode-owned private artifact.
After `--check --diff`, the contract fetches and canonicalizes the state again
and requires exact byte equality. The shell acceptance also requires an
Ansible recap with `changed` greater than zero, runs verification-only and
requires refusal, then runs normal convergence and exact verification.

Linux integration executes duplicate, surplus, mixed-drift, and missing-state
scenarios with explicit markers. The Mac drift hook runs the mixed-drift
snapshot/check/refusal sequence; the existing reconcile phase performs normal
repair and its verification/notification hooks prove restored behavior.

## Acceptance

- Every new contract mode is executable against Dozzle v10.6.14.
- Duplicate convergence refusal exposes only safe opaque IDs.
- Surplus state is deleted without weakening duplicate refusal.
- Drifted check mode reports planned changes and preserves exact API state.
- Verification refuses every drift fixture before normal repair.
- Focused contracts, policy/mutation gates, full Linux integration, and a fresh
  committed Mac lifecycle pass.
- The final unpushed commit retains subject `feat: manage Dozzle alerting` and
  has no co-author trailer.

## Quality-review hardening

The final proof must distinguish evidence from orchestration artifacts. Ansible
task headers are not evidence that a loop predicate executed, because Ansible
prints a header even when every item skips. Each of the seven planning tasks
therefore emits one fixed, secret-free marker per actual planned mutation. The
contract counts every marker: mixed drift expects dispatcher repair, one rule
create, one rule repair, one enabled-state repair, one unmanaged rule removal,
and one unmanaged dispatcher removal; missing state expects one dispatcher
create and four rule creates, with zero occurrences in every other category.

The Mac drift hook verifies Dozzle in isolation with `verify.yml` and the
`platform_verify_dozzle` tag. It requires a fixed Dozzle dispatcher-drift
diagnostic, so pre-existing Beszel drift cannot satisfy the proof. Secret-bearing
state comparison remains under `no_log`; a derived boolean feeds a public fixed
assertion. Dispatcher relationships are compared as opaque normalized strings,
never integers.

The hook owns two temporary logs and the mixed fixture after creation. A
validated cleanup function unlinks one regular, non-symlink report-root file per
call for BSD portability. Normal success deletes both raw logs while deliberately
leaving the mixed fixture for lifecycle reconciliation. Any command failure,
assertion failure, HUP, INT, or TERM first invokes the exact owned fixture
recovery mode, then cleans both logs, and exits nonzero (129, 130, or 143 for
signals). Executable shell regression tests cover the former false-positive,
marker counts despite present task headers and a positive recap, successful log
cleanup, failure recovery, and signal recovery. Contract diagnostics remain
fixed messages and never interpolate API/template/notification bodies.
