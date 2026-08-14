# Immich Clean-Deployment Restore Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Recover volume2 Immich originals automatically from the newest safe matching database backup when a clean deployment finds that PostgreSQL state is absent.

**Architecture:** Classify host storage before starting PostgreSQL. If PostgreSQL is fresh but originals exist, select and validate one routine Immich backup, start only database/Redis, restore through the pinned PostgreSQL client while `immich-server` remains stopped, and verify database-to-file consistency before normal startup. Existing databases are never restored or replaced; originals without a valid backup fail closed.

**Tech Stack:** Python 3 standard library, Ansible Core, Docker Compose, PostgreSQL 14 client, Immich 3.1.0 backup format/API, unittest, Ruby/POSIX contracts.

---

## File structure

- Create `roles/immich/files/classify_restore.py`: safe storage classification and backup selection.
- Create `tests/immich_restore_classifier_test.py`: filesystem safety and selection tests.
- Create `roles/immich/tasks/restore.yml`: fresh-cluster restore, failure marker, and verification.
- Modify `roles/immich/tasks/main.yml`: preflight before data services and restore before application startup.
- Modify `services/immich/compose.yml`: mount the backup directory read-only in the database service.
- Modify `roles/immich/defaults/main.yml`: restore timing, marker, and supported filename contract.
- Modify `tests/contracts/immich.sh` and `tests/integration.sh`: static, negative, and full recovery proof.
- Create `tests/immich_restore_quality_test.rb`: mutation-protect restore ordering and fail-closed behavior.

### Task 1: Specify safe storage classification

**Files:**
- Create: `tests/immich_restore_classifier_test.py`

- [ ] **Step 1: Define the classifier output contract**

Invoke the helper with explicit PostgreSQL, media, backup, marker, expected UID, and expected GID paths/values. Require one JSON document shaped as:

```json
{
  "database": "fresh",
  "originalsPresent": true,
  "restoreRequired": true,
  "backupFilename": "immich-db-backup-20260815T010000-v3.1.0-pg14.19.sql.gz"
}
```

The only database values are `fresh` and `existing`; the filename is null unless restore is required.

- [ ] **Step 2: Cover the decision matrix**

Test empty database/empty originals, empty database/existing originals, existing database/empty originals, and existing database/existing originals. An existing database must always return `restoreRequired: false` and must not inspect backup content deeply enough to block normal deployment.

- [ ] **Step 3: Cover backup safety**

Accept only routine filenames matching Immich 3.1.0's format:

```text
immich-db-backup-YYYYMMDDTHHMMSS-vVERSION-pgVERSION.sql.gz
```

Reject symlinks, non-regular files, traversal, wrong owner, group/world-write bits, empty files, invalid gzip streams, trailing gzip junk, uploaded/restore-point/tmp/SQL-only names, and two candidates with the same newest timestamp. If the newest named candidate is unsafe, fail instead of falling back to an older file.

- [ ] **Step 4: Cover marker and traversal behavior**

Require immediate failure for a present restore-failure marker, symlinked roots, permission-denied traversal, or special files under `upload`/`library`. Stop scanning originals at the first safe regular file so a large library remains cheap.

- [ ] **Step 5: Run RED and commit**

```bash
python3 -m unittest -v tests/immich_restore_classifier_test.py
```

Expected: nonzero because the classifier does not exist.

```bash
git add tests/immich_restore_classifier_test.py
git commit -m "test: specify Immich restore preflight"
```

### Task 2: Implement the fail-closed classifier

**Files:**
- Create: `roles/immich/files/classify_restore.py`
- Modify: `roles/immich/defaults/main.yml`

- [ ] **Step 1: Implement descriptor-safe traversal**

Use `os.lstat`, `os.scandir`, `stat` predicates, and no-follow opens. Never follow a symlink. Treat a PostgreSQL directory with any entry as existing; host preparation's empty directory is fresh. Inspect originals only beneath `upload` and `library`.

- [ ] **Step 2: Select the newest backup by embedded UTC timestamp**

Parse the fixed timestamp, sort descending, reject ambiguity, then validate only the selected newest candidate. Fully consume the gzip stream in bounded chunks and reject decompression errors or an empty SQL stream. Return only the basename.

- [ ] **Step 3: Add defaults**

```yaml
immich_restore_failure_marker: "{{ nas_docker_root }}/immich/.restore-failed"
immich_restore_backup_container_path: /immich-backups
immich_restore_verify_limit: 25
```

- [ ] **Step 4: Run unit GREEN**

```bash
python3 -m unittest -v tests/immich_restore_classifier_test.py
```

- [ ] **Step 5: Commit classifier**

```bash
git add roles/immich/files/classify_restore.py roles/immich/defaults/main.yml
git commit -m "feat: classify Immich restore state safely"
```

### Task 3: Gate deployment before PostgreSQL initialization

**Files:**
- Modify: `roles/immich/tasks/main.yml`
- Modify: `services/immich/compose.yml`
- Modify: `tests/contracts/immich.sh`
- Create: `tests/immich_restore_quality_test.rb`

- [ ] **Step 1: Write static assertions first**

Require classifier execution before `Deploy the Immich data services`; JSON/schema assertions before any Compose mutation; a hard failure for originals without backup; and inclusion of `restore.yml` between data-service deployment and full `Deploy Immich`. Mutation tests must reject reordered preflight, ignored classifier failure, an existing-database restore path, or application startup before restore verification.

- [ ] **Step 2: Run the classifier without leaking paths or filenames**

Execute the copied helper with `ansible.builtin.command`/`argv`, `changed_when: false`, `check_mode: false`, and `no_log: true`. Parse JSON only after `rc == 0`, then assert exact keys/types. Produce a sanitized failure that says whether the blocker is unsafe storage, missing backup, ambiguous backup, or a previous failed restore.

- [ ] **Step 3: Refuse unrecoverable split-brain state**

Before Compose, assert that `database == 'fresh' and originalsPresent` implies a selected safe backup. Never create the administrator on this path unless restore succeeds.

- [ ] **Step 4: Mount backups read-only into PostgreSQL**

Add only:

```yaml
- ${NAS_MEDIA_ROOT:?}/Immich-backups/database:/immich-backups:ro
```

to the database service. Preserve the server's existing `/data/backups` mount. The database mount must remain read-only in every effective Compose variant.

- [ ] **Step 5: Run static GREEN and commit**

```bash
PATH="$PWD/.venv/bin:$PATH" tests/contracts/immich.sh static
PATH="$PWD/.venv/bin:$PATH" ruby tests/immich_restore_quality_test.rb
PATH="$PWD/.venv/bin:$PATH" ansible-playbook -i inventory/hosts.yml site.yml --syntax-check
```

```bash
git add roles/immich/tasks/main.yml services/immich/compose.yml tests/contracts/immich.sh tests/immich_restore_quality_test.rb
git commit -m "fix: gate Immich startup on restore preflight"
```

### Task 4: Restore and verify while the server is stopped

**Files:**
- Create: `roles/immich/tasks/restore.yml`
- Modify: `roles/immich/tasks/main.yml`
- Modify: `tests/contracts/immich.sh`

- [ ] **Step 1: Create the failure marker before mutation**

When `restoreRequired`, atomically write a mode-`0600` marker owned by NAS UID/GID before invoking `psql`. Its content contains only a version and sanitized stage. Remove it only after all restore verification passes. A killed or failed run therefore blocks automatic retry.

- [ ] **Step 2: Restore through the pinned database container**

Use `community.docker.docker_compose_v2_exec` against service `database`, `tty: false`, with an `argv` shell that supplies `PGPASSWORD` from the container environment and streams the selected read-only backup:

```sh
gzip -dc -- "/immich-backups/$1" |
  psql --host=database --username="$POSTGRES_USER" --dbname="$POSTGRES_DB" \
    --single-transaction --set=ON_ERROR_STOP=on
```

Pass the validated basename as `$1`; never interpolate it into shell source. Keep task output `no_log: true`. On failure, update only the marker stage and stop.

- [ ] **Step 3: Verify restored schema and file references**

Before starting `immich-server`, query PostgreSQL read-only to require:

- the Immich migrations/schema marker exists;
- at least one non-deleted asset exists when originals were detected;
- a bounded sample of non-deleted asset IDs and original paths has safe absolute `/data/...` paths;
- each sampled path maps beneath the declared volume2 Immich root and is a readable regular file without symlink traversal.

Use a JSON-returning SQL query and a separate no-follow filesystem helper path. Do not modify application tables.

- [ ] **Step 4: Remove marker and continue normal convergence**

Only after schema/count/path checks succeed, remove the marker, start the complete stack, require `/server/config` to report initialized, then run the existing administrator, user, onboarding, password, and settings reconciliation. A restored database reporting uninitialized is a hard failure, not permission to create an empty administrator.

- [ ] **Step 5: Add check-mode reporting**

For a required restore, report `IMMICH_PLAN_DATABASE_RESTORE` without starting containers, creating markers, or reading secret content.

- [ ] **Step 6: Run focused checks and commit**

```bash
PATH="$PWD/.venv/bin:$PATH" tests/contracts/immich.sh static
PATH="$PWD/.venv/bin:$PATH" ruby tests/immich_restore_quality_test.rb
PATH="$PWD/.venv/bin:$PATH" ansible-playbook -i inventory/hosts.yml site.yml --syntax-check
```

```bash
git add roles/immich/tasks/restore.yml roles/immich/tasks/main.yml tests/contracts/immich.sh
git commit -m "feat: restore Immich catalog before startup"
```

### Task 5: Prove real asset recovery and refusal cases

**Files:**
- Modify: `tests/contracts/immich.sh`
- Modify: `tests/integration.sh`
- Modify: `tests/validate-policy.sh`
- Modify: `tests/policy_test.rb`

- [ ] **Step 1: Create a real recovery fixture**

In the disposable media lane, upload multiple distinct assets, record their IDs/checksums/original bytes plus users/settings, trigger Immich's database-backup job, and wait for exactly one valid completed routine backup in the declared backup directory.

- [ ] **Step 2: Simulate only database loss**

Stop the disposable Immich stack, move its PostgreSQL directory to a test-owned quarantine path, recreate the empty managed directory, and leave volume2 originals/backups untouched. Redeploy through the normal role.

- [ ] **Step 3: Verify identity, not just counts**

Require the same asset IDs, checksums, downloadable original bytes, users, administrator, settings, onboarding/password state, and readable host files. Require the failure marker absent and a second convergence idempotent.

- [ ] **Step 4: Add negative scenarios**

In isolated disposable roots, prove deployment stops before `immich-server` for originals with no backup, invalid newest gzip, ambiguous newest timestamps, unsafe permissions, and a prior failure marker. Prove an existing PostgreSQL cluster is never restored even when a newer backup exists.

- [ ] **Step 5: Register focused tests and run full verification**

Register both `python3 -m unittest -v tests/immich_restore_classifier_test.py` and `ruby tests/immich_restore_quality_test.rb` exactly once in `tests/validate-policy.sh`, and protect both registrations in `tests/policy_test.rb`. Then run:

```bash
python3 -m unittest -v tests/immich_restore_classifier_test.py
PATH="$PWD/.venv/bin:$PATH" ruby tests/immich_restore_quality_test.rb
PATH="$PWD/.venv/bin:$PATH" tests/contracts/immich.sh static
PATH="$PWD/.venv/bin:$PATH" tests/integration.sh --suite media
PATH="$PWD/.venv/bin:$PATH" tests/validate-policy.sh
git diff --check
```

Expected: all commands exit 0; the clean-database recreation restores the exact prior Immich catalogue.

- [ ] **Step 6: Commit the completed recovery proof**

```bash
git add tests/contracts/immich.sh tests/integration.sh tests/validate-policy.sh tests/policy_test.rb
git commit -m "test: prove Immich clean-deployment recovery"
```
