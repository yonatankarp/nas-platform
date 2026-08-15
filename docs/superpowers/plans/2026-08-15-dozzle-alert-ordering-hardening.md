# Dozzle Alert Ordering Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Dozzle health alert correlation durable under concurrent out-of-order delivery while isolating relay state and hardening readiness, atomic writes, and ntfy publishing.

**Architecture:** Replace the unhealthy-only state file with a canonical version-2 ordered health-entry list, retaining version-1 input migration. The relay compares exact RFC3339 nanosecond instants under its existing exclusive state lock, bounds healthy tombstones, exposes a nonblocking state-validating health probe, writes randomized temporary files, and refuses redirects. Compose mounts a role-managed dedicated state child instead of the Dozzle data root.

**Tech Stack:** Python 3.13 standard library, `unittest`, Docker Compose, Ansible, Ruby/POSIX contract tests.

---

## File structure

- Modify `services/dozzle/alert_relay.py`: timestamp ordering, state v2/migration, readiness, atomic temporary files, and redirect refusal.
- Modify `tests/dozzle_alert_relay_test.py`: real HTTP and filesystem regression coverage.
- Modify `services/dozzle/compose.yml` and `services/dozzle/compose.adoption.yml`: dedicated state-child mounts.
- Modify `roles/dozzle/tasks/main.yml`: prepare and validate the mode-0700 relay directory.
- Modify `tests/contracts/dozzle.sh`: protect the mount, role, timestamp template, and readiness contract.
- Modify `tests/dozzle_quality_test.rb`: mutation-protect against restoring the parent-root mount.
- Modify related Mac adoption binding expectations only where the effective Compose mount contract requires it.

### Task 1: Ordered version-2 state

**Files:**
- Modify: `tests/dozzle_alert_relay_test.py`
- Modify: `services/dozzle/alert_relay.py`

- [ ] **Step 1: Write failing ordering and migration tests**

Add real relay requests that send Recovery at `2026-08-15T01:22:14.000000001Z` before Unhealthy at `2026-08-15T01:22:13.999999999Z`, then assert no publish and a healthy version-2 entry. Cover equal timestamps with Recovery precedence, repeated equal Unhealthy publication, server restart using the same state file, and a private version-1 fixture migrating without losing unhealthy identity.

- [ ] **Step 2: Write failing retention and bound tests**

Patch the relay clock to a fixed UTC instant. Seed old and recent healthy entries plus unhealthy entries, then require only old healthy entries to be removed. Seed more than 128 entries and require deterministic oldest-healthy removal. Seed unprunable unhealthy data beyond the serialized limit and require `500 state unavailable` before any upstream request.

- [ ] **Step 3: Run RED**

```bash
python3 -m unittest -v tests.dozzle_alert_relay_test.DozzleAlertRelayTest.test_later_recovery_wins_when_older_unhealthy_arrives_late tests.dozzle_alert_relay_test.DozzleAlertRelayTest.test_version_one_state_migrates_without_discarding_unhealthy tests.dozzle_alert_relay_test.DozzleAlertRelayTest.test_healthy_tombstone_retention_is_bounded
```

Expected: failures because the current state is an unhealthy set and stale Unhealthy still publishes.

- [ ] **Step 4: Implement exact ordering and canonical state**

Use an integer nanosecond key derived from parsed UTC calendar fields. Store sorted entries shaped exactly as:

```json
{"version":2,"entries":[{"identity":"nas\u0000<id>","state":"healthy","timestamp":"2026-08-15T01:22:14.000000001Z"}]}
```

Treat version-1 identities as unhealthy at `0001-01-01T00:00:00Z`. Under the existing exclusive lock, ignore older events, let healthy win equal-time ties, preserve equal-time repeated-Unhealthy publishing, and commit state only after successful publication when publication is required.

- [ ] **Step 5: Implement deterministic bounds**

At accepted-event reconciliation, remove healthy entries older than `utc_now() - timedelta(days=30)`, then remove healthy entries ordered by parsed timestamp and identity until at most 128 entries and 64 KiB remain. Raise `StateError` before publication if remaining unhealthy entries exceed either bound.

- [ ] **Step 6: Run GREEN**

```bash
python3 -m unittest -v tests/dozzle_alert_relay_test.py
```

Expected: all relay tests pass.

### Task 2: Readiness, randomized replace, and redirect refusal

**Files:**
- Modify: `tests/dozzle_alert_relay_test.py`
- Modify: `services/dozzle/alert_relay.py`

- [ ] **Step 1: Write failing readiness tests**

Require `200 ok` for a safe absent or valid state, `503 state unavailable` for corrupt JSON, state symlinks, unsafe file mode, unsafe directory mode, or unsafe lock file, and a prompt `200` while another file descriptor holds the valid lock exclusively.

- [ ] **Step 2: Write failing atomic-name and redirect tests**

Patch `secrets.token_hex` so the first randomized name collides and the second succeeds; assert exclusive creation, no temporary leftovers, and mode `0600`. Point ntfy at a local redirector whose target records requests; require `502`, no state transition, and no request or bearer token at the target.

- [ ] **Step 3: Run RED**

```bash
python3 -m unittest -v tests.dozzle_alert_relay_test.DozzleAlertRelayTest.test_health_validates_state_without_waiting_for_an_active_lock tests.dozzle_alert_relay_test.DozzleAlertRelayTest.test_publish_refuses_redirects_without_forwarding_token
```

Expected: corrupt state still reports 200 and urllib follows the redirect.

- [ ] **Step 4: Implement nonblocking readiness**

Open and validate the exact-mode-0700 directory and any lock file without symlink following. Attempt `LOCK_SH | LOCK_NB`; on a valid contended lock return ready immediately, otherwise parse the state with the same strict reader used by event handling. Map `StateError` to HTTP 503.

- [ ] **Step 5: Implement hardened replace and publish**

Generate temporary names with `secrets.token_hex(16)`, retry exclusive collisions, and unlink only the name created by the current replace attempt. Publish through a `urllib` opener whose redirect handler returns no redirected request; treat every 3xx as `UpstreamError`.

- [ ] **Step 6: Run GREEN**

```bash
python3 -m unittest -v tests/dozzle_alert_relay_test.py
```

Expected: all relay tests pass without traceback or temporary artifacts.

### Task 3: Dedicated state-directory deployment contract

**Files:**
- Modify: `tests/contracts/dozzle.sh`
- Modify: `tests/dozzle_quality_test.rb`
- Modify: `services/dozzle/compose.yml`
- Modify: `services/dozzle/compose.adoption.yml`
- Modify: `roles/dozzle/tasks/main.yml`
- Modify: Mac adoption expectation tests identified by the failing focused contract.

- [ ] **Step 1: Change static and mutation tests first**

Require the base relay mount to be `${DOZZLE_STATE_ROOT:?}/alert-relay:/state`, the adoption mount to be `${PLATFORM_ADOPTION_ROOT:?}/legacy/dozzle/data/alert-relay:/state`, and the role to create and validate `{{ dozzle_state_root }}/alert-relay` as a nonsymlink directory owned by the runtime UID with mode `0700`. Add a mutation that replaces the child mount with the parent root and require static failure.

- [ ] **Step 2: Run Compose contract RED**

```bash
tests/contracts/dozzle.sh static
ruby tests/dozzle_quality_test.rb
```

Expected: failures naming the parent-root relay mount.

- [ ] **Step 3: Implement the least-privilege mount and role preparation**

Create the child directory before Compose deployment with NAS UID/GID ownership where Linux ownership is managed and mode `0700`; inspect it with `follow: false`; assert type, owner, and exact mode. Change normal and adoption relay mounts while keeping Dozzle on the parent `/data` mount.

- [ ] **Step 4: Update the dispatcher timestamp precision**

Change the Dozzle template layout to `2006-01-02T15:04:05.999999999Z07:00` and require that exact expression statically so source nanoseconds reach the relay.

- [ ] **Step 5: Run Compose contract GREEN**

```bash
tests/contracts/dozzle.sh static
ruby tests/dozzle_quality_test.rb
```

Expected: both pass, including effective adoption renders.

### Task 4: Full verification and intentional commit

**Files:**
- Verify all files changed in Tasks 1–3.

- [ ] **Step 1: Run local and pinned relay tests**

```bash
python3 -m unittest -v tests/dozzle_alert_relay_test.py
docker run --rm --network none -v "$PWD:/repo:ro" -w /repo docker.io/library/python:3.13-alpine@sha256:399babc8b49529dabfd9c922f2b5eea81d611e4512e3ed250d75bd2e7683f4b0 python3 -m unittest -v tests/dozzle_alert_relay_test.py
```

- [ ] **Step 2: Run repository checks**

```bash
tests/contracts/dozzle.sh static
ruby tests/dozzle_quality_test.rb
ruby tests/policy_test.rb
ansible-playbook -i inventory/local.yml site.yml --syntax-check
ansible-lint --strict
tests/integration.sh --suite dozzle
tests/validate-policy.sh
git diff --check
```

Expected: every command exits zero; integration remains disposable and never targets external ntfy.

- [ ] **Step 3: Self-review exact scope and commit**

Confirm only relay ordering/security, dedicated mount preparation, and their tests changed. Verify no secret value, production endpoint, Docker socket, published port, or `Co-Authored-By` was introduced, then commit with an intentional message such as:

```bash
git add services/dozzle roles/dozzle tests
git commit -m "fix: order and isolate Dozzle alert state"
```
