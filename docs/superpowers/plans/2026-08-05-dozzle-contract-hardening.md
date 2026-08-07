# Dozzle Contract Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prove Dozzle duplicate refusal, surplus cleanup, and non-mutating check-mode planning against the pinned API on Linux and Mac.

**Architecture:** Extend the existing Ruby-backed Dozzle contract with isolated fixture modes and private owned-ID/snapshot artifacts. Keep REST reconciliation in the Ansible role, derive secret-free planning predicates from read state, and expose one explicit check-mode change task per mutation category while every HTTP mutation remains skipped.

**Tech Stack:** POSIX shell, Ruby standard library, Ansible Core, `ansible.builtin.uri`, Docker Compose, Dozzle v10.6.14 API.

---

### Task 1: Establish static RED coverage

**Files:**
- Modify: `tests/contracts/dozzle.sh`
- Modify: `tests/policy_test.rb`
- Test: `tests/contracts/dozzle.sh`

- [x] **Step 1: Require the missing contract surfaces**

Extend the static contract to require these exact planned task names in
`roles/dozzle/tasks/main.yml`:

```ruby
planned_tasks = [
  "Report planned managed Dozzle dispatcher creation",
  "Report planned managed Dozzle dispatcher repair",
  "Report planned managed Dozzle alert rule creation",
  "Report planned managed Dozzle alert rule repair",
  "Report planned managed Dozzle alert rule enabled-state repair",
  "Report planned unmanaged Dozzle alert rule removal",
  "Report planned unmanaged Dozzle dispatcher removal"
]
planned_tasks.each do |name|
  abort "Dozzle contract failed: missing #{name}" unless role.include?("- name: #{name}")
end
```

Require Linux integration markers for duplicate dispatcher refusal, duplicate
rule refusal, surplus cleanup, mixed-drift check invariance, and missing-state
check invariance. Require the Mac drift hook to invoke the mixed snapshot and
snapshot-verification modes around `--check --diff`.

- [x] **Step 2: Run static tests and observe RED**

Run:

```sh
tests/contracts/dozzle.sh static
ruby tests/policy_test.rb
```

Expected: failure naming the first absent planned-change task and absent dynamic
proof markers.

- [x] **Step 3: Keep the RED assertions while implementing later tasks**

Do not weaken marker or task-name requirements. They become green only when the
role and executable orchestrators exist.

### Task 2: Add orthogonal API fixture modes and safe duplicate refusal

**Files:**
- Modify: `tests/contracts/dozzle.sh`
- Modify: `roles/dozzle/tasks/main.yml`
- Modify: `tests/integration.sh`
- Test: `tests/contracts/dozzle.sh`
- Test: `tests/integration.sh`

- [x] **Step 1: Add opaque-ID artifact helpers to the contract**

Implement a strict identifier boundary:

```ruby
SAFE_ID = /\A[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}\z/

def safe_id(value)
  id = value.to_s
  fail_contract("API returned an unsafe identifier") unless id.match?(SAFE_ID)
  id
end
```

Write mode-owned artifacts beneath `PLATFORM_REPORT_ROOT` with mode `0600`,
refuse symlink or non-regular replacements, and record only created fixture IDs
or sorted matching ID lists. Cleanup reads the stored created ID and sends a
DELETE for that exact endpoint; it never resolves deletion targets by name.

- [x] **Step 2: Implement dispatcher duplicate fixture modes**

Add modes that create one dispatcher with the managed name but fixed harmless
fields, verify exactly two matching safe IDs, and delete only the stored created
ID. The integration sequence is:

```sh
run_dozzle_contract duplicate-dispatcher-create
run_dozzle_contract duplicate-dispatcher-verify
if run_play --tags dozzle > /tmp/dozzle-duplicate-dispatcher.txt 2>&1; then
  exit 1
fi
run_dozzle_contract duplicate-dispatcher-assert-output /tmp/dozzle-duplicate-dispatcher.txt
/repo/tests/assert-no-vault-secrets.rb "$vault_file" "$vault_password_file" \
  /tmp/dozzle-duplicate-dispatcher.txt
run_dozzle_contract duplicate-dispatcher-cleanup
printf 'DOZZLE_DUPLICATE_DISPATCHER_REFUSED_WITH_SAFE_IDS\n'
```

- [x] **Step 3: Run dispatcher duplicate proof and observe RED**

Against a focused deployed sandbox, run the sequence above.

Expected: current convergence refuses the duplicate but its `no_log` assertion
does not expose the two safe IDs, so output assertion fails.

- [x] **Step 4: Derive and report only safe dispatcher IDs in the role**

Create `dozzle_managed_dispatcher_ids` from the secret-bearing API result, then
assert its length is at most one with fixed failure text containing only
`dozzle_managed_dispatcher_ids | join(',')`. Keep the API response task
`no_log: true`; do not include dispatcher bodies in public task output.

- [x] **Step 5: Implement and prove the orthogonal rule duplicate scenario**

Add corresponding `duplicate-rule-create`, `duplicate-rule-verify`, output
assertion, and owned-ID cleanup modes for `OOM`. Run them only after dispatcher
duplicate cleanup, so convergence reaches the rule uniqueness assertion. Derive
safe rule ID lists per managed rule in Ansible and emit only those IDs.

Expected GREEN markers:

```text
DOZZLE_DUPLICATE_DISPATCHER_REFUSED_WITH_SAFE_IDS
DOZZLE_DUPLICATE_RULE_REFUSED_WITH_SAFE_IDS
```

### Task 3: Prove surplus cleanup independently

**Files:**
- Modify: `tests/contracts/dozzle.sh`
- Modify: `tests/integration.sh`
- Test: `tests/integration.sh`

- [x] **Step 1: Add the missing-proof RED assertion**

Require `DOZZLE_SURPLUS_STATE_REMOVED` in the static integration contract and
run `tests/contracts/dozzle.sh static` before adding the sequence.

Expected: failure because no executable surplus marker exists.

- [x] **Step 2: Add surplus create/verify/removed modes**

Create a fixed uniquely named unmanaged dispatcher and one unmanaged rule linked
to it. Store each returned safe ID. `surplus-verify` requires both exact stored
IDs to exist. `surplus-removed` requires both IDs to be absent and deletes the
private artifacts; it never performs API cleanup by name.

- [x] **Step 3: Integrate normal convergence cleanup**

Run:

```sh
run_dozzle_contract surplus-create
run_dozzle_contract surplus-verify
run_play --tags dozzle
run_dozzle_contract surplus-removed
run_dozzle_contract verify
printf 'DOZZLE_SURPLUS_STATE_REMOVED\n'
```

Expected: unmanaged rule deletion precedes dispatcher deletion, and exact
verification passes without changing duplicate-refusal behavior.

### Task 4: Make API drift visible and immutable in check mode

**Files:**
- Modify: `roles/dozzle/tasks/main.yml`
- Modify: `tests/contracts/dozzle.sh`
- Modify: `tests/integration.sh`
- Modify: `tests/mac/hooks/drift/20-dozzle.sh`
- Test: `tests/contracts/dozzle.sh`
- Test: `tests/integration.sh`
- Test: `tests/mac/hooks/drift/20-dozzle.sh`

- [x] **Step 1: Add mixed and missing fixture/snapshot modes**

`check-mixed-create` changes managed dispatcher fields, changes `OOM` fields,
PATCHes `OOM` disabled, deletes `Recovery`, and creates surplus dispatcher/rule.
`check-missing-create` deletes all managed rules followed by the managed
dispatcher. Each mode stores a canonical JSON snapshot:

```ruby
JSON.generate(
  "dispatchers" => dispatchers.sort_by { |entry| safe_id(entry.fetch("id")) },
  "rules" => rules.sort_by { |entry| safe_id(entry.fetch("id")) }
)
```

The corresponding `*-unchanged` mode fetches current state and requires exact
byte equality with the private snapshot.

- [x] **Step 2: Demonstrate mixed-drift check RED**

Run mixed fixture creation, then `ansible-playbook --tags dozzle --check --diff`
and capture its recap. Run the unchanged snapshot check and verification-only.

Expected: state is unchanged and verify refuses, but current role reports no
API planned changes, so the acceptance fails its `changed>0` condition.

- [x] **Step 3: Add seven planning categories without API mutation**

For every existing mutation predicate, derive a boolean or safe ID list from the
read state. Add one `ansible.builtin.debug` task per approved category with
`changed_when: true` and `when: ansible_check_mode` plus that predicate. Keep
secret-bearing predicate derivation and values under `no_log: true`; planning
messages contain only fixed category text and allowlisted names/IDs.

Resolve an absent managed dispatcher as `{}` in check mode. Actual mutation
tasks remain guarded with `not ansible_check_mode`; normal creation resolves the
created response before rule reconciliation.

- [x] **Step 4: Prove mixed-drift GREEN and normal repair**

Require the check recap to match `changed=[1-9][0-9]*` and `failed=0`, run
`check-mixed-unchanged`, require verification-only failure, run normal
convergence, then exact verify. Emit:

```text
DOZZLE_CHECK_MIXED_PLANNED_IMMUTABLE_AND_REPAIRED
```

- [x] **Step 5: Prove missing-state POST planning GREEN**

Repeat the snapshot/check/refusal/normal-repair sequence with missing managed
state and emit:

```text
DOZZLE_CHECK_MISSING_PLANNED_IMMUTABLE_AND_REPAIRED
```

- [x] **Step 6: Integrate Mac mixed-drift acceptance**

In the Mac drift hook, create mixed drift and its snapshot, run the committed
site play with `--check --diff` to a private report artifact, require
`changed>0`/`failed=0`, run `check-mixed-unchanged`, then require `verify.sh` to
fail. Leave the drift in place for the lifecycle reconcile phase; after
reconcile, existing verify and real-notification hooks prove restoration.

### Task 5: Broad verification and final amendment

**Files:**
- Modify: `docs/superpowers/specs/2026-08-05-dozzle-contract-hardening-design.md`
- Modify: `docs/superpowers/plans/2026-08-05-dozzle-contract-hardening.md`
- Modify: all files listed in Tasks 1-4

- [x] **Step 1: Run focused static and dynamic proofs**

Run `tests/contracts/dozzle.sh static`, both duplicate scenarios, surplus
cleanup, mixed check/repair, and missing check/repair. Require every marker and
run `tests/assert-no-vault-secrets.rb` over expected-failure/check logs.

- [x] **Step 2: Run the complete policy gate**

Run `tests/validate-policy.sh` with pinned Ansible dependencies. Expected:
policy, mutation policy, Compose behavior, registry/contracts, Mac isolation,
phase status, report, cleanup, and sanitizer all pass.

- [x] **Step 3: Run full Linux integration**

Run `tests/integration.sh`. Expected: duplicate/surplus/check markers, registered
contracts, zero-change second run, and final check mode all pass.

- [x] **Step 4: Amend the commit and run fresh Mac lifecycle**

Amend the unpushed commit with exact subject `feat: manage Dozzle alerting`, no
body or co-author trailer. Generate an encrypted ephemeral vault outside the
repository and run every fresh Mac phase from preflight through cleanup at the
committed SHA. Require all report phases `passed`.

- [x] **Step 5: Final cleanup and evidence**

Remove owned sandboxes, containers, ephemeral vaults, and task scratch. Preserve
only the sanitized Mac report. Require `git diff --check`, empty
`git status --short`, exact commit subject, empty body, and no push.

### Task 6: Make planned-change evidence predicate-sensitive

**Files:**
- Modify: `roles/dozzle/tasks/main.yml`
- Modify: `tests/contracts/dozzle.sh`
- Modify: `tests/integration.sh`
- Test: `tests/contracts/dozzle.sh`

- [x] **Step 1: Write marker-count RED tests**

Create synthetic mixed and missing Ansible output containing every task header
and a positive recap. Require `assert-check-*-output` to reject a missing marker
even though the corresponding header remains, and require exact zero/nonzero
counts for all seven markers.

- [x] **Step 2: Emit one marker per true predicate**

Use the fixed markers `DOZZLE_PLAN_DISPATCHER_CREATE`,
`DOZZLE_PLAN_DISPATCHER_REPAIR`, `DOZZLE_PLAN_RULE_CREATE`,
`DOZZLE_PLAN_RULE_REPAIR`, `DOZZLE_PLAN_RULE_ENABLE_REPAIR`,
`DOZZLE_PLAN_RULE_REMOVE`, and `DOZZLE_PLAN_DISPATCHER_REMOVE` as the debug
messages. Do not add them to task names.

- [x] **Step 3: Replace header assertions with exact counts**

Mixed output must contain counts `0,1,1,1,1,1,1` in the order above; missing
output must contain `1,0,4,0,0,0,0`. Run both synthetic tests and the static
contract; expect GREEN.

### Task 7: Isolate and make the Mac drift hook fail-safe

**Files:**
- Modify: `tests/mac/hooks/drift/20-dozzle.sh`
- Create: `tests/mac/dozzle-drift-hook-test.sh`
- Modify: `tests/validate-policy.sh`
- Modify: `roles/dozzle/tasks/main.yml`
- Test: `tests/mac/dozzle-drift-hook-test.sh`

- [x] **Step 1: Write executable RED scenarios**

Run the hook in a disposable copied layout with controlled contract and Ansible
executables. Prove the current hook falsely passes when all-service verification
fails only for Beszel, retains raw outputs, fails to recover after an assertion,
and does not terminate/recover correctly for HUP, INT, and TERM.

- [x] **Step 2: Add a public fixed Dozzle refusal**

Derive the secret-bearing exact dispatcher comparison under `no_log`, then feed
only its boolean to a public assertion whose fixed diagnostic is `Dozzle ntfy
dispatcher is absent or drifted.` Compare rule dispatcher IDs with `| string` on
both operands.

- [x] **Step 3: Implement isolated verification and cleanup state machine**

Invoke committed `verify.yml --tags platform_verify_dozzle`, require the fixed
diagnostic, and never call all-service `verify.sh` from the Dozzle drift hook.
Validate and unlink one owned report file at a time. On ordinary failure recover
the mixed fixture and exit nonzero; on HUP/INT/TERM recover and exit 129/130/143.
On success remove logs and retain the fixture for reconcile.

- [x] **Step 4: Run focused hook GREEN tests**

Require success cleanup, false-proof rejection, assertion recovery, and all
three signal recovery cases to pass with an empty report directory.

### Task 8: Remove unsafe diagnostics and rerun all gates

**Files:**
- Modify: `tests/contracts/dozzle.sh`
- Modify: `tests/policy_test.rb`
- Modify: `docs/superpowers/specs/2026-08-05-dozzle-contract-hardening-design.md`
- Modify: `docs/superpowers/plans/2026-08-05-dozzle-contract-hardening.md`

- [x] **Step 1: Write diagnostic RED assertions**

Require fixed diagnostics for drift mismatch, dispatcher template mismatch,
webhook-test failure, webhook-delivery timeout, exit-fixture failure, and exit
notification timeout. Reject interpolated `.inspect`, response bodies,
notification bodies, counters, and raw subprocess stderr.

- [x] **Step 2: Replace raw diagnostics**

Retain the same predicates but emit only fixed safe messages. Run shell syntax,
static contracts, policy, mutation policy, and secret/sanitizer tests.

- [x] **Step 3: Run full runtime acceptance and amend**

Run full Linux integration, amend the existing unpushed commit with exact
subject `feat: manage Dozzle alerting` and an empty body, then run every fresh
Mac lifecycle phase at the committed SHA. Remove owned sandboxes, containers,
vaults, and task scratch; preserve only the sanitized Mac report and do not push.

---

Completed. Verified 2026-08-07 against the code rather than from memory: the
seven planned task names are present in the role, the seven `DOZZLE_PLAN_*`
markers are emitted there and counted by the contract, the five duplicate,
surplus and check-mode markers are driven by `tests/integration.sh`, and the
Mac drift hook carries its isolated check-mode proof. All of them pass in CI,
which now runs the full converge on Linux.
