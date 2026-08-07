# Mac Platform Proof Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prove that the complete nine-stack NAS platform can be deployed on Docker Desktop from the same encrypted credentials and managed configuration, pass automated and manual acceptance, and adopt disposable state created by the current Portainer-era definitions without touching the physical NAS.

**Architecture:** Ansible will copy a versioned deployment bundle from the controller checkout and deploy canonical Compose files plus minimal Mac overrides into an isolated sandbox. A shared harness will run fresh-install and legacy-state-adoption lanes, exercise service APIs and disposable fixtures, verify idempotence and drift repair, and produce a redacted report tied to the Git revision and encrypted-vault checksum.

**Tech Stack:** ansible-core 2.21.2, community.docker 5.2.1, Docker Compose v2, POSIX shell, Ruby policy tests, service HTTP APIs/CLIs, GitHub Actions.

**Specification:** `docs/superpowers/specs/2026-08-05-mac-platform-proof-design.md`

---

## Execution boundaries

- This plan never connects to, deploys to, stops, or changes the physical NAS.
- The local acceptance run uses the real encrypted vault so the same operator,
  database, ntfy, Beszel, and integration credentials are installed on the Mac.
- CI uses a generated ephemeral vault with the identical schema. CI proves
  behavior and schema, not production credential parity.
- Production application data and databases are never copied to the Mac.
- Paperless Gmail authentication and configuration are verified without
  consuming messages. A real fetch remains an explicit manual action.
- Every production change follows red-green-refactor and gets its own commit.
- Stop after any failing baseline, possible secret disclosure, destructive path
  ambiguity, or unexpected external side effect.

## Target file structure

```text
inventory/
  mac.yml
  local.yml
  remote.yml
  group_vars/
    all/main.yml
    mac_hosts/main.yml
    nas_hosts/main.yml
    all/vault.yml.example
services/
  manifest.yml
  <service>/compose.yml
  <service>/compose.mac.yml
roles/
  deployment_bundle/
  preflight/
  host_prep/
  ntfy/ beszel/ dozzle/
  audiobookshelf/ komga/ tinymediamanager/
  jellyfin/ immich/ paperless_ngx/
tests/
  policy_test.rb
  integration.sh
  sandbox_cleanup.sh
  generate-ephemeral-vault.sh
  contracts/<service>.sh
  mac/lib.sh
  mac/run.sh
  mac/cleanup.sh
  mac/fixtures.sh
  mac/verify.sh
  mac/drift.sh
  mac/adoption.sh
  mac/report.rb
  mac/manual-review.md
verify.yml
```

## Tranche 1: Safe foundation and shared harness

### Task 1: Make integration cleanup reliable

**Files:**
- Create: `tests/integration_cleanup_test.sh`
- Create: `tests/sandbox_cleanup.sh`
- Modify: `tests/integration.sh:18-52`
- Modify: `.github/workflows/ci.yml:20-24`

- [x] **Step 1: Write a failing cleanup regression test**

Create a sandbox, use the pinned runner image to create a root-owned file inside
it, invoke the shared cleanup command, and assert the directory no longer exists:

```sh
sandbox=$(mktemp -d "${TMPDIR:-/tmp}/nas-platform-cleanup.XXXXXX")
runner_image=docker.io/library/python:3.13-alpine@sha256:399babc8b49529dabfd9c922f2b5eea81d611e4512e3ed250d75bd2e7683f4b0
docker run --rm -v "$sandbox:/sandbox" "$runner_image" \
  sh -c 'mkdir -p /sandbox/state && touch /sandbox/state/root-owned'
cleanup_sandbox "$sandbox"
[ ! -e "$sandbox" ]
```

- [x] **Step 2: Run the regression test and verify the current cleanup fails**

Run: `tests/integration_cleanup_test.sh`

Expected: non-zero exit with `Permission denied` from host-side `rm`.

- [x] **Step 3: Extract safe cleanup into a sourced function**

Define `cleanup_sandbox` in `tests/sandbox_cleanup.sh` and source that file from
both the integration harness and its regression test. The function must:

1. Validate the path matches `${temporary_parent}/nas-platform-*.??????`.
2. Remove known containers first.
3. Use
   `docker.io/library/python:3.13-alpine@sha256:399babc8b49529dabfd9c922f2b5eea81d611e4512e3ed250d75bd2e7683f4b0`
   to delete bind-mounted contents.
4. Remove the now-empty host directory.
5. Preserve the original test exit status.

Do not use `sudo`, an unvalidated glob, or a broad recursive host deletion.

- [x] **Step 4: Run cleanup and policy checks**

Run:

```sh
tests/integration_cleanup_test.sh
sh -n tests/integration.sh tests/integration_cleanup_test.sh tests/sandbox_cleanup.sh
ruby tests/policy_test.rb
```

Expected: all commands exit zero and the temporary directory is absent.

- [x] **Step 5: Commit**

```sh
git add tests/integration.sh tests/integration_cleanup_test.sh tests/sandbox_cleanup.sh .github/workflows/ci.yml
git commit -m "fix: clean integration sandboxes safely"
```

### Task 2: Add an explicit migration manifest

**Files:**
- Create: `services/manifest.yml`
- Modify: `tests/policy_test.rb:18-81`
- Test: `tests/policy_test.rb`

- [x] **Step 1: Add failing manifest assertions**

Extend the policy test to require the exact service names and reject undeclared
service directories:

```ruby
EXPECTED_SERVICES = %w[
  audiobookshelf beszel dozzle immich jellyfin komga ntfy paperless-ngx
  tinymediamanager
].freeze

manifest_names = manifest.fetch("services").map { |service| service.fetch("name") }
check(failures, manifest_names.sort == EXPECTED_SERVICES.sort,
      "service manifest must list the complete source platform")
```

Each manifest entry has `name`, `legacy_path`, `role`, `tranche`, and `status`.
The only allowed statuses are `planned`, `implemented`, and `accepted`. A service
marked `implemented` or `accepted` must have Compose, role, storage declarations,
and automated verification.

- [x] **Step 2: Run the policy test and verify it fails**

Run: `ruby tests/policy_test.rb`

Expected: failure because `services/manifest.yml` is absent.

- [x] **Step 3: Create the complete manifest**

Mark `ntfy` and `beszel` as `implemented`; mark the remaining seven services as
`planned`. Record
`400f03f276ae1bb69f5460c175b9fb923d620f1a` as `legacy_source.commit` and
`../nas-infrastructure` as the local default source.

- [x] **Step 4: Run the policy test**

Run: `ruby tests/policy_test.rb`

Expected: `policy: all properties hold`.

- [x] **Step 5: Commit**

```sh
git add services/manifest.yml tests/policy_test.rb
git commit -m "test: track complete platform migration scope"
```

### Task 3: Make deployments controller-revision-owned

**Files:**
- Create: `roles/deployment_bundle/meta/argument_specs.yml`
- Create: `roles/deployment_bundle/tasks/main.yml`
- Create: `roles/deployment_bundle/templates/manifest.yml.j2`
- Modify: `site.yml:10-23`
- Modify: `inventory/group_vars/all/main.yml:15-16`
- Modify: `roles/ntfy/tasks/main.yml:8-21`
- Modify: `roles/beszel/tasks/main.yml:13-37`
- Modify: `tests/integration.sh:114-122`

- [x] **Step 1: Add a failing bundle-ownership integration assertion**

Before running Ansible, place a deliberately stale Compose file in the target
deployment directory. After the run, assert its checksum equals the controller
source and assert the generated deployment manifest contains the expected Git
SHA.

- [x] **Step 2: Run the focused integration test and verify it fails**

Run: `tests/integration.sh site.yml --tags deployment_bundle`

Expected: failure because no role replaces the stale target definition.

- [x] **Step 3: Implement immutable release bundles**

Add variables:

```yaml
platform_release_id: "{{ lookup('pipe', 'git rev-parse HEAD') | trim }}"
platform_deploy_root: "{{ nas_docker_root }}/nas-platform"
platform_release_dir: "{{ platform_deploy_root }}/releases/{{ platform_release_id }}"
platform_current_dir: "{{ platform_deploy_root }}/current"
```

The role copies only manifest-declared implemented services from
`{{ playbook_dir }}/services` to `platform_release_dir`, writes a manifest with
Git SHA and image references, and atomically points `platform_current_dir` at
that release. Service roles deploy from `platform_current_dir`, never from an
arbitrary target Git checkout. Each role passes canonical `compose.yml` plus
`compose.{{ platform_kind }}.yml` when that override exists; production behavior
therefore remains canonical and overrides stay capability-scoped.

- [x] **Step 4: Remove the target-checkout preflight requirement**

Replace the `nas_repo_dir/services` assertion with checks that the controller
bundle source exists and that `platform_deploy_root` is writable. Keep mount and
Docker checks unchanged.

- [x] **Step 5: Run integration, idempotence, and check mode**

Run: `tests/integration.sh site.yml`

Expected: converge succeeds, second run reports `changed=0`, check mode succeeds,
and the stale file has been replaced by the controller version.

- [x] **Step 6: Commit**

```sh
git add roles/deployment_bundle roles/preflight site.yml inventory/group_vars/all/main.yml roles/ntfy roles/beszel tests/integration.sh
git commit -m "feat: deploy versioned controller bundles"
```

### Task 4: Separate host capabilities from portable configuration

**Files:**
- Create: `inventory/mac.yml`
- Create: `inventory/group_vars/mac_hosts/main.yml`
- Create: `inventory/group_vars/nas_hosts/main.yml`
- Modify: `inventory/local.yml`
- Modify: `inventory/remote.yml`
- Modify: `inventory/group_vars/all/main.yml`
- Modify: `site.yml:6-8`
- Modify: `roles/preflight/meta/argument_specs.yml`
- Modify: `tests/policy_test.rb`

- [x] **Step 1: Add failing inventory-contract tests**

Require every inventory to expose a child of `platform_hosts`, require
`platform_kind` to be either `nas` or `mac`, and require explicit capability
variables for render devices, host networking, and external integration checks.

- [x] **Step 2: Run the policy test and verify it fails**

Run: `ruby tests/policy_test.rb`

Expected: failure naming the missing `platform_hosts` and Mac inventory.

- [x] **Step 3: Implement the inventory hierarchy**

Use this shape:

```yaml
platform_hosts:
  children:
    mac_hosts:
      hosts:
        mac:
          ansible_connection: local
```

NAS inventories place `nas` under `nas_hosts`. Change `site.yml` to target
`platform_hosts`. Move only machine facts into host-group files. Keep timezone,
UID/GID policy, alert thresholds, service identities, and application behavior in
shared variables.

- [x] **Step 4: Validate all inventories**

Run:

```sh
ansible-inventory -i inventory/mac.yml --graph
ansible-inventory -i inventory/local.yml --graph
ansible-inventory -i inventory/remote.yml --graph
ruby tests/policy_test.rb
```

Expected: all inventories contain `platform_hosts`; policy passes.

- [x] **Step 5: Commit**

```sh
git add inventory site.yml roles/preflight tests/policy_test.rb
git commit -m "refactor: model platform host capabilities"
```

### Task 5: Enforce shared-vault credential parity

**Files:**
- Modify: `inventory/group_vars/all/vault.yml.example`
- Modify: `templates/vault-plain.yml.j2`
- Modify: `generate-secrets.yml`
- Create: `validate-vault.yml`
- Create: `roles/vault_contract/meta/argument_specs.yml`
- Create: `roles/vault_contract/tasks/main.yml`
- Create: `tests/generate-ephemeral-vault.sh`
- Modify: `site.yml`
- Modify: `tests/policy_test.rb:129-160`

- [x] **Step 1: Add failing vault-schema tests**

Require the example, generated template, validation role, and CI generator to
share the same keys. Add keys for:

- Audiobookshelf administrator.
- Dozzle administrator and password hash.
- Immich administrator and database.
- Jellyfin administrator.
- Komga administrator.
- Paperless administrator, database, Django secret, Gmail account/app password,
  mail-account identity, and mail-rule identity.
- tinyMediaManager password.
- Existing ntfy and Beszel identities.

The test must reject `vault_nas_*` values used as portable application settings;
connection coordinates remain NAS inventory values, not shared credentials.

- [x] **Step 2: Run the policy test and verify missing keys fail**

Run: `ruby tests/policy_test.rb`

Expected: failures listing the absent portable credential keys.

- [x] **Step 3: Expand and validate the vault contract**

`validate-vault.yml` must validate presence and shape without printing values.
It records only the SHA-256 of the encrypted vault file in the deployment report.
It must never hash or print individual plaintext secrets.

Change `generate-secrets.yml` so it is explicitly for a brand-new platform and
never overwrites or silently rotates migration credentials. Document that the
real vault is populated from the current password manager/Portainer values.

Create `tests/generate-ephemeral-vault.sh` to generate schema-complete disposable
values, write them under a caller-supplied temporary directory with mode `0600`,
encrypt them with a one-run password file, and print no secret values. The script
must refuse output paths inside the repository. Its `--cleanup <directory>` mode
must apply the same validated-prefix rule and remove the temporary vault and
password file without printing either.

- [x] **Step 4: Prove example/template/schema parity**

Run:

```sh
ruby tests/policy_test.rb
ansible-playbook validate-vault.yml -e @inventory/group_vars/all/vault.yml.example
tests/generate-ephemeral-vault.sh --self-test
```

Expected: both pass with no secret values in output.

- [x] **Step 5: Commit**

```sh
git add inventory/group_vars/all/vault.yml.example templates/vault-plain.yml.j2 generate-secrets.yml validate-vault.yml roles/vault_contract site.yml tests/policy_test.rb tests/generate-ephemeral-vault.sh
git commit -m "feat: define portable credential contract"
```

### Task 6: Build the Mac lifecycle and reporting harness

**Files:**
- Create: `tests/mac/lib.sh`
- Create: `tests/mac/run.sh`
- Create: `tests/mac/cleanup.sh`
- Create: `tests/mac/fixtures.sh`
- Create: `tests/mac/verify.sh`
- Create: `tests/mac/drift.sh`
- Create: `tests/mac/report.rb`
- Create: `tests/mac/manual-review.md`
- Create: `verify.yml`
- Modify: `.gitignore`
- Modify: `README.md`
- Modify: `tests/policy_test.rb`

- [x] **Step 1: Write failing lifecycle tests**

Add policy assertions that the harness supports these named phases and refuses a
sandbox outside its validated prefix:

```text
preflight deploy seed verify idempotence drift reconcile recreate persistence
report cleanup
```

Add a shell test proving cleanup refuses `/`, the repository root, an empty path,
and an arbitrary existing directory.

- [x] **Step 2: Run the tests and verify they fail**

Run:

```sh
ruby tests/policy_test.rb
tests/mac/cleanup.sh --self-test
```

Expected: missing-harness failures.

- [x] **Step 3: Implement the phase runner**

`run.sh` accepts:

```text
--lane fresh|adoption
--vault-file <encrypted-file>
--vault-password-file <executable-or-file>
--keep-on-failure
--phase <name>
```

It creates a unique sandbox with `mktemp -d`, exports explicit sandbox variables,
invokes Ansible with `inventory/mac.yml`, and writes reports outside service data.
It defaults to preserving failed sandboxes and prints one explicit cleanup
command.

`verify.yml` runs application verification roles without redeploying services.
The harness uses it for post-seed, post-drift, post-recreation, and
post-adoption checks so verification cannot accidentally hide a defect by
reconverging first.

- [x] **Step 4: Implement redacted reports**

The Ruby reporter accepts structured phase input, rejects keys matching
`password|secret|token|authorization|private_key|hash`, and emits JSON plus a
human-readable Markdown summary. Add unit cases proving each forbidden key is
redacted.

- [x] **Step 5: Verify shell safety and report redaction**

Run:

```sh
find tests/mac -type f -name '*.sh' -exec sh -n {} +
ruby tests/mac/report.rb --self-test
tests/mac/cleanup.sh --self-test
ruby tests/policy_test.rb
```

Expected: all pass.

- [x] **Step 6: Commit**

```sh
git add tests/mac verify.yml .gitignore README.md tests/policy_test.rb
git commit -m "feat: add disposable Mac proof harness"
```

## Tranche 2: Monitoring and alerting

### Task 7: Make ntfy and Beszel fully convergent

**Files:**
- Create: `services/ntfy/compose.mac.yml`
- Create: `services/beszel/compose.mac.yml`
- Modify: `roles/beszel/tasks/main.yml:130-296`
- Modify: `roles/beszel/vars/main.yml`
- Modify: `roles/beszel/defaults/main.yml`
- Modify: `tests/integration.sh`
- Create: `tests/contracts/beszel.sh`
- Modify: `tests/mac/drift.sh`
- Modify: `tests/mac/verify.sh`

- [x] **Step 1: Write failing Beszel drift tests**

After initial deployment, mutate the application-user role, replace the managed
universal token, change the ntfy webhook, change an alert threshold, and add a
second system record. Re-run Ansible and assert:

- The vault token exists exactly once for the managed user.
- The user is verified and has role `admin`.
- The webhook equals the configured ntfy URL.
- Each managed alert matches its configured value and duration.
- Alerts attach to the system matching `beszel_system_name`, not the first record.

- [x] **Step 2: Run the contract test and verify current behavior fails**

Run: `tests/contracts/beszel.sh`

Expected: token, role, alert-update, and system-selection assertions fail.

- [x] **Step 3: Implement record-specific reconciliation**

List and select records by managed identity. Use `PATCH` for existing mismatched
users, tokens, settings, and alerts; use `POST` only when absent. Never treat a
generic HTTP 400 as successful convergence. Refuse duplicate managed identities
with a diagnostic that contains IDs but no secrets.

- [x] **Step 4: Add explicit agent lifecycle handling**

When the host lacks the agent capability, ensure a previously managed agent is
stopped and absent. On Mac, run the non-Intel agent with CPU/container monitoring
through the socket proxy. On NAS, retain the Intel image, render device, host
network, and `CAP_PERFMON` requirements.

- [x] **Step 5: Run monitoring integration tests**

Run:

```sh
tests/contracts/beszel.sh
tests/mac/run.sh --lane fresh --phase verify
tests/mac/run.sh --lane fresh --phase drift
```

Expected: all managed records converge and a test Beszel notification appears in
the disposable ntfy topic.

- [x] **Step 6: Commit**

```sh
git add services/ntfy/compose.mac.yml services/beszel/compose.mac.yml roles/beszel tests/contracts/beszel.sh tests/integration.sh tests/mac
git commit -m "fix: reconcile Beszel configuration drift"
```

### Task 8: Migrate Dozzle and its four alert rules

**Files:**
- Create: `services/dozzle/compose.yml`
- Create: `services/dozzle/compose.mac.yml`
- Create: `roles/dozzle/defaults/main.yml`
- Create: `roles/dozzle/meta/argument_specs.yml`
- Create: `roles/dozzle/tasks/main.yml`
- Create: `roles/dozzle/templates/env.j2`
- Create: `roles/dozzle/templates/users.yml.j2`
- Create: `tests/contracts/dozzle.sh`
- Modify: `inventory/group_vars/all/main.yml`
- Modify: `site.yml`
- Modify: `services/manifest.yml`

- [x] **Step 1: Write a failing Dozzle contract test**

The test requires simple authentication with the vault credential, disabled
actions/shell/MCP, read-only Docker access through the socket proxy, an ntfy
destination, and exactly these enabled event alerts:

```yaml
- name: OOM
  event: 'name == "oom"'
  cooldown: 300
- name: Unexpected exit
  event: 'name == "die" && !(attributes["exitCode"] in ["0", "130", "143", "137"])'
  cooldown: 300
- name: Unhealthy
  event: 'name == "health_status" && attributes["healthStatus"] == "unhealthy"'
- name: Recovery
  event: 'name == "health_status" && attributes["healthStatus"] == "healthy"'
```

- [x] **Step 2: Run the contract test and verify the service is absent**

Run: `tests/contracts/dozzle.sh`

Expected: failure because Dozzle is not deployed.

- [x] **Step 3: Port and parameterize the Compose definition**

Preserve the pinned images and socket-proxy restrictions from
`nas-infrastructure`. Declare `/data` as critical state. The Mac override changes
only published host port and socket access mechanics required by Docker Desktop.

- [x] **Step 4: Implement deterministic provisioning**

Render `users.yml` from the shared vault. Characterize the pinned image's
notification API in `tests/contracts/dozzle.sh`; provision destination and alert
records through that API. If the pinned image exposes no stable write API, fail
the task rather than copying an opaque database, and record the explicit product
limitation for design review.

- [x] **Step 5: Verify an actual event reaches ntfy**

Start a disposable container that exits with code 1, wait through the event
pipeline, and assert an authenticated message appears on `nas-critical`. Confirm
the publisher token cannot read the topic.

- [x] **Step 6: Run idempotence and drift repair**

Run:

```sh
tests/contracts/dozzle.sh
tests/mac/run.sh --lane fresh --phase idempotence
tests/mac/run.sh --lane fresh --phase drift
```

Expected: four alerts and one destination remain exact; second Ansible run has
zero changes.

- [x] **Step 7: Mark Dozzle implemented and commit**

```sh
git add services/dozzle roles/dozzle tests/contracts/dozzle.sh inventory/group_vars/all/main.yml site.yml services/manifest.yml tests/mac
git commit -m "feat: manage Dozzle alerting"
```

## Tranche 3: Read-mostly media services

### Task 9: Migrate Audiobookshelf

**Files:**
- Create: `services/audiobookshelf/compose.yml`
- Create: `services/audiobookshelf/compose.mac.yml`
- Create: `roles/audiobookshelf/defaults/main.yml`
- Create: `roles/audiobookshelf/meta/argument_specs.yml`
- Create: `roles/audiobookshelf/tasks/main.yml`
- Create: `roles/audiobookshelf/templates/env.j2`
- Create: `tests/contracts/audiobookshelf.sh`
- Modify: `inventory/group_vars/all/main.yml`
- Modify: `site.yml`
- Modify: `services/manifest.yml`
- Modify: `tests/mac/fixtures.sh`
- Modify: `tests/mac/verify.sh`

- [x] **Step 1: Write a failing application contract**

Require vault administrator login, one managed audiobook library rooted at
`/audiobooks`, successful fixture scan, playable audio response, and retained
progress after recreation.

- [x] **Step 2: Run the contract and verify it fails because the role is absent**

Run: `tests/contracts/audiobookshelf.sh`

- [x] **Step 3: Port Compose and storage policy**

Parameterize config, metadata, and read-only audiobook sources. Preserve pinned
image, UID/GID, port, health check, restart, and logging policy. Declare config
and metadata critical and the media library user-owned.

- [x] **Step 4: Provision administrator and library through the pinned API**

Use create-if-absent and patch-if-drift semantics keyed by vault username and
library name. Refuse duplicate managed identities.

- [x] **Step 5: Seed and verify the audiobook fixture**

Generate a short tagged audio file, scan it, set playback progress, recreate the
container, and assert both item and progress remain.

- [x] **Step 6: Run tests and commit**

```sh
tests/contracts/audiobookshelf.sh
tests/mac/run.sh --lane fresh --phase recreate
git add services/audiobookshelf roles/audiobookshelf tests inventory/group_vars/all/main.yml site.yml services/manifest.yml
git commit -m "feat: migrate Audiobookshelf"
```

### Task 10: Migrate Komga and tinyMediaManager

**Files:**
- Create: `services/komga/compose.yml`
- Create: `services/komga/compose.mac.yml`
- Create: `roles/komga/defaults/main.yml`
- Create: `roles/komga/meta/argument_specs.yml`
- Create: `roles/komga/tasks/main.yml`
- Create: `roles/komga/templates/env.j2`
- Create: `services/tinymediamanager/compose.yml`
- Create: `services/tinymediamanager/compose.mac.yml`
- Create: `roles/tinymediamanager/defaults/main.yml`
- Create: `roles/tinymediamanager/meta/argument_specs.yml`
- Create: `roles/tinymediamanager/tasks/main.yml`
- Create: `roles/tinymediamanager/templates/env.j2`
- Create: `tests/contracts/komga.sh`
- Create: `tests/contracts/tinymediamanager.sh`
- Modify: `inventory/group_vars/all/main.yml`
- Modify: `services/manifest.yml`
- Modify: `site.yml`
- Modify: `tests/mac/fixtures.sh`
- Modify: `tests/mac/verify.sh`

- [x] **Step 1: Write failing contracts for both applications**

Komga must accept the vault login, expose a managed read-only `/data` library,
scan a small comic archive, and preserve library settings. tinyMediaManager must
accept the vault password, expose writable Movies and Series fixture trees, scan
both sources, write metadata, keep direct VNC disabled, and preserve settings.

- [x] **Step 2: Run both contracts and verify absence failures**

Run:

```sh
tests/contracts/komga.sh
tests/contracts/tinymediamanager.sh
```

- [x] **Step 3: Port canonical definitions and Mac overrides**

Preserve Komga's read-only library. Preserve tinyMediaManager's intentional
writes and NAS host-network exception; the Mac override replaces host networking
with explicit web/API port publications because Docker Desktop host networking
is not equivalent.

- [x] **Step 4: Add provisioning and fixture verification**

Use supported application APIs or stable configuration files. If an application
does not expose first-run automation, the contract must identify the exact
manual exception and the role must stop with instructions instead of reporting
success. Do not edit opaque databases.

- [x] **Step 5: Run persistence tests and commit**

Completed 2026-08-07. Every gate in the handoff checkpoint passed from a fresh
run: live contracts, second-run `changed=0 failed=0`, `--check --diff`, cleanup,
the full static review, and the complete Mac fresh lane across all eleven phases.

The checkpoint's byte-churn was only half fixed. The role compared settings
semantically, but the contract still fingerprinted them byte for byte, and two
writers touch those documents: the application in its own format, and the role
with `to_nice_json` when it repairs drift. The fingerprint was captured in one
format and recompared in the other. Only the complete Mac lane crosses both
writers, which is why `--phase recreate` could never have been the gate.

The lane also exposed three defects that the role's own verification could not
see, each because it asserted what it had configured rather than what a caller
would experience: `httpServerPort` compared against the variable that set it
while the API bound a port nothing forwarded to, readiness polled the image's
nginx rather than the application, and `compose up --wait` waited on a
healthcheck that did not exist. Komga has no healthcheck either, so `--wait` is
equally vacuous there; it passes only because Komga starts quickly.

```sh
tests/contracts/komga.sh
tests/contracts/tinymediamanager.sh
tests/mac/run.sh --lane fresh
git add services/komga services/tinymediamanager roles/komga roles/tinymediamanager tests inventory/group_vars/all/main.yml site.yml services/manifest.yml
git commit -m "feat: migrate book and media management services"
```

## Tranche 4: Jellyfin

### Task 11: Migrate Jellyfin with explicit CPU and GPU capabilities

**Files:**
- Create: `services/jellyfin/compose.yml`
- Create: `services/jellyfin/compose.mac.yml`
- Create: `services/jellyfin/compose.integration.yml`
- Create: `roles/jellyfin/defaults/main.yml`
- Create: `roles/jellyfin/vars/main.yml`
- Create: `roles/jellyfin/meta/argument_specs.yml`
- Create: `roles/jellyfin/tasks/main.yml`
- Create: `roles/jellyfin/templates/env.j2`
- Create: `tests/contracts/jellyfin.sh`
- Create: `tests/mac/run-jellyfin-contract.sh`
- Create: `tests/mac/hooks/{verify,drift,fixtures-seed,fixtures-recreate,fixtures-persistence}/60-jellyfin.sh`
- Modify: `inventory/group_vars/all/main.yml`
- Modify: `inventory/group_vars/mac_hosts/main.yml`
- Modify: `services/manifest.yml`
- Modify: `site.yml`
- Modify: `verify.yml`
- Modify: `tests/contracts/registry.yml`
- Modify: `tests/integration.sh`
- Modify: `tests/sandbox_cleanup.sh`
- Modify: `tests/policy_test.rb`
- Modify: `tests/mac/{run.sh,verify.sh,report.rb,cleanup.sh,config-isolation.sh,run-phase-status-test.sh}`

Two file-list corrections found during implementation. `inventory/group_vars/nas_hosts/main.yml`
needs no change: Step 3 keeps the render node in the production Compose file, so
no new machine fact is introduced, and adding one would have cascaded into
`PLATFORM_CAPABILITIES`, the preflight argument specs, and the manifest mutation
tests for no gain. `tests/mac/fixtures.sh` needs no change either; it dispatches
to the hook directories, so a service is added by dropping in hooks.

`services/jellyfin/compose.integration.yml` is required and was not planned. The
integration lane deploys everything in `site.yml` inside a Linux container that
has no `/dev/dri`, so without it CI would fail on a device that cannot exist there.

- [x] **Step 1: Write failing Jellyfin contracts**

The shared contract requires vault login, a managed `/media` library, fixture
discovery, direct play, CPU transcoding on Mac, preserved user/library state, and
read-only media. The NAS-only contract requires render device mapping, group
access, and the one-minute stop grace period.

- [x] **Step 2: Verify the service is absent**

Run: `tests/contracts/jellyfin.sh --platform mac`

- [x] **Step 3: Port canonical Compose and create a Mac override**

Keep `/dev/dri/renderD128` only in the production definition. The Mac override
selects CPU behavior without redefining image, container data paths, or security
policy.

Compose appends sequences when it merges, so an empty `devices` list would have
left the production render node in place. The override resets `devices` and
`group_add` with an explicit `!override` tag, and the contract asserts the tag
itself rather than only the parsed empty list, because the parsed result is
identical either way and only the tag actually removes anything.

- [x] **Step 4: Automate the startup wizard idempotently**

Use Jellyfin's startup/configuration API to set the vault administrator and
managed library only when the wizard is incomplete; on later runs authenticate
and reconcile the managed library without resetting unrelated user settings.

Two behaviors of pinned 10.11.11 that no documentation states and only a live
server reveals. The startup endpoints answer 503 until the server finishes
initializing, which happens well after the container health check passes, so the
role waits on the endpoint it actually calls rather than on `/health`. And
`POST /Startup/User` answers 404 until `GET /Startup/User` has materialized the
default first user, so that read is a required step of the wizard, not a probe.

- [x] **Step 5: Verify CPU transcode and state persistence**

Request a transcoded segment from the fixture, assert a successful media
response and active transcode session, recreate Jellyfin, and authenticate with
the same vault login.

Forcing a smaller frame size makes the source unusable as-is, so the server must
re-encode rather than remux. The contract asserts the returned segment is real
MPEG-TS, that the reported session is not direct video and reports no hardware
acceleration, and that re-encoded output reached the cache volume, which is
durable evidence independent of how long the session stays visible.

- [x] **Step 6: Run tests and commit**

Completed 2026-08-07. The complete Mac fresh lane passed all eleven phases from
a clean sandbox, including `changed=0 failed=0` on the second run, Jellyfin drift
refused by the verification-only playbook and repaired by the next converge, and
user, library, and scanned media surviving container recreation.

The command block below is superseded. `--phase recreate` cannot be the gate: it
is unreachable on its own because `require_predecessors` demands every earlier
phase, and Task 10 already recorded that three of its four defects lived in
phases that `--phase recreate` never reaches. Run the complete lane.

Two defects that only the live lane could find, both the contract asserting its
own expectations instead of what the server sends: a rejected login returns plain
text, not JSON, and a ranged direct-play request returns 206, not 200. Each
raised before the response it was meant to check could be compared.

```sh
tests/contracts/jellyfin.sh --platform mac
tests/mac/run.sh --lane fresh
git add services/jellyfin roles/jellyfin tests inventory site.yml services/manifest.yml
git commit -m "feat: migrate Jellyfin with platform capabilities"
```

## Tranche 5: Immich

### Task 12: Migrate Immich with coordinated database state

**Files:**
- Create: `services/immich/compose.yml`
- Create: `services/immich/compose.mac.yml`
- Create: `roles/immich/defaults/main.yml`
- Create: `roles/immich/meta/argument_specs.yml`
- Create: `roles/immich/tasks/main.yml`
- Create: `roles/immich/templates/env.j2`
- Create: `tests/contracts/immich.sh`
- Create: `tests/mac/snapshot-immich.sh`
- Modify: `inventory/group_vars/all/main.yml`
- Modify: `inventory/group_vars/all/vault.yml.example`
- Modify: `roles/vault_contract/meta/argument_specs.yml`
- Modify: `services/manifest.yml`
- Modify: `site.yml`
- Modify: `tests/mac/fixtures.sh`
- Modify: `tests/mac/verify.sh`

- [ ] **Step 1: Write failing Immich contracts**

Require healthy server, machine learning, Valkey, and PostgreSQL; vault
administrator login; upload of photo/video fixtures; thumbnails; CPU machine
learning; search; and persistence across recreation. Assert database/cache/helper
ports are not exposed to the LAN-facing interface.

- [ ] **Step 2: Verify the service is absent**

Run: `tests/contracts/immich.sh`

- [ ] **Step 3: Port the pinned multi-container definition**

Keep production `/dev/dri`; remove it only through the Mac override. Preserve
the existing volume split between originals, generated assets, model cache, and
PostgreSQL. Classify PostgreSQL/profile as critical and generated assets/model
cache according to the source recovery contract.

- [ ] **Step 4: Provision the vault administrator and stable settings**

Create the administrator only when absent; otherwise authenticate and refuse a
different managed account. Do not rotate database credentials against an
existing database without an explicit migration task.

- [ ] **Step 5: Add coordinated snapshot and rollback tests**

Stop writes, create an application-consistent PostgreSQL dump plus matching
fixture assets and generated state, record checksums, mutate the deployment, and
restore the coordinated set. Assert originals open and database records match.

- [ ] **Step 6: Run tests and commit**

```sh
tests/contracts/immich.sh
tests/mac/snapshot-immich.sh --self-test
tests/mac/run.sh --lane fresh --phase persistence
git add services/immich roles/immich tests inventory site.yml services/manifest.yml
git commit -m "feat: migrate Immich with recovery proof"
```

## Tranche 6: Paperless-ngx

### Task 13: Migrate Paperless and provision Gmail safely

**Files:**
- Create: `services/paperless-ngx/compose.yml`
- Create: `services/paperless-ngx/compose.mac.yml`
- Create: `roles/paperless_ngx/defaults/main.yml`
- Create: `roles/paperless_ngx/meta/argument_specs.yml`
- Create: `roles/paperless_ngx/tasks/main.yml`
- Create: `roles/paperless_ngx/templates/env.j2`
- Create: `tests/contracts/paperless.sh`
- Create: `tests/mac/snapshot-paperless.sh`
- Modify: `inventory/group_vars/all/main.yml`
- Modify: `inventory/group_vars/all/vault.yml.example`
- Modify: `roles/vault_contract/meta/argument_specs.yml`
- Modify: `services/manifest.yml`
- Modify: `site.yml`
- Modify: `tests/mac/fixtures.sh`
- Modify: `tests/mac/verify.sh`

- [ ] **Step 1: Write failing Paperless contracts**

Require healthy webserver, PostgreSQL, Valkey, Gotenberg, and Tika; vault
administrator login; document consumption; German/English/Hebrew OCR; preview;
search; Office conversion; export; and persistence. Require the configured Gmail
account and mail rule to match vault/shared configuration.

Require Paperless's actual document-bearing paths to use writable storage under
`nas_media_root` (`/volume2` on the NAS), never `nas_docker_root` (`/volume1`):
the media/document archive, consume inbox, and exports all belong on volume 2.
Only service-owned PostgreSQL, Valkey, configuration, search-index, and cache
state belongs under `/volume1/Docker/paperless-ngx`. Add policy assertions for
this split so a later refactor cannot silently move documents onto volume 1.

- [ ] **Step 2: Add a non-consuming Gmail contract**

The test authenticates to Paperless, inspects the managed mail account/rule,
invokes only the application's connection/authentication check, and asserts no
fetch/import task ran and no inbox message count changed.

- [ ] **Step 3: Verify the service is absent**

Run: `tests/contracts/paperless.sh`

- [ ] **Step 4: Port the canonical stack and Mac network override**

Preserve the NAS host-network exception and loopback-only dependencies in the
production definition. The Mac override uses a Docker Desktop-compatible network
while keeping database, Valkey, Tika, and Gotenberg unpublished externally.
Install and checksum the pinned Hebrew Tesseract model declaratively.

Mount Paperless media/archive, consume, and export directories read-write from
`nas_media_root`; those are user-document storage and must resolve under
`/volume2` on the physical NAS. Mount database, Valkey, configuration,
search-index, and regenerable cache paths from `nas_docker_root` under
`/volume1/Docker/paperless-ngx`, with their appropriate recovery classes.

- [ ] **Step 5: Provision administrator, mail account, and mail rule**

Use supported Paperless management commands and REST resources with exact
identity matching and patch-if-drift behavior. Mark every credential-bearing
task `no_log`. Do not run mail fetch as part of convergence.

- [ ] **Step 6: Verify fixtures, export, and coordinated rollback**

Consume text/image and Office fixtures, assert OCR/search results, create a
portable export, and separately test a coordinated PostgreSQL/archive/data/inbox
snapshot. Restore each strategy into an isolated sandbox and verify the records.

- [ ] **Step 7: Run tests and commit**

```sh
tests/contracts/paperless.sh
tests/mac/snapshot-paperless.sh --self-test
tests/mac/run.sh --lane fresh --phase persistence
git add services/paperless-ngx roles/paperless_ngx tests inventory site.yml services/manifest.yml
git commit -m "feat: migrate Paperless with Gmail provisioning"
```

## Tranche 7: State adoption, manual review, and release gate

### Task 14: Implement the legacy-state-adoption lane

**Files:**
- Create: `tests/mac/adoption.sh`
- Create: `tests/mac/legacy-overrides/audiobookshelf.yml`
- Create: `tests/mac/legacy-overrides/beszel.yml`
- Create: `tests/mac/legacy-overrides/dozzle.yml`
- Create: `tests/mac/legacy-overrides/immich.yml`
- Create: `tests/mac/legacy-overrides/jellyfin.yml`
- Create: `tests/mac/legacy-overrides/komga.yml`
- Create: `tests/mac/legacy-overrides/ntfy.yml`
- Create: `tests/mac/legacy-overrides/paperless-ngx.yml`
- Create: `tests/mac/legacy-overrides/tinymediamanager.yml`
- Modify: `tests/mac/run.sh`
- Modify: `services/manifest.yml`
- Modify: `.github/workflows/ci.yml`

- [ ] **Step 1: Write a failing adoption orchestration test**

Require the script to verify the checked-out `nas-infrastructure` commit equals
`legacy_source.commit`, deploy every legacy stack with disposable paths, seed
state, stop without deleting bind mounts, snapshot state, deploy `nas-platform`
against it, and compare service-specific assertions.

- [ ] **Step 2: Run the adoption self-test and verify it fails**

Run: `tests/mac/adoption.sh --self-test`

Expected: missing orchestration and override failures.

- [ ] **Step 3: Implement pinned legacy checkout handling**

Local runs accept `NAS_INFRASTRUCTURE_DIR`; CI checks out the source repository at
the manifest SHA into a sibling directory. Abort on a dirty or mismatched source
instead of silently testing another revision.

- [ ] **Step 4: Implement per-service adoption assertions**

For every service, record managed login success, fixture checksums, durable
settings, and database record counts before cutover. After Ansible adoption,
assert those remain, then assert newly managed configuration and credential
parity. Beszel additionally verifies key/token adoption without duplicate
systems; ntfy verifies existing auth state plus declarative ACLs; Dozzle verifies
persisted destination and rules.

- [ ] **Step 5: Implement rollback rehearsals**

Restore the pre-cutover copy into a fresh sandbox. For Immich and Paperless,
restore the full coordinated set and matching legacy images. Never point legacy
images at post-migration databases.

- [ ] **Step 6: Run the complete adoption lane**

Run:

```sh
tests/mac/run.sh --lane adoption --vault-file inventory/group_vars/all/vault.yml --vault-password-file "$PLATFORM_VAULT_PASSWORD_FILE"
```

Expected: every service reports adopted state, idempotence, persistence, and
rollback success; no production data is read.

- [ ] **Step 7: Commit**

```sh
git add tests/mac/adoption.sh tests/mac/legacy-overrides tests/mac/run.sh services/manifest.yml .github/workflows/ci.yml
git commit -m "test: prove legacy state adoption"
```

### Task 15: Create and execute the manual acceptance review

**Files:**
- Modify: `tests/mac/manual-review.md`
- Modify: `tests/mac/report.rb`
- Modify: `README.md`
- Create locally, do not commit: `.artifacts/mac-proof/<release>/manual-review.md`

- [ ] **Step 1: Turn every approved workflow into a checkbox**

Include URL, vault username variable name, fixture name, exact user action, and
expected result for Audiobookshelf, Komga, Jellyfin, tinyMediaManager, Immich,
Paperless, ntfy, Beszel, and Dozzle. Include fields for pass/fail, notes,
timestamp, Git SHA, image set, encrypted-vault checksum, and reviewer.

- [ ] **Step 2: Add automated report validation**

The reporter refuses an acceptance report with unchecked workflows, missing
evidence metadata, unacknowledged NAS-only gates, or secret-like values.

- [ ] **Step 3: Run the fresh lane with the real encrypted vault**

Run:

```sh
tests/mac/run.sh --lane fresh \
  --vault-file inventory/group_vars/all/vault.yml \
  --vault-password-file "$PLATFORM_VAULT_PASSWORD_FILE" \
  --keep-on-failure
```

Expected: automated phases pass and the harness prints localhost URLs plus the
manual-review artifact path.

- [ ] **Step 4: Complete the manual application review**

Perform every workflow in the approved design. For Paperless, inspect Gmail
configuration and run only the non-consuming authentication/connectivity check.
Do not mark an item passed based only on container health.

- [ ] **Step 5: Validate the completed report**

Run:

```sh
ruby tests/mac/report.rb --validate .artifacts/mac-proof/*/manual-review.md
```

Expected: `manual acceptance: all workflows passed`.

- [ ] **Step 6: Commit the reusable checklist, not the secret-bearing artifact**

```sh
git add tests/mac/manual-review.md tests/mac/report.rb README.md
git commit -m "docs: add Mac acceptance review"
```

### Task 16: Restore update automation and enforce the final proof gate

**Files:**
- Create: `renovate.json`
- Create: `.github/dependabot.yml`
- Modify: `.github/workflows/ci.yml`
- Modify: `tests/policy_test.rb`
- Modify: `services/manifest.yml`
- Modify: `README.md`

- [ ] **Step 1: Add failing final-gate policy assertions**

Require all nine manifest entries to be `accepted` before the proof badge/status
can be declared. Require Renovate grouping for version-coupled Immich and Beszel
images, pinned GitHub Actions, pinned Ansible dependencies, fresh and adoption CI
jobs, and an explicit list of NAS-only gates.

- [ ] **Step 2: Run policy and verify planned services prevent acceptance**

Run: `ruby tests/policy_test.rb`

Expected: failure until every service has passed its contract and manifest state
is updated.

- [ ] **Step 3: Add update automation**

Port the source repository's Renovate and Dependabot policies, updating file
match patterns for `services/*/compose*.yml`, `requirements.yml`, and workflow
actions. Keep automatic merge and deployment disabled.

- [ ] **Step 4: Add CI proof lanes**

CI generates an ephemeral vault, runs policy/lint/syntax, fresh installation,
idempotence, drift repair, recreation, persistence, adoption, and cleanup. It
must clearly label credential parity and manual review as local required evidence,
not CI-passed properties.

- [ ] **Step 5: Run full non-secret verification**

Run:

```sh
ruby tests/policy_test.rb
ansible-lint --strict
ansible-playbook -i inventory/mac.yml site.yml --syntax-check
tests/integration.sh site.yml
proof_vault_dir=$(mktemp -d "${TMPDIR:-/tmp}/nas-platform-vault.XXXXXX")
tests/generate-ephemeral-vault.sh \
  --output "$proof_vault_dir/vault.yml" \
  --password-file "$proof_vault_dir/password"
tests/mac/run.sh --lane fresh \
  --vault-file "$proof_vault_dir/vault.yml" \
  --vault-password-file "$proof_vault_dir/password"
tests/mac/run.sh --lane adoption \
  --vault-file "$proof_vault_dir/vault.yml" \
  --vault-password-file "$proof_vault_dir/password"
tests/generate-ephemeral-vault.sh --cleanup "$proof_vault_dir"
```

Expected: every command exits zero, second Ansible runs report no changes, and
cleanup leaves no containers, networks, sandbox files, or rendered secrets.

- [ ] **Step 6: Mark all services accepted and commit**

Only after automated and manual gates pass:

```sh
git add renovate.json .github services/manifest.yml tests/policy_test.rb README.md
git commit -m "chore: enforce complete Mac platform proof"
```

### Task 17: Produce the NAS migration-design input packet

**Files:**
- Create: `docs/migration/mac-proof-summary.md`
- Modify: `README.md`

- [ ] **Step 1: Write the evidence summary**

Record the accepted Git SHA, image set, tested legacy SHA, automated report
locations, manual review result, credential-parity evidence, per-service adoption
behavior, rollback results, unavoidable manual exceptions, and every NAS-only
gate. Do not include secrets or absolute secret-file paths.

- [ ] **Step 2: Verify the summary against reports**

Run: `ruby tests/mac/report.rb --verify-summary docs/migration/mac-proof-summary.md`

Expected: every claim has a matching report result and no secret-like material.

- [ ] **Step 3: Confirm the physical NAS remains untouched**

Review the Ansible limit/host logs and assert no run targeted `nas_hosts`. Record
this as a proof precondition.

- [ ] **Step 4: Commit and stop**

```sh
git add docs/migration/mac-proof-summary.md README.md
git commit -m "docs: record Mac platform proof evidence"
```

Stop here. Use the evidence packet to brainstorm and write the separate physical
NAS migration design. Do not infer authorization to deploy to the NAS from
completion of this plan.

## Completion criteria

This implementation plan is complete only when:

1. All nine services are `accepted` in `services/manifest.yml`.
2. Fresh-install and legacy-state-adoption lanes pass with ephemeral CI secrets.
3. Both lanes pass locally using the shared encrypted deployment vault.
4. The manual application review passes using the same operator credentials as
   the NAS.
5. Paperless Gmail account/rule provisioning and non-consuming authentication
   succeed.
6. Idempotence, drift repair, persistence, rollback, cleanup, policy, lint, and
   syntax checks pass.
7. NAS-only limitations are recorded without being represented as tested.
8. No command in this plan has changed the physical NAS.
9. The Mac proof summary is committed and ready to drive the NAS migration
   design.
