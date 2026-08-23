# tinyMediaManager Retirement Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop and remove the deployed tinyMediaManager container while preserving its critical state and all Movies/Series media, leaving permanent source and vault cleanup for a second release after NAS verification.

**Architecture:** Keep tinyMediaManager in the service manifest for one transitional release so the immutable deployment bundle still contains the exact Compose definition needed to remove the existing project. Replace its converging role with an idempotent retirement role that renders the legacy interpolation environment, executes Compose with `state: absent` and `remove_volumes: false`, and verifies the container is absent without mutating the bind-mounted state. Adapt the existing service contract and Mac hooks to start a representative legacy container before convergence, record a state sentinel, and prove that convergence removes only the container.

**Tech Stack:** Ansible Core, `community.docker.docker_compose_v2`, Docker Compose, Ruby and shell contract tests, repository Mac/integration harness.

---

## Scope boundaries

This is retirement release one. It deliberately retains:

- `services/tinymediamanager/` and its digest-pinned image;
- the `tinymediamanager` manifest, storage, CPU, port, CI-suite, and vault entries;
- `{{ nas_docker_root }}/tinymediamanager/data` and every media file;
- the role name and `platform_verify_tinymediamanager` tag.

The follow-up cleanup release removes those declarations only after the NAS has converged this release and verification confirms the container is absent and state is preserved. Open Subtitles is unrelated to this retirement and remains until Bazarr is proven.

### Task 1: Replace the active-service contract with a retirement contract

**Files:**
- Modify: `tests/contracts/tinymediamanager.sh`

- [ ] **Step 1: Replace the static assertions with retirement assertions**

Keep the shell entry point and safe repository-root resolution, but replace the current active-service Ruby assertions with this contract shape:

```ruby
tasks = YAML.safe_load_file(role_path, aliases: true)
retire = tasks.find { |task| task["name"] == "Retire tinyMediaManager without deleting state" }
abort "tinyMediaManager retirement contract failed: retirement task is absent" unless retire

compose = retire.fetch("community.docker.docker_compose_v2")
abort "tinyMediaManager retirement contract failed: project identity differs" unless
  compose.fetch("project_src") == "{{ platform_current_dir }}/services/tinymediamanager" &&
    compose.fetch("project_name") == "{{ tinymediamanager_compose_project_name }}" &&
    compose.fetch("files") == "{{ platform_service_compose_files['tinymediamanager'] }}"
abort "tinyMediaManager retirement contract failed: service is not removed" unless
  compose.fetch("state") == "absent"
abort "tinyMediaManager retirement contract failed: volumes may be deleted" unless
  compose.fetch("remove_volumes") == false
abort "tinyMediaManager retirement contract failed: orphan deletion is too broad" unless
  compose.fetch("remove_orphans") == false

active = tasks.any? do |task|
  task.dig("community.docker.docker_compose_v2", "state") == "present"
end
abort "tinyMediaManager retirement contract failed: role still starts the service" if active

mutates_state = tasks.any? do |task|
  module_name = %w[ansible.builtin.copy ansible.builtin.file ansible.builtin.template].find { |name| task.key?(name) }
  next false unless module_name
  payload = task.fetch(module_name).to_s
  payload.include?("tinymediamanager_state_root")
end
abort "tinyMediaManager retirement contract failed: role mutates preserved state" if mutates_state

inspection = tasks.find { |task| task["name"] == "Inspect the retired tinyMediaManager container" }
assertion = tasks.find { |task| task["name"] == "Require tinyMediaManager to remain retired" }
abort "tinyMediaManager retirement contract failed: container absence is not inspected" unless
  inspection&.key?("community.docker.docker_container_info")
abort "tinyMediaManager retirement contract failed: container absence is not asserted" unless assertion
```

Retain the existing checks that the Compose file uses parameterized bind mounts and bounded logging. Remove checks for web/API readiness, password installation, managed settings, metadata generation, and CPU-runtime verification because the retired container must not run.

- [ ] **Step 2: Add runtime modes for a preservation sentinel**

The shell contract must accept these exact modes:

```sh
seed-retirement-fixture)
  # Create, never replace, a mode-0600 sentinel below
  # $PLATFORM_DOCKER_ROOT/tinymediamanager/data.
  ;;
assert-retired)
  # Require docker inspect of $PLATFORM_TINYMEDIAMANAGER_CONTAINER to fail,
  # require the sentinel to be a regular non-symlink file, and require its
  # contents and SHA-256 digest to equal the seed artifact in
  # $PLATFORM_REPORT_ROOT.
  ;;
```

Use Ruby `File::WRONLY | File::CREAT | File::EXCL` for both sentinel and report artifact creation. Refuse symlinks and non-regular files. Do not recursively enumerate or hash the real state directory; the sentinel proves bind-state preservation without exposing application data.

- [ ] **Step 3: Run the contract and confirm the intended failure**

Run:

```sh
tests/contracts/tinymediamanager.sh static
```

Expected: FAIL with `retirement task is absent` because the role still deploys tinyMediaManager.

- [ ] **Step 4: Commit the red contract**

```sh
git add -- tests/contracts/tinymediamanager.sh
git commit -m "test: define tinymediamanager retirement contract"
```

### Task 2: Convert the role from deployment to retirement

**Files:**
- Modify: `roles/tinymediamanager/tasks/main.yml`
- Modify: `roles/tinymediamanager/defaults/main.yml`
- Modify: `roles/tinymediamanager/meta/argument_specs.yml`
- Modify: `roles/tinymediamanager/templates/env.j2`

- [ ] **Step 1: Reduce defaults to retirement-only inputs**

Replace active endpoints and metadata settings with only the stable project/container identities:

```yaml
---
tinymediamanager_compose_project_name: >-
  {{ (platform_project_name ~ '-tinymediamanager')
     if platform_project_name | default('') | length > 0 else 'tinymediamanager' }}
tinymediamanager_container_name: >-
  {{ (platform_project_name ~ '-tinymediamanager')
     if platform_compose_kind == 'mac' else 'tinymediamanager' }}
tinymediamanager_web_port: 4000
tinymediamanager_api_port: 7878
```

The ports remain only because the transitional Compose definition must interpolate on Mac; they are removed in retirement release two.

- [ ] **Step 2: Narrow the role interface**

Set the short description to `Retire tinyMediaManager while preserving bind-mounted state` and retain only these options: `platform_compose_kind`, optional `platform_project_name`, optional `tinymediamanager_container_name`, optional `tinymediamanager_web_port`, optional `tinymediamanager_api_port`, and required `vault_tinymediamanager_password`. The legacy password remains temporarily because Compose interpolation validates every required environment expression even when the desired state is absent.

- [ ] **Step 3: Keep the legacy environment render interpolation-only**

Render the same required Compose inputs in `env.j2`, but add a leading comment stating that the file exists solely to parse and remove the transitional Compose project. Do not add or rotate any credential.

- [ ] **Step 4: Replace the role body with the retirement flow**

Use this task order:

```yaml
---
- name: Select the tinyMediaManager preserved state root
  tags: [platform_verify_tinymediamanager]
  ansible.builtin.set_fact:
    tinymediamanager_state_root: "{{ nas_docker_root }}/tinymediamanager/data"

- name: Revalidate deployment paths before tinyMediaManager retirement
  ansible.builtin.include_role:
    name: deployment_bundle
    tasks_from: target
  vars:
    deployment_target_require_current_release: true
    deployment_target_extra_paths:
      - "{{ platform_current_dir }}/services/tinymediamanager"
      - "{{ platform_current_dir }}/services/tinymediamanager/compose.yml"
      - "{{ platform_current_dir }}/services/tinymediamanager/compose.{{ platform_compose_kind }}.yml"
      - "{{ platform_runtime_dir }}/services/tinymediamanager"
      - "{{ platform_runtime_dir }}/services/tinymediamanager/.env"
      - "{{ tinymediamanager_state_root }}"

- name: Inspect preserved tinyMediaManager state before retirement
  tags: [platform_verify_tinymediamanager]
  ansible.builtin.stat:
    path: "{{ tinymediamanager_state_root }}"
    follow: false
  register: tinymediamanager_preserved_state

- name: Require safe preserved tinyMediaManager state
  tags: [platform_verify_tinymediamanager]
  ansible.builtin.assert:
    that:
      - tinymediamanager_preserved_state.stat.exists
      - tinymediamanager_preserved_state.stat.isdir
      - not tinymediamanager_preserved_state.stat.islnk
    fail_msg: >-
      Refusing tinyMediaManager retirement because its critical state root is
      absent or unsafe. Restore the state directory before retrying.

- name: Render the transitional tinyMediaManager removal environment
  ansible.builtin.template:
    src: env.j2
    dest: "{{ platform_runtime_dir }}/services/tinymediamanager/.env"
    mode: "0600"
  no_log: true

- name: Retire tinyMediaManager without deleting state
  community.docker.docker_compose_v2:
    project_src: "{{ platform_current_dir }}/services/tinymediamanager"
    project_name: "{{ tinymediamanager_compose_project_name }}"
    files: "{{ platform_service_compose_files['tinymediamanager'] }}"
    env_files: ["{{ platform_runtime_dir }}/services/tinymediamanager/.env"]
    state: absent
    remove_volumes: false
    remove_orphans: false
  register: tinymediamanager_retirement

- name: Report the tinyMediaManager retirement
  ansible.builtin.include_role:
    name: ntfy
    tasks_from: deployment_report
  vars:
    ntfy_deployment_report_service: tinyMediaManager retirement
    ntfy_deployment_report_changed: "{{ tinymediamanager_retirement is changed }}"

- name: Inspect the retired tinyMediaManager container
  tags: [platform_verify_tinymediamanager]
  community.docker.docker_container_info:
    name: "{{ tinymediamanager_container_name }}"
  register: tinymediamanager_retired_container

- name: Require tinyMediaManager to remain retired
  tags: [platform_verify_tinymediamanager]
  ansible.builtin.assert:
    that:
      - ansible_check_mode or not tinymediamanager_retired_container.exists
      - tinymediamanager_preserved_state.stat.exists
      - tinymediamanager_preserved_state.stat.isdir
      - not tinymediamanager_preserved_state.stat.islnk
    fail_msg: >-
      tinyMediaManager retirement did not leave the container absent with its
      critical bind-mounted state preserved.
```

The `ansible_check_mode` alternative is required because Compose predicts the
removal without performing it; the following read-only inspection will still
see the container during a check-mode run. Do not delete files, rewrite JSON,
call the application API, run a CPU check, or remove volumes.

- [ ] **Step 5: Run the static contract**

Run:

```sh
tests/contracts/tinymediamanager.sh static
```

Expected: `tinyMediaManager retirement static contract passed`.

- [ ] **Step 6: Run role and policy checks**

Run:

```sh
ruby tests/policy_test.rb
ansible-lint --strict roles/tinymediamanager site.yml verify.yml
ansible-playbook -i inventory/local.yml site.yml --syntax-check
ansible-playbook -i inventory/local.yml verify.yml --syntax-check
```

Expected: all commands pass. If the deployment-report policy only recognizes `state: present`, extend its property check to accept this one explicitly named retirement task rather than weakening it for other roles.

- [ ] **Step 7: Commit the role conversion**

```sh
git add -- roles/tinymediamanager
git commit -m "feat: retire tinymediamanager without deleting state"
```

### Task 3: Make integration prove removal of a pre-existing container

**Files:**
- Modify: `tests/integration.sh`
- Modify: `tests/integration_suite_test.sh`
- Modify: `tests/contracts/tinymediamanager.sh`
- Create: `tests/tinymediamanager_retirement_fixture.yml`
- Modify: `tests/mac/hooks/fixtures-seed/50-tinymediamanager.sh`
- Modify: `tests/mac/hooks/fixtures-persistence/50-tinymediamanager.sh`
- Modify: `tests/mac/hooks/fixtures-recreate/50-tinymediamanager.sh`
- Modify: `tests/mac/hooks/drift/50-tinymediamanager.sh`
- Modify: `tests/mac/hooks/verify/50-tinymediamanager.sh`
- Modify: `tests/mac/run-tinymediamanager-contract.sh`

- [ ] **Step 1: Write a strict failing lifecycle-routing observation test**

Update `tests/integration_suite_test.sh` to execute a narrow, side-effect-free
routing-observation mode in `tests/integration.sh`. The test must observe the
same lifecycle routing plan that production execution uses; it must not parse
the shell source or emulate Docker, Ansible, controller, or hook behavior.

Require the observation mode to emit an ordered, terminal event stream. For
the `tinymediamanager` and `full` suites, project the relevant events and
require this exact order:

```text
seed-retirement-fixture
converge
assert-retired
success
```

For unrelated suites, require no tinyMediaManager events and require `success`
as the terminal event. Reject the legacy `seed`, `run`, and
`assert-persistence` modes, plus active API-readiness and metadata-readiness
behavior.

Run:

```sh
tests/integration_suite_test.sh
```

Expected: FAIL because the observation seam and retirement routing do not yet
exist.

- [ ] **Step 2: Add a shared lifecycle dispatch and safe observation mode**

Refactor `tests/integration.sh` so real execution and routing observation both
consume the same lifecycle dispatch plan. Add only the narrow observation mode
required by the test: it emits the ordered events that production would
dispatch, performs none of them, and ends with an explicit `success` event so
an early exit cannot satisfy the contract.

The observation mode must perform no Docker, Ansible, network, media/state,
fixed-/tmp, or controller-payload side effects. Any unexpected operation while
observing must fail closed. Do not maintain a second routing model solely for
the test.

- [ ] **Step 3: Seed preserved state before convergence**

Change the tinyMediaManager pre-converge fixture call in `tests/integration.sh` to:

```sh
PLATFORM_CONTRACT_REPO_DIR=$repo_dir \
PLATFORM_DOCKER_ROOT=$docker_root \
PLATFORM_REPORT_ROOT=$report_root \
  "$repo_dir/tests/contracts/tinymediamanager.sh" seed-retirement-fixture
```

The seed mode creates `retirement-contract.txt` containing a fixed non-secret marker and stores its digest in the report root.

- [ ] **Step 4: Start the legacy Compose project before the site converge**

In the same fixture phase, have `seed-retirement-fixture` create a mode-0600 environment file at `$PLATFORM_REPORT_ROOT/tinymediamanager-retirement.env` with the exact keys required by the current Compose definition:

```dotenv
TZ=UTC
PLATFORM_CONTAINER_CPUSET=0
USER_ID=1000
GROUP_ID=100
TINYMEDIAMANAGER_PASSWORD=retirement-fixture-only
TINYMEDIAMANAGER_DATA_PATH=${PLATFORM_DOCKER_ROOT}/tinymediamanager/data
TINYMEDIAMANAGER_MOVIES_PATH=${PLATFORM_MEDIA_ROOT}/Media/Movies
TINYMEDIAMANAGER_SERIES_PATH=${PLATFORM_MEDIA_ROOT}/Media/Series
TINYMEDIAMANAGER_WEB_HOST_PORT=${PLATFORM_TINYMEDIAMANAGER_WEB_PORT}
TINYMEDIAMANAGER_API_HOST_PORT=${PLATFORM_TINYMEDIAMANAGER_API_PORT}
PLATFORM_PROJECT_NAME=${PLATFORM_PROJECT_NAME}
```

The contract writes resolved values, not the literal shell expressions shown above.

Create `tests/tinymediamanager_retirement_fixture.yml`:

```yaml
---
- name: Start a legacy tinyMediaManager fixture for retirement proof
  hosts: localhost
  connection: local
  gather_facts: false
  tasks:
    - name: Start the legacy tinyMediaManager fixture
      community.docker.docker_compose_v2:
        project_src: "{{ lookup('env', 'PLATFORM_CONTRACT_REPO_DIR') }}/services/tinymediamanager"
        project_name: "{{ lookup('env', 'PLATFORM_PROJECT_NAME') }}-tinymediamanager"
        files: >-
          {{ ['compose.yml',
              'compose.' ~ lookup('env', 'PLATFORM_COMPOSE_KIND') ~ '.yml'] }}
        env_files:
          - "{{ lookup('env', 'PLATFORM_REPORT_ROOT') }}/tinymediamanager-retirement.env"
        state: present
        wait: true
        wait_timeout: 240
      changed_when: false
```

Invoke the playbook with the repository's pinned Ansible and collection environment. It is test setup outside `site.yml`; `changed_when: false` prevents fixture creation from contaminating converge accounting.

Use the exact project name and environment file that the role will later use. This proves `state: absent` removes a real Compose-owned container rather than merely accepting an already-absent state.

- [ ] **Step 5: Assert retirement after convergence**

Replace active runtime calls with:

```sh
PLATFORM_CONTRACT_REPO_DIR=$repo_dir \
PLATFORM_DOCKER_ROOT=$docker_root \
PLATFORM_REPORT_ROOT=$report_root \
PLATFORM_TINYMEDIAMANAGER_CONTAINER=$tinymediamanager_container \
  "$repo_dir/tests/contracts/tinymediamanager.sh" assert-retired
```

The assertion must run after first converge, clean reconverge, and service recreation phases.

- [ ] **Step 6: Replace active-service Mac hooks**

Make the hook responsibilities exact:

- `fixtures-seed`: seed the sentinel and start the legacy Compose project;
- `fixtures-persistence`: assert container absence and sentinel preservation;
- `fixtures-recreate`: do not recreate tinyMediaManager; assert it remains absent;
- `drift`: start the legacy project as deliberate drift and record the condition;
- `verify`: run the tagged verification and require that convergence repaired the drift by removing the container;
- `run-tinymediamanager-contract.sh`: dispatch only `seed-retirement-fixture` and `assert-retired`.

No hook may remove `{{ nas_docker_root }}/tinymediamanager/data` or Movies/Series fixtures.

- [ ] **Step 7: Run the focused static harness tests**

Run:

```sh
tests/integration_suite_test.sh
tests/mac/integration-context-test.sh
tests/mac/run-phase-status-test.sh
ruby tests/policy_test.rb
```

Expected: all pass.

- [ ] **Step 8: Run the tinyMediaManager integration suite**

Run:

```sh
tests/integration.sh --suite tinymediamanager site.yml
```

Expected: fixture starts the old container; first converge removes it; second converge is clean; the sentinel digest remains exact.

- [ ] **Step 9: Commit the lifecycle proof**

```sh
git add -- tests/integration.sh tests/integration_suite_test.sh \
  tests/contracts/tinymediamanager.sh \
  tests/tinymediamanager_retirement_fixture.yml tests/mac
git commit -m "test: prove tinymediamanager retirement lifecycle"
```

### Task 4: Update operator-facing retirement documentation

**Files:**
- Modify: `README.md`
- Modify: `docs/getting-started-nas.md`
- Modify: `docs/secrets.md`
- Modify: `tests/mac/manual-review.md`
- Modify: `services/jellyfin/compose.yml`
- Test: `tests/docs_links_test.rb`
- Test: `tests/secrets_docs_test.rb`

- [ ] **Step 1: Write failing documentation assertions**

Extend the relevant documentation test so it requires all four statements:

```text
tinyMediaManager is retired and must remain stopped.
Its bind-mounted state is preserved through the transitional release.
Movies and Series are not deleted or moved by retirement.
The tinyMediaManager vault key remains until the cleanup release.
```

Run the focused documentation test and confirm it fails because the current docs still describe an active manager.

- [ ] **Step 2: Update the documentation and Jellyfin ownership comment**

Replace active-operation instructions with the transitional state and rollback procedure: before Radarr/Sonarr deployment, rollback may restore the preserved role and Compose definitions and reconverge; after arr has written the libraries, rollback must first stop the arr writers. Change the Jellyfin Compose comment from tinyMediaManager ownership to the neutral statement that media writers own adjacent metadata while Jellyfin remains read-only.

- [ ] **Step 3: Run documentation checks**

Run:

```sh
ruby tests/docs_links_test.rb
ruby tests/secrets_docs_test.rb
```

Expected: both pass.

- [ ] **Step 4: Commit documentation**

```sh
git add -- README.md docs/getting-started-nas.md docs/secrets.md \
  tests/mac/manual-review.md services/jellyfin/compose.yml \
  tests/docs_links_test.rb tests/secrets_docs_test.rb
git commit -m "docs: document tinymediamanager retirement checkpoint"
```

### Task 5: Verify the transitional release and prepare the NAS checkpoint

**Files:**
- No planned file changes; any failure must be fixed in a file already named in Tasks 1–4

- [ ] **Step 1: Run whitespace and targeted verification**

```sh
git diff --check origin/main...HEAD
tests/contracts/tinymediamanager.sh static
tests/integration_suite_test.sh
ruby tests/policy_test.rb
```

Expected: all pass.

- [ ] **Step 2: Run the complete repository policy ladder**

```sh
tests/validate-policy.sh
ansible-lint --strict
```

Expected: all policy checks and lint pass.

- [ ] **Step 3: Run the disposable lifecycle proof**

```sh
tests/integration.sh --suite tinymediamanager site.yml
```

Require the caller to supply the disposable vault password file, then run:

```sh
: "${PLATFORM_MAC_VAULT_PASSWORD_FILE:?set the disposable vault password file}"
tests/mac/run.sh --lane fresh \
  --vault-file inventory/group_vars/all/vault.yml \
  --vault-password-file "$PLATFORM_MAC_VAULT_PASSWORD_FILE"
```

Expected: first converge removes the seeded legacy container, reconverge is clean, check mode predicts no unsafe mutation, drift recreation is removed, and the sentinel remains byte-exact.

- [ ] **Step 4: Inspect the final diff and commit any verification-only corrections**

```sh
git status --short
git diff --stat origin/main...HEAD
git log --oneline origin/main..HEAD
```

Stage only named retirement files. Do not add a `Co-Authored-By` trailer.

- [ ] **Step 5: Stop at the production checkpoint**

Do not begin permanent deletion or arr deployment in this branch. After this release reaches the NAS, require these operator observations:

```text
docker ps --all contains no tinyMediaManager container
{{ nas_docker_root }}/tinymediamanager/data still exists
Movies and Series remain present and readable in Jellyfin
the deployment report records the retirement
```

Only then start a fresh-main cleanup branch that deletes tinyMediaManager source, ports, CPU/vault/CI contracts, and introduces the Usenet acquisition foundation.
