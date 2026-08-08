# Immich Database Probe Diagnostics Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Expose a bounded, secret-safe reason when Immich's PostgreSQL credential probe fails on native Linux or ADM.

**Architecture:** Run the bounded credential probe through Compose service
`database`, using `sh -ec` to source `PGPASSWORD` from the container's existing
`POSTGRES_PASSWORD` and pass only the managed username and database as positional
arguments. Keep the raw result under `no_log`, derive one of four non-sensitive
statuses in a separate fact, and make the public assertion report only that
status and the Compose service name. Extend the existing Immich static contract
before changing the role so the red/green cycle proves the exact probe controls,
diagnostic presence, and redaction.

**Tech Stack:** Ansible, Ruby contract assertions embedded in POSIX shell, Docker Compose, GitHub Actions

---

## Task 1: Contract the safe diagnostic boundary

**Files:**
- Modify: `tests/contracts/immich.sh`
- Test: `tests/contracts/immich.sh`

- [ ] **Step 1: Write the failing contract assertions**

After the existing `required_tasks.each` block, parse the role tasks and require the classifier and public assertion:

```ruby
role_tasks = YAML.safe_load_file(
  File.join(root, "roles", "immich", "tasks", "main.yml"),
  aliases: true
)
classifier = role_tasks.find do |task|
  task["name"] == "Classify the Immich database credential probe"
end
refuse("missing secret-safe database probe classifier") unless classifier
classifier_text = classifier.to_s
%w[execution-failed connection-rejected identity-mismatch verified].each do |status|
  refuse("database probe classifier omits #{status}") unless classifier_text.include?(status)
end
refuse("database probe classifier must remain redacted") unless classifier["no_log"] == true

assertion = role_tasks.find do |task|
  task["name"] == "Require the managed Immich database credential"
end
refuse("database credential assertion is absent") unless assertion
refuse("database credential assertion still censors its safe category") if assertion["no_log"] == true
assertion_text = assertion.to_s
refuse("database credential assertion omits the safe status") unless
  assertion_text.include?("immich_database_probe_status")
%w[vault_immich_db_password immich_database_identity stderr stdout].each do |secret_source|
  refuse("database credential assertion exposes #{secret_source}") if
    assertion_text.include?(secret_source)
end
```

- [ ] **Step 2: Run the Immich static contract and verify RED**

Run:

```bash
tests/contracts/immich.sh --platform nas static
```

Expected: exit 1 with `Immich contract failed: missing secret-safe database probe classifier`.

## Task 2: Derive and report a bounded probe status

**Files:**
- Modify: `roles/immich/tasks/main.yml`
- Test: `tests/contracts/immich.sh`

- [ ] **Step 1: Add the redacted classifier**

Insert this task immediately after `Refuse a rotated Immich database credential`:

```yaml
- name: Classify the Immich database credential probe
  ansible.builtin.set_fact:
    immich_database_probe_status: >-
      {% if immich_database_identity.rc is not defined %}
      execution-failed
      {% elif immich_database_identity.rc | int != 0 %}
      connection-rejected
      {% elif immich_database_identity.stdout | default('') | trim !=
              vault_immich_db_username ~ '/' ~ vault_immich_db_name %}
      identity-mismatch
      {% else %}
      verified
      {% endif %}
  when: not ansible_check_mode
  no_log: true
```

- [ ] **Step 2: Restrict the assertion to safe values**

Replace the assertion conditions and failure message with:

```yaml
- name: Require the managed Immich database credential
  ansible.builtin.assert:
    that:
      - immich_database_probe_status == 'verified'
    fail_msg: >-
      Immich database credential verification failed
      ({{ immich_database_probe_status }}) in container
      {{ immich_postgres_container }}. Restore the previous vault values or
      migrate the database credential explicitly, then rerun.
  when: not ansible_check_mode
```

Do not add `no_log` to the assertion. Its inputs are intentionally limited to the bounded status and non-secret container name.

- [ ] **Step 3: Run the Immich static contract and verify GREEN**

Run:

```bash
tests/contracts/immich.sh --platform nas static
```

Expected: exit 0 and `Immich static contract passed (nas)`.

- [ ] **Step 4: Run repository policy verification**

Run:

```bash
tests/validate-policy.sh
```

Expected: exit 0 with all policy and static contract checks passing.

- [ ] **Step 5: Review the exact patch**

Run:

```bash
git diff --check
git diff -- roles/immich/tasks/main.yml tests/contracts/immich.sh
```

Expected: no whitespace errors; the role exposes only the bounded status and container name.

- [ ] **Step 6: Commit the diagnostic implementation**

```bash
git add roles/immich/tasks/main.yml tests/contracts/immich.sh
git commit -m "fix: expose safe Immich database probe failures"
```

Do not add a `Co-Authored-By` trailer.

## Task 3: Remove the hidden target-side Docker API dependency

**Files:**
- Modify: `tests/contracts/immich.sh`
- Modify: `roles/immich/tasks/main.yml`
- Test: `tests/contracts/immich.sh`

- [ ] **Step 1: Write the failing Compose-exec contract**

After locating the database credential assertion in the embedded Ruby contract,
locate the probe and require the ADM-safe module and exact Compose inputs:

```ruby
probe = role_tasks.find do |task|
  task["name"] == "Refuse a rotated Immich database credential"
end
refuse("database credential probe is absent") unless probe
refuse("role must not use the Docker API exec module") if
  role.include?("community.docker.docker_container_exec")
compose_probe = probe["community.docker.docker_compose_v2_exec"]
refuse("database credential probe must use Compose exec") unless compose_probe
{
  "project_src" => "{{ platform_current_dir }}/services/immich",
  "project_name" => "{{ immich_compose_project_name }}",
  "files" => "{{ immich_compose_files }}",
  "env_files" => ["{{ platform_runtime_dir }}/services/immich/.env"],
  "service" => "database",
  "tty" => false
}.each do |field, expected|
  refuse("database credential Compose probe #{field} differs") unless
    compose_probe[field] == expected
end
refuse("database credential Compose probe must not supply host environment") if
  compose_probe.key?("env")
refuse("database credential Compose probe command differs") unless
  compose_probe["argv"] == [
    "sh",
    "-ec",
    "exec env PGPASSWORD=\"$POSTGRES_PASSWORD\" PGCONNECT_TIMEOUT=15 " \
      "psql --host=database --username=\"$1\" --dbname=\"$2\" " \
      "--no-align --tuples-only " \
      "--command=\"select current_user || '/' || current_database()\"",
    "immich-database-probe",
    "{{ vault_immich_db_username }}",
    "{{ vault_immich_db_name }}"
  ]
{
  "register" => "immich_database_identity",
  "when" => "not ansible_check_mode",
  "failed_when" => false,
  "changed_when" => false,
  "check_mode" => false,
  "no_log" => true
}.each do |field, expected|
  refuse("database credential Compose probe #{field} differs") unless
    probe[field] == expected
end
probe_text = probe.to_s
refuse("database credential Compose probe exposes the vault password") if
  probe_text.include?("vault_immich_db_password")
refuse("database credential Compose probe uses a host --env path") if
  probe_text.include?("--env")
```

Also require the public assertion to identify `Compose service database` and
reject the obsolete `immich_postgres_container` fact anywhere in the role.

- [ ] **Step 2: Verify the contract is RED**

Run:

```bash
tests/contracts/immich.sh --platform nas static
```

Expected: exit 1 because the probe still uses
`community.docker.docker_container_exec`.

- [ ] **Step 3: Replace Docker API exec with Compose CLI exec**

In `roles/immich/tasks/main.yml`, remove `immich_postgres_container` from the
Compose-selection fact and replace the raw probe module with:

```yaml
- name: Refuse a rotated Immich database credential
  community.docker.docker_compose_v2_exec:
    project_src: "{{ platform_current_dir }}/services/immich"
    project_name: "{{ immich_compose_project_name }}"
    files: "{{ immich_compose_files }}"
    env_files: ["{{ platform_runtime_dir }}/services/immich/.env"]
    service: database
    argv:
      - sh
      - -ec
      - >-
        exec env PGPASSWORD="$POSTGRES_PASSWORD" PGCONNECT_TIMEOUT=15
        psql --host=database --username="$1" --dbname="$2"
        --no-align --tuples-only
        --command="select current_user || '/' || current_database()"
      - immich-database-probe
      - "{{ vault_immich_db_username }}"
      - "{{ vault_immich_db_name }}"
    tty: false
  register: immich_database_identity
  when: not ansible_check_mode
  failed_when: false
  changed_when: false
  check_mode: false
  no_log: true
```

Update the safe assertion message to identify `Compose service database` rather
than a platform-specific container name. Preserve the classifier and all
redaction boundaries.

- [ ] **Step 4: Verify focused and repository tests are GREEN**

Run:

```bash
tests/contracts/immich.sh --platform nas static
python tests/immich_probe_status_test.py
ansible-lint --strict
tests/validate-policy.sh
git diff --check
```

Use the repository `.venv/bin` at the front of `PATH`. Expected: every command
exits 0.

- [ ] **Step 5: Commit the transport fix**

```bash
git add roles/immich/tasks/main.yml tests/contracts/immich.sh
git commit -m "fix: probe Immich database through Compose"
```

Do not add a `Co-Authored-By` trailer.

## Task 4: Verify native Linux and merge

**Files:**
- No source changes unless native-Linux evidence identifies another defect.

- [ ] **Step 1: Integrate and push the reviewed fix**

Run:

```bash
git -C /Users/yonatankarp-rudin/Projects/nas-platform merge --ff-only \
  agent/task-12-immich-diagnostics
git -C /Users/yonatankarp-rudin/Projects/nas-platform push origin \
  agent/task-12-immich
```

Expected: the PR branch fast-forwards to the reviewed diagnostics head and the
remote branch advances without rewriting history.

- [ ] **Step 2: Poll PR checks at 15-minute intervals**

Run:

```bash
gh pr checks 2 --watch --interval 900
```

Expected: either every required check passes, or `CI / validate` reports one of
`execution-failed`, `connection-rejected`, or `identity-mismatch` without
exposing a credential.

- [ ] **Step 3: Continue systematic debugging from the category**

If CI fails, list the PR checks, copy the failed GitHub Actions run ID from its
details URL, and inspect only that run's failed logs:

```bash
gh pr checks 2
gh run view <failed-run-id> --log-failed
```

Replace `<failed-run-id>` with the numeric run ID from the failed check. Use the
reported category to form one hypothesis and add a failing regression test
before changing production behavior. Do not merge while native-Linux CI is red.

- [ ] **Step 4: Merge only after fresh green verification**

When all checks pass, re-read the PR head SHA and check rollup, then merge PR #2 with the repository's permitted merge method and the expected head SHA. Verify the PR reports `MERGED` afterward.
