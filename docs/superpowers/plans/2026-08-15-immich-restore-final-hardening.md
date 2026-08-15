# Immich Restore Final Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fail closed on selective-role helper drift, clear stale Redis during restore, honor native Mac ownership, reject incompatible newest backups, and keep every restore marker valid JSON.

**Architecture:** Keep the classifier as the single service-owned runtime helper. Add a reusable Ansible integrity include before every helper execution, extend the classifier's canonical-name parser with explicit runtime compatibility inputs, and keep Redis reset plus marker updates inside the existing protected restore block. Derive host ownership once from platform facts and verify all boundaries with executable fixtures plus static mutation contracts.

**Tech Stack:** Ansible, Python 3 standard library, Ruby executable contracts, Docker Compose integration shell.

---

### Task 1: Backup compatibility contract

**Files:**
- Modify: `tests/immich_restore_classifier_test.py`
- Modify: `roles/immich/defaults/main.yml`
- Modify: `roles/immich/meta/argument_specs.yml`
- Modify: `roles/immich/tasks/main.yml`
- Modify: `services/immich/classify_restore.py`

- [ ] **Step 1: Write failing classifier tests**

Add `--expected-immich-version 3.1.0` and `--expected-postgres-major 14` to classification fixture argv. Add tests where the unique newest filename declares `v3.2.0` or `pg15.1`, plus an older compatible backup, and require only `incompatible-newest-backup` with no fallback.

- [ ] **Step 2: Verify RED**

Run: `python3 -m unittest -v tests/immich_restore_classifier_test.py`

Expected: failures because the new arguments are unknown and incompatible backups are still selected.

- [ ] **Step 3: Implement minimal compatibility parsing**

Capture timestamp, Immich version, and PostgreSQL version in `BACKUP_NAME`. Select the unique newest canonical candidate before compatibility validation. Compare exact Immich version and the PostgreSQL major component, then raise `Refusal("incompatible-newest-backup")` before gzip/ownership validation on mismatch. Add role defaults:

```yaml
immich_restore_expected_immich_version: "3.1.0"
immich_restore_expected_postgres_major: 14
```

Pass both arguments only in classification mode and register `str`/`int` argument specs.

- [ ] **Step 4: Verify GREEN**

Run: `python3 -m unittest -v tests/immich_restore_classifier_test.py`

Expected: all classifier tests pass with sanitized fixed output.

### Task 2: Selective role helper integrity

**Files:**
- Create: `roles/immich/tasks/verify_classifier.yml`
- Create: `tests/immich_selective_helper_integrity_test.rb`
- Modify: `roles/immich/tasks/main.yml`
- Modify: `roles/immich/tasks/restore.yml`
- Modify: `tests/immich_restore_quality_test.rb`
- Modify: `tests/validate-policy.sh`
- Modify: `tests/policy_test.rb`
- Modify: `tests/policy_manifest_test.rb`

- [ ] **Step 1: Write failing executable and mutation contracts**

Construct a real release helper plus a Python tripwire. Run only extracted Immich tasks and prove valid bytes execute once while a missing file, content tamper, symlink, or mode drift fails with a fixed helper-integrity message and leaves the tripwire untouched. Static mutations must reject removal of either include, a controller path not anchored at `playbook_dir`, checksum removal, symlink following, and mode relaxation.

- [ ] **Step 2: Verify RED**

Run:

```bash
ruby tests/immich_selective_helper_integrity_test.rb
ruby tests/immich_restore_quality_test.rb
```

Expected: failures because no per-execution integrity include exists.

- [ ] **Step 3: Implement reusable pre-execution verification**

Validate the controller source with local non-following stat, regular-file and `0644` assertions, and an exact no-trim SHA-256. Validate the deployed current helper through `ansible.builtin.stat` with `follow: false` and `checksum_algorithm: sha256`; assert existence, regular type, non-link status, mode `0644`, and checksum equality. Use only fixed sanitized failure text and place the include immediately before both command tasks.

- [ ] **Step 4: Verify GREEN**

Run the executable helper fixture, quality contract, immutable-release helper test, and policy registration contracts. Expected: all pass.

### Task 3: Protected Redis reset

**Files:**
- Modify: `roles/immich/tasks/restore.yml`
- Modify: `tests/immich_restore_quality_test.rb`
- Modify: `tests/immich_restore_lifecycle_test.rb`

- [ ] **Step 1: Write failing reset ordering and failure tests**

Require a protected `redis-reset` stage before SQL, argv execution against service `redis`, `redis-cli --raw flushall`, `no_log`, and exact `rc == 0`, empty stderr, `stdout | trim == 'OK'`. Extend the lifecycle fixture so reset failure retains a parsed marker with stage `redis-reset` and SQL/server/admin events never occur.

- [ ] **Step 2: Verify RED**

Run quality and lifecycle tests. Expected: missing Redis reset and marker-stage failures.

- [ ] **Step 3: Implement reset inside the protected block**

Set stage `redis-reset`, execute flushall with `failed_when: false`, then assert exact sanitized result before changing stage to `database-restore` and running SQL.

- [ ] **Step 4: Verify GREEN**

Run quality and lifecycle tests. Expected: all restore ordering and failure-boundary scenarios pass.

### Task 4: Native ownership and valid JSON markers

**Files:**
- Modify: `roles/immich/defaults/main.yml`
- Modify: `roles/immich/tasks/main.yml`
- Modify: `roles/immich/tasks/restore.yml`
- Modify: `tests/immich_restore_lifecycle_test.rb`
- Modify: `tests/immich_restore_quality_test.rb`

- [ ] **Step 1: Write failing native adoption lifecycle assertions**

Remove UID/GID fixture overrides, provide actual `ansible_facts.user_uid/user_gid`, and run native Mac with ownership management disabled. Parse every retained marker with `JSON.parse`, require exactly keys `version` and `stage`, integer version 1, expected stage, and an actual final newline. Assert marker ownership remains the native fixture user and successful initialized restores remove it.

- [ ] **Step 2: Verify RED**

Run lifecycle and quality tests. Expected: root backup defaults reject host-created backups, forced marker owner/group violates native policy, and the initial literal backslash-n marker is not valid JSON.

- [ ] **Step 3: Implement effective ownership and serialization**

Derive backup UID/GID from `ansible_facts.user_uid/user_gid` only for native Mac with ownership management disabled; otherwise use zero. For both copy tasks, use managed `nas_uid/nas_gid` only on NAS or ownership-managed hosts and `omit` otherwise. Serialize marker dictionaries with `to_json` and append a real YAML-block newline.

- [ ] **Step 4: Verify GREEN**

Run lifecycle and quality tests. Expected: normal and adoption native fixtures pass every marker transition and ownership assertion.

### Task 5: Disposable Redis integration and final verification

**Files:**
- Modify: `tests/integration.sh`
- Modify: `tests/immich_restore_quality_test.rb`
- Modify: `tests/validate-policy.sh` if new executable registration is required

- [ ] **Step 1: Write failing integration contract assertions**

Require the clean-restore lane to preseed a Redis key, stop only `immich-server`, `immich-machine-learning`, and `database`, avoid `compose down`, quarantine only PostgreSQL, then assert the stale key is absent after restore and run the asset survival contract.

- [ ] **Step 2: Verify static RED**

Run `ruby tests/immich_restore_quality_test.rb`. Expected: failure because the integration lane still removes Redis through `compose down` and does not assert stale-key removal.

- [ ] **Step 3: Implement the disposable restore flow**

Use `docker compose exec -T redis redis-cli --raw set ...` before stopping the three non-Redis services, verify the seed exists, quarantine PostgreSQL, run the selective role, and assert `exists` returns `0` before the existing clean-restore asset contract.

- [ ] **Step 4: Run focused verification**

Run classifier, quality, lifecycle, selective integrity, immutable-release, adoption baseline, policy/manifest, Ansible syntax/lint, normal/adoption Compose renders, and `git diff --check`.

- [ ] **Step 5: Run integration where available**

Run the focused disposable Immich restore lane if the harness supports selecting it. If unavailable, record the exact command/error and rely only on the executable Redis failure fixture plus static integration contract; do not touch production.

- [ ] **Step 6: Run full policy and commit**

Run `tests/validate-policy.sh` because the registry changes. Confirm exit zero, inspect the final diff, and commit without `Co-Authored-By` trailers.
