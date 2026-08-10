# Legacy State Adoption Lane Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prove all nine pinned legacy stacks can be seeded, snapshotted, adopted by nas-platform, verified, recreated, and rolled back with real configuration parity and no production data.

**Architecture:** The existing proof runner gains a distinct adoption phase graph and protected parity inputs. A focused adoption coordinator renders legacy environment files, drives nine pinned Compose projects with committed overrides, records sanitized baselines, performs coordinated filesystem snapshots, and compares post-cutover and rollback evidence.

**Tech Stack:** POSIX shell, Ruby, Ansible, Docker Compose v2, YAML/JSON, GitHub Actions.

## Implementation checkpoint — 2026-08-10

- Branch: `agent/task-14-adoption`
- Implementation baseline before this checkpoint:
  `07da7aa9bd270f15e2b60e0ab101fd7a555e2c93`
- Managed-user migration prerequisite: complete. Full synthetic integration passed at
  `a3195f49a00a1906fae7fd92811d08a329af9e19`, including all registered live
  contracts, second convergence with `changed=0`, and final check mode.
- Task 1: complete and independently spec/security reviewed. Feature commit
  `ac384978fad004d24901f9353caa5676239c2e20`; protected-input corrections end at
  `ed88de7582b43d99a4e19923104ccdcd86083e44`.
- Task 2: complete and independently spec/security reviewed. Initial feature
  commit `7ba47a2e75bd879e7924aef21700febc5277c73c`; encrypted-snapshot, checkout
  integrity, runner-preflight, and real-Ansible regression corrections end at
  `03eb26d`.
- Task 3: complete and independently spec/security reviewed. Override feature
  commit `8e10e04506bbe50e2af6be7156cb61871e06e3d5`; exact environment,
  runtime-semantics, port, and bind contract corrections end at
  `81b5c6a8606eb0ef30899480525a55d6be1ef9af`. The pinned Beszel Intel image is
  retained with a portable runtime posture. Read-only Docker socket binds are
  allowed only on the Beszel and Dozzle socket-proxy services.
- Task 4: complete and independently spec/security reviewed. Initial feature
  commit `b562c8a61aea228d31ed8f910df2f8d02637430d`; exact role prerequisites,
  fixture namespaces, structured health, all-nine legacy environment adapters,
  pre-start Beszel identity, contained fixture controls, secure staging, and
  default temporary-root corrections end at
  `07da7aa9bd270f15e2b60e0ab101fd7a555e2c93`.
- Task 5 is the immediate next action. Tasks 6–9 are not started.
- Task 10: not started and remains gated on explicitly supplied/authorized
  protected deployment and parity inputs plus the clean pinned legacy checkout.
- No protected production inputs have been accessed and no live migration has
  been claimed.
- Process hygiene: monitor Ruby mutation/self-test processes by PID, parent,
  elapsed time, CPU, and output progress during long gates. At this checkpoint
  no Ruby test process is running. Stop only a confirmed orphan or spin loop.
- Commit policy: never add `Co-Authored-By` trailers.

---

### Task 1: Extend the runner and report schemas

**Files:**
- Modify: tests/mac/run.sh
- Modify: tests/mac/report.rb
- Modify: tests/mac/run-phase-status-test.sh
- Create: tests/mac/adoption-runner-test.sh

- [ ] **Step 1: Write failing CLI and phase tests**

Require fresh phases to remain:

~~~text
preflight deploy seed verify idempotence drift reconcile recreate persistence report cleanup
~~~

Require adoption phases to be:

~~~text
preflight legacy-deploy legacy-seed capture-baseline snapshot cutover verify
idempotence recreate persistence rollback report cleanup
~~~

Require normal adoption runs to accept and require --parity-vault-file and
--parity-vault-password-file. Fresh runs must reject parity options. Resumed
adoption runs must bind both ciphertext checksums and the legacy commit.

Run: tests/mac/adoption-runner-test.sh

Expected: FAIL because run.sh has one phase list and no parity options.

- [ ] **Step 2: Split phase selection**

Define FRESH_PHASES and ADOPTION_PHASES before option parsing and assign PHASES
after lane validation. Add parity options to the parser and usage. Validate the
parity artifact like the deployment vault, require it outside the repository,
and require an explicit parity password input. The caller may pass the same
external password path for both vaults, but omission is never interpreted as
permission to fall back.

- [ ] **Step 3: Extend report identity**

Add nullable parity_vault_checksum and legacy_commit root fields. Require both
64/40 lowercase hexadecimal values for adoption and null for fresh. Pass them at
report initialization, compare them during resume, redact any unexpected
secret-named fields, and render them in JSON and Markdown.

- [ ] **Step 4: Verify and commit**

~~~bash
tests/mac/adoption-runner-test.sh
tests/mac/run-phase-status-test.sh
ruby tests/mac/report.rb --self-test
git add tests/mac/run.sh tests/mac/report.rb tests/mac/run-phase-status-test.sh \
  tests/mac/adoption-runner-test.sh
git commit -m "feat: add adoption proof phases"
~~~

### Task 2: Validate the pinned legacy checkout and render parity inputs

**Files:**
- Create: tests/mac/adoption.sh
- Create: tests/mac/adoption-self-test.sh
- Create: tests/mac/legacy-render.yml
- Create: tests/mac/templates/legacy-env.j2
- Modify: tests/validate-policy.sh

- [ ] **Step 1: Write failing self-tests**

Require refusal of missing, dirty, symlinked, wrong-repository, and wrong-commit
NAS_INFRASTRUCTURE_DIR values. Require exact repository origin and commit from
services/manifest.yml. Require encrypted parity schema/commit validation and
mode-0600 rendered environment files under the owned sandbox, with no values in
output.

Run: tests/mac/adoption-self-test.sh

Expected: FAIL because adoption.sh is absent.

- [ ] **Step 2: Implement preflight**

adoption.sh accepts a subcommand and reads only exported runner paths. Its
preflight resolves NAS_INFRASTRUCTURE_DIR physically, compares git status,
remote repository identity, and HEAD to
400f03f276ae1bb69f5460c175b9fb923d620f1a, and verifies every manifest
legacy_path is a regular tracked file.

legacy-render.yml receives the encrypted parity vault with -e at invocation
time, validates exact schema and service set, and renders one env file per stack.
The template iterates sorted entries and doubles dollar signs for Compose without
shell evaluation. No task logs values.

- [ ] **Step 3: Add self-test mode and commit**

adoption.sh --self-test uses fake git, ansible-playbook, and docker commands to
prove ordering and error propagation without Darwin or Docker.

~~~bash
sh -n tests/mac/adoption.sh tests/mac/adoption-self-test.sh
tests/mac/adoption-self-test.sh
git add tests/mac/adoption.sh tests/mac/adoption-self-test.sh \
  tests/mac/legacy-render.yml tests/mac/templates/legacy-env.j2 tests/validate-policy.sh
git commit -m "feat: validate legacy adoption inputs"
~~~

### Task 3: Add nine disposable legacy overrides

**Files:**
- Create: tests/mac/legacy-overrides/audiobookshelf.yml
- Create: tests/mac/legacy-overrides/beszel.yml
- Create: tests/mac/legacy-overrides/dozzle.yml
- Create: tests/mac/legacy-overrides/immich.yml
- Create: tests/mac/legacy-overrides/jellyfin.yml
- Create: tests/mac/legacy-overrides/komga.yml
- Create: tests/mac/legacy-overrides/ntfy.yml
- Create: tests/mac/legacy-overrides/paperless-ngx.yml
- Create: tests/mac/legacy-overrides/tinymediamanager.yml
- Create: tests/mac/legacy-overrides-test.rb

- [ ] **Step 1: Write the failing override contract**

For every manifest service require one regular YAML file, no image override, no
production host path, unique project/container names, sandbox-only bind sources,
allocated localhost ports, no NAS device, and no production host networking.
Require Immich and Paperless dependency DNS to remain reachable. Require legacy
image references to come only from the pinned base Compose files.

Run: ruby tests/mac/legacy-overrides-test.rb

Expected: FAIL because the directory is absent.

- [ ] **Step 2: Add simple-service overrides**

Audiobookshelf, Dozzle, Jellyfin, Komga, ntfy, and tinyMediaManager replace each
bind source with the corresponding PLATFORM_MAC_SANDBOX path, remove fixed
container_name values, publish only allocated 127.0.0.1 ports, and remove devices
or host networking. Keep container-side paths unchanged.

- [ ] **Step 3: Add Beszel, Immich, and Paperless overrides**

Beszel selects the portable agent, removes Docker-socket/device access, and uses
the already-managed socket proxy contract. Immich replaces all data/database
mounts and removes GPU devices. Paperless replaces all coordinated state mounts
and converts host networking to the default Compose network so db, broker, tika,
and gotenberg resolve by service name. Override only environment values whose
address semantics changed in the disposable network.

- [ ] **Step 4: Verify and commit**

~~~bash
ruby tests/mac/legacy-overrides-test.rb
git add tests/mac/legacy-overrides tests/mac/legacy-overrides-test.rb
git commit -m "test: adapt pinned legacy stacks"
~~~

### Task 4: Deploy and seed disposable legacy state

**Files:**
- Create: tests/mac/legacy-compose.sh
- Create: tests/mac/legacy-seed.sh
- Create: tests/mac/legacy-seed-test.sh
- Modify: tests/mac/adoption.sh

- [ ] **Step 1: Write the failing orchestration test**

With fake commands require render before Compose config, config before up, all
nine unique legacy projects, health wait before seeding, and seed failure before
snapshot/cutover. Require legacy stop to omit volumes and bind deletion.

Run: tests/mac/legacy-seed-test.sh

Expected: FAIL because helpers are absent.

- [ ] **Step 2: Implement legacy Compose control**

legacy-compose.sh supports config, up, stop, start, ps, and down for one
manifest service. It always supplies the pinned base file, committed override,
rendered env file, and project name
PLATFORM_PROJECT_NAME-legacy-SERVICE. It rejects any other service/action and
never passes --volumes.

- [ ] **Step 3: Implement service seeding**

Initialize primary administrators with deployment-vault credentials, then create
all allowlisted users through the same supported interfaces named in
config/managed-user-capabilities.yml. Seed existing fixture helpers for media,
books, photos, and documents; seed Beszel system/token state, ntfy auth/ACLs,
Dozzle notification state, and Paperless mail state. Emit service/capability
labels only.

- [ ] **Step 4: Verify and commit**

~~~bash
tests/mac/legacy-seed-test.sh
tests/mac/adoption.sh --self-test
git add tests/mac/legacy-compose.sh tests/mac/legacy-seed.sh \
  tests/mac/legacy-seed-test.sh tests/mac/adoption.sh
git commit -m "test: seed disposable legacy state"
~~~

### Task 5: Capture a strict non-secret baseline

**Files:**
- Create: tests/mac/adoption-baseline.rb
- Create: tests/mac/adoption-baseline-test.rb
- Create: tests/mac/adoption-probes/audiobookshelf.sh
- Create: tests/mac/adoption-probes/beszel.sh
- Create: tests/mac/adoption-probes/dozzle.sh
- Create: tests/mac/adoption-probes/immich.sh
- Create: tests/mac/adoption-probes/jellyfin.sh
- Create: tests/mac/adoption-probes/komga.sh
- Create: tests/mac/adoption-probes/ntfy.sh
- Create: tests/mac/adoption-probes/paperless-ngx.sh
- Create: tests/mac/adoption-probes/tinymediamanager.sh
- Modify: tests/mac/adoption.sh

- [ ] **Step 1: Write failing schema/redaction tests**

Require exact root fields schema, legacy_commit, legacy_images, services.
Per-service evidence contains only identity names, roles/permissions, enabled
state, record counts, fixture SHA-256 values, and named managed settings.
Reject keys matching password, secret, token, authorization, private, hash, and
unknown fields. Inject canaries and require atomic refusal without replacing an
existing baseline.

Run: ruby tests/mac/adoption-baseline-test.rb

Expected: FAIL because the recorder is absent.

- [ ] **Step 2: Implement recorder and probes**

Each probe writes one JSON object to stdout and diagnostics to stderr. It
authenticates internally but emits no credential or response body. The recorder
validates, sorts, and atomically publishes baseline.json mode 0600. Capture exact
legacy image references from docker compose config --images and bind them to the
pinned commit.

- [ ] **Step 3: Verify and commit**

~~~bash
ruby tests/mac/adoption-baseline-test.rb
sh -n tests/mac/adoption-probes/*.sh
git add tests/mac/adoption-baseline.rb tests/mac/adoption-baseline-test.rb \
  tests/mac/adoption-probes tests/mac/adoption.sh
git commit -m "test: capture legacy adoption baseline"
~~~

### Task 6: Snapshot and cut over without deleting state

**Files:**
- Create: tests/mac/adoption-snapshot.sh
- Create: tests/mac/adoption-snapshot-test.sh
- Modify: tests/mac/adoption.sh
- Modify: tests/mac/run.sh

- [ ] **Step 1: Write failing snapshot tests**

Require all legacy projects stopped, coordinated source inventory, regular
owned snapshot directory, copy failure atomicity, immutable baseline copy, and
no call to run_site before snapshot publication. Require snapshot refusal for
symlinked state, missing roots, or changed baseline.

Run: tests/mac/adoption-snapshot-test.sh

Expected: FAIL because the snapshot helper is absent.

- [ ] **Step 2: Implement coordinated copy**

Record source relative paths and file metadata under the owned sandbox. Copy
with archive semantics that do not follow symlinks into snapshot/candidate,
verify the inventory, then rename to snapshot/pre-cutover. Include all Immich
and Paperless application/database/support directories as one unit.

- [ ] **Step 3: Implement cutover**

The snapshot phase stops legacy projects without deletion and publishes the
coordinated snapshot. The cutover phase revalidates that immutable snapshot,
invokes run_site against the same service-data roots, and runs the normal exact
verifier. Rename the old adoption deploy behavior; no target role runs during
legacy-deploy.

- [ ] **Step 4: Verify and commit**

~~~bash
tests/mac/adoption-snapshot-test.sh
tests/mac/adoption-runner-test.sh
git add tests/mac/adoption-snapshot.sh tests/mac/adoption-snapshot-test.sh \
  tests/mac/adoption.sh tests/mac/run.sh
git commit -m "test: snapshot state before adoption"
~~~

### Task 7: Verify adoption, recreation, and persistence

**Files:**
- Create: tests/mac/adoption-compare.rb
- Create: tests/mac/adoption-compare-test.rb
- Modify: tests/mac/adoption.sh
- Modify: tests/mac/run.sh

- [ ] **Step 1: Write failing comparison tests**

Require every baseline service and field after cutover. Reject missing or
duplicate users, privilege drift, count regression, fixture checksum changes,
Beszel duplicate systems, ntfy ACL drift, Dozzle destination/rule drift, and
unknown evidence. Accept additional unmanaged records only where the capability
matrix says preserve.

Run: ruby tests/mac/adoption-compare-test.rb

Expected: FAIL because comparison is absent.

- [ ] **Step 2: Implement semantic comparison**

Reuse probes against the target deployment. Compare identity sets and exact
managed properties, minimum preserved record counts, and exact fixture
checksums. Emit only service/capability/pass labels. Store a sanitized comparison
object for the report.

- [ ] **Step 3: Wire remaining target phases**

verify runs comparison; idempotence uses the existing changed=0 gate; recreate
recreates every target container then compares; persistence reruns fixtures and
comparison. A failure preserves the sandbox and records only sanitized
diagnostics.

- [ ] **Step 4: Verify and commit**

~~~bash
ruby tests/mac/adoption-compare-test.rb
tests/mac/adoption-runner-test.sh
ruby tests/mac/report.rb --self-test
git add tests/mac/adoption-compare.rb tests/mac/adoption-compare-test.rb \
  tests/mac/adoption.sh tests/mac/run.sh
git commit -m "test: verify adopted service state"
~~~

### Task 8: Rehearse rollback in a fresh sandbox

**Files:**
- Create: tests/mac/adoption-rollback.sh
- Create: tests/mac/adoption-rollback-test.sh
- Modify: tests/mac/adoption.sh
- Modify: tests/mac/cleanup.sh

- [ ] **Step 1: Write failing rollback isolation tests**

Require a new rollback root/project namespace, restoration only from the
pre-cutover snapshot, legacy images equal baseline images, and no target database
reuse. Inject failure before and after restore; require original snapshot and
cutover sandbox unchanged. Require cleanup to recognize both owned namespaces.

Run: tests/mac/adoption-rollback-test.sh

Expected: FAIL because rollback is absent.

- [ ] **Step 2: Implement rollback**

Create an owned rollback sandbox, restore the snapshot, render the same parity
environment, start matching pinned legacy projects, and rerun baseline probes.
For Immich and Paperless restore complete coordinated sets before any container
starts. Compare rollback evidence to the original baseline and stop the rollback
projects without mutating evidence.

- [ ] **Step 3: Extend contained cleanup and commit**

Cleanup enumerates target, legacy, and rollback project labels derived from the
owned marker. It refuses unknown resources and never removes parity/deployment
vaults, NAS infrastructure checkout, or report evidence.

~~~bash
tests/mac/adoption-rollback-test.sh
tests/mac/cleanup.sh --self-test
git add tests/mac/adoption-rollback.sh tests/mac/adoption-rollback-test.sh \
  tests/mac/adoption.sh tests/mac/cleanup.sh
git commit -m "test: rehearse legacy rollback"
~~~

### Task 9: Add synthetic adoption convergence to CI

**Files:**
- Create: tests/adoption-integration.sh
- Create: tests/adoption-integration-test.sh
- Modify: .github/workflows/ci.yml
- Modify: tests/validate-policy.sh

- [ ] **Step 1: Write the failing CI contract**

Require the full lane to generate separate ephemeral deployment/parity vaults,
check out yonatankarp/nas-infrastructure at the manifest SHA, run complete
adoption convergence, and upload only sanitized failure diagnostics. Require the
docs-only lane to skip it. Reject production paths, secrets, and mutable legacy
refs.

Run: tests/adoption-integration-test.sh

Expected: FAIL because CI has no adoption step.

- [ ] **Step 2: Implement Linux synthetic wrapper**

Generate synthetic exports and both ephemeral vaults under an owned temporary
root, import parity with the production parser, export NAS_INFRASTRUCTURE_DIR to
the pinned CI checkout, and run the adoption coordinator in integration platform
mode. The trap uses existing contained cleanup and removes only owned synthetic
credentials.

- [ ] **Step 3: Add CI checkout and convergence**

In the full lane, check out nas-infrastructure into a non-repository sibling
path at 400f03f276ae1bb69f5460c175b9fb923d620f1a. Run
tests/adoption-integration.sh after existing fresh convergence. Do not pass real
secrets or upload raw Compose environment/config output.

- [ ] **Step 4: Verify and commit**

~~~bash
tests/adoption-integration-test.sh
tests/validate-policy.sh
git diff --check
git add tests/adoption-integration.sh tests/adoption-integration-test.sh \
  tests/validate-policy.sh .github/workflows/ci.yml
git commit -m "ci: prove synthetic legacy adoption"
~~~

### Task 10: Run the real local release gate

**Files:**
- Modify: docs/getting-started-mac.md
- Modify: docs/portainer-parity.md
- Modify: tests/secrets_docs_test.rb

- [ ] **Step 1: Document the exact adoption command**

Add all four external vault arguments and NAS_INFRASTRUCTURE_DIR. State that the
physical NAS is untouched, synthetic CI is not production-parity evidence, and
reports retain only ciphertext checksums.

- [ ] **Step 2: Verify documentation and complete static checks**

~~~bash
tests/validate-docs.sh
tests/validate-policy.sh
ansible-lint --strict
ansible-playbook -i inventory/mac.yml site.yml --syntax-check
git diff --check
git add docs/getting-started-mac.md docs/portainer-parity.md tests/secrets_docs_test.rb
git commit -m "docs: explain the adoption proof"
~~~

- [ ] **Step 3: Run the protected-input proof**

From a clean primary checkout with Docker Desktop running:

~~~bash
NAS_INFRASTRUCTURE_DIR=/absolute/clean/nas-infrastructure \
tests/mac/run.sh --lane adoption \
  --vault-file /external/deployment-vault.yml \
  --vault-password-file /external/vault-password \
  --parity-vault-file /external/portainer-parity.yml \
  --parity-vault-password-file /external/vault-password
~~~

Expected: all adoption phases pass, idempotence reports changed=0, rollback
matches the pre-cutover baseline, reports contain both ciphertext checksums and
no values, and git status remains clean.

- [ ] **Step 4: Stop at Task 14 handoff**

Report the implementation commit, pinned legacy commit, image set, phase results,
sanitized report locations, capability exceptions, and CI run. Do not contact
the physical NAS, retire parity evidence, rotate credentials, or begin Task 15.
